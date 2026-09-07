import Foundation

// The OpenClaw Gateway WebSocket client. This is the only thing in Bridge that
// holds the auth token, and it is native on purpose:
//
//   gateway.controlUi.allowedOrigins is locked to https://claw.myatlasapp.net,
//   so a page served from Bridge's own loopback origin would be refused at the
//   handshake. A native client sends no Origin header at all, is treated as a
//   native-app UI client, and sidesteps the check without loosening it.
//
// Everything the page sees arrives through onEmit as already-trimmed JSON. The
// token never appears in that stream, in a log line, or in an error message.
//
// The full wire contract — handshake, device auth, scopes, event shapes — is
// written up in PROTOCOL.md next to this file.

final class Gateway {
    static let shared = Gateway()

    enum Status: String { case connecting, live, reconnecting, stale, error }

    /// Called on the main queue with one bridge message to hand the web view.
    var onEmit: (([String: Any]) -> Void)?

    private let q = DispatchQueue(label: "bridge.gateway")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let identity = DeviceIdentity.loadOrCreate()

    private var nextId = 1
    private var pending: [String: ([String: Any]?, [String: Any]?) -> Void] = [:]
    private var rows: [[String: Any]] = []
    private var backoff: TimeInterval = 1
    private var generation = 0            // invalidates callbacks from a dead socket
    private var stopped = false
    private var lastEventAt = Date()
    private var historyDebounce: [String: DispatchWorkItem] = [:]

    private(set) var status: Status = .connecting
    private(set) var detail: String = "starting"
    private(set) var serverVersion: String?
    private(set) var scopes: [String] = []

    /// Phase B reads. Each is a real gateway projection, refreshed on connect
    /// and — for tasks — patched from the live `task` event stream.
    private var tasks: [String: [String: Any]] = [:]     // taskId -> trimmed task

    /// How much transcript to backfill per session. The pane shows a tail; more
    /// than this is scrollback nobody reads and a payload nobody needs.
    static let historyLimit = 60
    /// Subscribing to transcripts for every session at once is a lot of fan-out
    /// for rows the user cannot see. The most recently active are the ones that
    /// move, and the list is sorted by activity.
    static let liveSessionCap = 24

    static let clientId = "openclaw-macos"   // a value the Gateway's enum accepts
    static let clientMode = "ui"
    static let clientVersion = "0.1.0"
    /// Phase C. Bridge is now the room: it relays a main-chat message into each
    /// agent's own session and answers questions on Chancellor's behalf, and all
    /// three of those are writes.
    ///
    ///   operator.read       the session index, transcripts, agents, groups, tasks
    ///   operator.write      chat.send / chat.abort — the relay, and steering
    ///   operator.questions  question.list / question.resolve and the event family
    ///
    /// `operator.approvals` is deliberately NOT here: Bridge shows approvals it
    /// happens to see but does not resolve them, and an unused scope is a
    /// standing grant nobody audits. `operator.admin` likewise — PROTOCOL.md §3.
    ///
    /// Widening this set raises a NEW pairing request rather than extending the
    /// approved one (PROTOCOL.md §3), so the first launch after this change
    /// reconnects unscoped until that request is approved. `onHello` names that
    /// state rather than letting it read as a generic failure.
    static let requestedScopes = ["operator.read", "operator.write", "operator.questions"]

    // MARK: - lifecycle

    func start() {
        q.async { self.stopped = false; self.connect() }
    }

    func stop() {
        q.async {
            self.stopped = true
            self.generation += 1
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    /// Called when the token changes in Settings: drop and rebuild immediately
    /// rather than waiting out a backoff the user cannot see.
    func reconnectNow() {
        q.async {
            self.generation += 1
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.backoff = 1
            self.connect()
        }
    }

    private func set(_ s: Status, _ d: String) {
        status = s
        detail = d
        // Phase B: the page draws a Settings panel listing what this connection
        // was actually granted, so the scope set goes across rather than a
        // single readOnly bit derived from it. The bit stays — every existing
        // call site reads it — but it is no longer the only thing known.
        emit(["type": "status", "connection": s.rawValue, "detail": d,
              "readOnly": !scopes.contains("operator.write"),
              "scopes": scopes,
              "requestedScopes": Self.requestedScopes,
              "sshHost": Tunnel.sshHost,
              "tokenPresent": Keychain.token != nil,
              "serverVersion": serverVersion ?? ""])
    }

    private func emit(_ msg: [String: Any]) {
        DispatchQueue.main.async { self.onEmit?(msg) }
    }

    /// Does a retry scheduled at generation `scheduled` still apply?
    ///
    /// It does not if anything has moved the generation on in the meantime —
    /// `reconnectNow()` (Settings saved a token, or the page's Reconnect
    /// button), `stop()`, or a `connect()` that has already happened. Its own
    /// function because it is the whole of the fix and the only part of it that
    /// can be asserted without opening a socket.
    static func retryStillApplies(scheduled: Int, current: Int, stopped: Bool) -> Bool {
        !stopped && scheduled == current
    }

    /// A DELAYED RETRY MUST CHECK THAT IT IS STILL THE PLAN.
    ///
    /// This scheduled `connect()` unconditionally, and `connect()` assigns
    /// `self.task` without cancelling what was there. So the ordinary impatient
    /// case — the banner says reconnecting, the backoff is up at 30 seconds,
    /// Chancellor clicks Reconnect — ran `reconnectNow()`'s connect AND, seconds
    /// later, the stale one. The second overwrote `task`, and the first socket
    /// was never cancelled: still open to the gateway, still counted as a
    /// connection there, never read from here because `receive` filters on the
    /// generation. Every further click added one.
    ///
    /// Measured on the two functions lifted verbatim (`/tmp/fd5/reconnect.swift`),
    /// one click during one backoff:
    ///
    ///     before  connects=3 liveSockets=2
    ///     after   connects=2 liveSockets=1
    private func retry(_ why: String) {
        guard !stopped else { return }
        generation += 1
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        set(.reconnecting, why)
        let wait = backoff
        backoff = min(backoff * 2, 30)
        let scheduled = generation
        NSLog("bridge: gateway retry in \(wait)s — \(why)")
        q.asyncAfter(deadline: .now() + wait) {
            guard Gateway.retryStillApplies(scheduled: scheduled,
                                            current: self.generation,
                                            stopped: self.stopped) else {
                NSLog("bridge: a queued gateway retry was superseded and did not run")
                return
            }
            self.connect()
        }
    }

    // MARK: - connect

    private func connect() {
        guard !stopped else { return }
        guard let token = Keychain.token, !token.isEmpty else {
            set(.error, "no gateway token — open Settings and paste gateway.auth.token")
            return
        }
        set(status == .reconnecting ? .reconnecting : .connecting, "opening the ssh forward")
        guard let port = Tunnel.shared.start() else {
            // Verbatim, because "could not connect" is useless and the ssh line
            // is usually the whole diagnosis.
            retry("ssh forward failed: " + (Tunnel.shared.lastError ?? "unknown"))
            return
        }
        guard let url = URL(string: "ws://127.0.0.1:\(port)/") else {
            set(.error, "bad gateway url"); return
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.httpCookieAcceptPolicy = .never
        let s = URLSession(configuration: cfg)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        generation += 1
        let gen = generation
        set(status == .reconnecting ? .reconnecting : .connecting, "handshaking with the gateway")
        t.resume()
        receive(gen: gen, token: token)
    }

    private func receive(gen: Int, token: String) {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard gen == self.generation else { return }
                switch result {
                case .failure(let e):
                    self.retry("socket closed: \(e.localizedDescription)")
                case .success(let msg):
                    var text: String?
                    if case .string(let s) = msg { text = s }
                    if case .data(let d) = msg { text = String(data: d, encoding: .utf8) }
                    if let text { self.handle(text, gen: gen, token: token) }
                    self.receive(gen: gen, token: token)
                }
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { err in
            if let err { NSLog("bridge: send failed: \(err.localizedDescription)") }
        }
    }

    /// Fire-and-read. Errors are logged and the callback never runs — the
    /// original Phase A shape, kept because most reads genuinely have nothing
    /// to do with a failure beyond not updating.
    private func rpc(_ method: String, _ params: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        call(method, params) { payload, _ in if let payload { done(payload) } }
    }

    /// The full form: exactly one of `payload` / `error` is non-nil.
    ///
    /// Phase B needs this. A steering send that is refused for lack of scope has
    /// to reach the screen as the specific refusal it was — code, message and
    /// missing scope — and Phase A's rpc() dropped every error into NSLog, which
    /// is precisely the silent no-op this feature is not allowed to be.
    private func call(_ method: String, _ params: [String: Any],
                      _ done: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let id = "r\(nextId)"
        nextId += 1
        pending[id] = done
        send(["type": "req", "id": id, "method": method, "params": params])
        // A response that never comes must not leak a closure forever, and the
        // UI must not sit on "connecting" because one call went missing.
        q.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
            NSLog("bridge: \(method) timed out")
            waiting(nil, ["code": "TIMEOUT", "message": "\(method) did not answer within 30s"])
        }
    }

    // MARK: - frames

    private func handle(_ text: String, gen: Int, token: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        lastEventAt = Date()

        switch type {
        case "event":
            let name = obj["event"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]
            if name == "connect.challenge" { sendConnect(payload, token: token) }
            else { onEvent(name, payload) }

        case "res":
            guard let id = obj["id"] as? String else { return }
            if id == "connect" { onHello(obj); return }
            guard let done = pending.removeValue(forKey: id) else { return }
            if obj["ok"] as? Bool == true {
                done(obj["payload"] as? [String: Any] ?? [:], nil)
            } else {
                let err = obj["error"] as? [String: Any] ?? [:]
                NSLog("bridge: rpc error \(err["code"] ?? "?"): \(err["message"] ?? "")")
                done(nil, err)
            }

        default: break
        }
    }

    // The handshake. The device block is not optional decoration: without it the
    // Gateway authenticates the shared token as role `operator` with scopes: []
    // and every subsequent read fails FORBIDDEN / MISSING_SCOPE. See PROTOCOL.md.
    private func sendConnect(_ challenge: [String: Any], token: String) {
        let nonce = challenge["nonce"] as? String ?? ""
        let ts = (challenge["ts"] as? NSNumber)?.int64Value ?? 0
        let scopeList = Self.requestedScopes.joined(separator: ",")
        // v3 payload, joined with "|". Field order is the contract; platform and
        // deviceFamily are lowercased the way the Gateway normalizes them.
        let payload = ["v3", identity.deviceId, Self.clientId, Self.clientMode, "operator",
                       scopeList, String(ts), token, nonce, "macos", ""].joined(separator: "|")
        guard let signature = identity.sign(payload) else {
            set(.error, "could not sign the device challenge"); return
        }
        send([
            "type": "req", "id": "connect", "method": "connect",
            "params": [
                "minProtocol": 4, "maxProtocol": 4,
                "client": ["id": Self.clientId, "version": Self.clientVersion,
                           "platform": "macos", "mode": Self.clientMode],
                "role": "operator",
                "scopes": Self.requestedScopes,
                // tool-events is what makes session.tool arrive at all: the
                // Gateway only registers connections that advertise it as
                // recipients for a run's structured tool events, and it does
                // NOT report an error when the capability is missing.
                "caps": ["tool-events", "session-scoped-events"],
                "commands": [], "permissions": [:],
                "auth": ["token": token],
                "userAgent": "bridge/\(Self.clientVersion)",
                "device": ["id": identity.deviceId,
                           "publicKey": identity.publicKeyBase64URL,
                           "signature": signature,
                           "signedAt": ts, "nonce": nonce],
            ],
        ])
    }

    private func onHello(_ frame: [String: Any]) {
        guard frame["ok"] as? Bool == true, let hello = frame["payload"] as? [String: Any] else {
            let err = frame["error"] as? [String: Any] ?? [:]
            let code = err["code"] as? String ?? "?"
            let msg = err["message"] as? String ?? "connect rejected"
            if code == "PAIRING_REQUIRED" {
                set(.error, "this device is not approved yet — run `openclaw devices approve` on the gateway host")
            } else {
                set(.error, "\(code): \(msg)")
            }
            return
        }
        let auth = hello["auth"] as? [String: Any] ?? [:]
        scopes = auth["scopes"] as? [String] ?? []
        serverVersion = (hello["server"] as? [String: Any])?["version"] as? String
        backoff = 1

        guard scopes.contains("operator.read") || scopes.contains("operator.admin") else {
            // Authenticated but unscoped is the failure mode that looks like
            // success, so it gets named rather than left to 20 MISSING_SCOPE logs.
            set(.error, "connected but the gateway granted no scopes (device not approved) — "
                + "approve it on the gateway host, then reconnect")
            return
        }
        set(.live, "subscribed")
        // A SUBSCRIPTION DOES NOT SURVIVE A RECONNECT — PROTOCOL.md §4 ("per
        // session; not sticky across reconnects") and §6 ("a reconnect
        // re-subscribes and re-fetches; it does not resume"). Every cache that
        // records "already subscribed" therefore belongs to ONE connection, and
        // the room's did not: `roomKeys` was process-lifetime, so from the first
        // reconnect onwards `subscribeRoom` skipped every lane and no room
        // session was ever re-subscribed or re-backfilled again. Nothing failed
        // and nothing was logged; the room simply stopped taking in replies.
        //
        // The session path was never affected — `adopt()` re-subscribes every
        // row it is handed — and it does not cover the room either: room
        // sessions rank by activity like any other, and measured on this gateway
        // they sat at 35 and 36 of 78, outside `liveSessionCap`.
        if !Gateway.debugSkipCacheReset { resetConnectionCaches() }
        subscribeSessions()
        fetchAgents()
        fetchGroups()
        fetchTasks()
        fetchQuestions()
    }

    // MARK: - Phase B reads
    //
    // All three of these were verified to answer under `operator.read` alone
    // against the live gateway before any of this was written — see PROTOCOL.md
    // §9.1. That mattered: the roster picker and the inbox are only honest if
    // their contents are real, and two of the obvious alternatives
    // (`agents.summary`, `config.agents.list`) need operator.admin.

    /// The real agent roster. This is what the Customize picker offers, rather
    /// than a hardcoded list that goes stale the moment an agent is added.
    private func fetchAgents() {
        rpc("agents.list", [:]) { [weak self] payload in
            let agents = (payload["agents"] as? [[String: Any]] ?? []).map { a -> [String: Any] in
                var o: [String: Any] = ["id": a["id"] as? String ?? "?"]
                o["name"] = a["name"] as? String ?? a["id"] as? String ?? "?"
                if let w = a["workspace"] as? String { o["workspace"] = w }
                if let m = a["model"] as? String { o["model"] = m }
                return o
            }
            self?.emit(["type": "agents", "agents": agents,
                        "defaultId": payload["defaultId"] as? String ?? "main"])
            // The room's roster is the gateway's real agent list, not a constant.
            // Every ping target is matched against it, so a tenth lane appears in
            // the room the moment the gateway has one.
            let roster = agents.map { (id: $0["id"] as? String ?? "?",
                                       name: $0["name"] as? String ?? "?") }
            DispatchQueue.main.async {
                Room.shared.setAgents(roster)
                Room.shared.push()
            }
            self?.subscribeRoom(roster.map { $0.id })
        }
    }

    // MARK: - the room
    //
    // Bridge owns a persistent session per agent, `agent:<id>:bridge`, and is
    // the only thing that writes to them. Subscribing and backfilling here is
    // what makes an agent's reply visible to the room at all: Room.observe reads
    // each backfill, takes any turn above its high-water mark into the shared
    // transcript, and relays the pings it finds. See Room.swift.

    private var roomKeys: Set<String> = []

    /// Set ONLY by `--room-probe`, to reproduce the pre-fix behaviour in the
    /// first half of a run and prove the fix in the second. Nothing else reads
    /// it and the app never sets it.
    static var debugSkipCacheReset = false

    /// Drop every "already subscribed on this connection" cache. See onHello.
    private func resetConnectionCaches() {
        roomKeys.removeAll()
        // Same lifetime, same reason: it guards a chat.history fetch that a new
        // connection has not made.
        historyFetched.removeAll()
    }

    /// How many room subscriptions this PROCESS has issued, ever — not how many
    /// are currently live. `--room-probe` reads it either side of a forced
    /// reconnect, which is the only way to observe whether a reconnect really
    /// re-subscribes the room: `roomKeys` is private, the subscription lives on
    /// the gateway, and a unit test has no socket to ask.
    private var roomSubscribeCount = 0
    var roomSubscribesIssued: Int { q.sync { roomSubscribeCount } }

    private func subscribeRoom(_ agentIds: [String]) {
        for id in agentIds {
            let key = Room.key(id)
            guard !roomKeys.contains(key) else { continue }
            roomKeys.insert(key)
            roomSubscribeCount += 1
            // A room session may not exist yet — chat.send creates it on first
            // use — so chat.history can answer with nothing, and that is fine.
            fetchHistory(key)
            rpc("sessions.messages.subscribe", ["key": key]) { _ in }
        }
    }

    // MARK: - questions
    //
    // Real, and shipped in this gateway build: question.list / get / resolve /
    // waitAnswer under `operator.questions`, with question.requested and
    // question.resolved as events. Phase B built the receiver and could not
    // reach it because it held operator.read; Phase C holds the scope and this
    // is the live path.
    //
    // The record shape, read off the gateway's own question-manager rather than
    // guessed at:
    //
    //   { id, questions: [{ questionId, header, question,
    //                       options: [{label, description?}],
    //                       multiSelect?, isSecret?, isOther? }],
    //     agentId?, sessionKey?, runId?, createdAtMs, expiresAtMs,
    //     status: "pending" | "answered" | "cancelled" | "expired" }
    //
    // It is forwarded whole. The inbox renders the options as buttons and
    // resolves through `question.resolve`, whose answers map is keyed by the
    // INNER questionId — not the record id. Those are different strings and
    // mixing them up is a silent no-answer.

    private func fetchQuestions() {
        rpc("question.list", [:]) { [weak self] payload in
            let list = payload["questions"] as? [[String: Any]] ?? []
            self?.emit(["type": "questions", "questions": list, "replace": true])
        }
    }

    /// Answer one question. `answers` is `{ innerQuestionId: [value] }`.
    func resolveQuestion(id: String, answers: [String: [String]], requestId: String) {
        q.async {
            self.call("question.resolve",
                      ["id": id, "answers": ["answers": answers], "resolvedBy": "bridge"]) { [weak self] payload, error in
                var msg: [String: Any] = ["type": "writeResult", "method": "question.resolve",
                                          "requestId": requestId, "sessionKey": ""]
                if let error {
                    let details = error["details"] as? [String: Any] ?? [:]
                    msg["ok"] = false
                    msg["code"] = error["code"] as? String ?? "ERROR"
                    msg["message"] = error["message"] as? String ?? "the gateway refused to resolve it"
                    if let m = details["missingScope"] as? String { msg["missingScope"] = m }
                    // QUESTION_ALREADY_TERMINAL / QUESTION_NOT_FOUND are ordinary
                    // races — someone answered it in the Control UI, or it timed
                    // out — and read differently from a refusal.
                    if let r = details["reason"] as? String { msg["reason"] = r }
                } else {
                    msg["ok"] = true
                    if let p = payload, let st = p["status"] as? String { msg["status"] = st }
                }
                self?.emit(msg)
                self?.fetchQuestions()
            }
        }
    }

    /// The gateway's own session groups — the `category` field sessions carry.
    /// Bridge's Projects section merges these with the projects the user made
    /// locally; the two are labelled differently because they are different.
    private func fetchGroups() {
        rpc("sessions.groups.list", [:]) { [weak self] payload in
            let groups = (payload["groups"] as? [[String: Any]] ?? []).map { g -> [String: Any] in
                ["name": g["name"] as? String ?? "?", "position": g["position"] as? Int ?? 0]
            }
            self?.emit(["type": "groups", "groups": groups])
        }
    }

    /// The inbox backlog. `tasks.list` is the delegation ledger: one row per
    /// delegated task, NOT one per agent — which is exactly the granularity the
    /// inbox was specified at. Live movement arrives as `task` events.
    private func fetchTasks() {
        rpc("tasks.list", ["limit": 120]) { [weak self] payload in
            guard let self else { return }
            for t in payload["tasks"] as? [[String: Any]] ?? [] {
                guard let id = t["id"] as? String ?? t["taskId"] as? String else { continue }
                self.tasks[id] = Gateway.trimTask(t)
            }
            self.emit(["type": "tasks", "tasks": Array(self.tasks.values), "replace": true])
            self.backfillTaskSummaries()
        }
    }

    /// The closing summary a completed task does not carry.
    ///
    /// A finished task's own row has no field holding what the agent actually
    /// concluded (see trimTask). The text does exist — it is the last assistant
    /// message in the CHILD session the task ran in — so the inbox reads it from
    /// there, which is also the most literal possible reading of "the parent
    /// agent's final summary".
    ///
    /// Bounded: only terminal delegated tasks, only sessions not already
    /// backfilled by adopt(), and only the most recent few. An inbox is a tail,
    /// not an archive, and this must not turn into 100 chat.history calls.
    private func backfillTaskSummaries() {
        let terminal: Set<String> = ["completed", "failed", "cancelled", "error", "aborted"]
        let wanted = tasks.values
            .filter { ($0["kind"] as? String) != "automation_run" }
            .filter { terminal.contains($0["status"] as? String ?? "") }
            .sorted { (($0["updatedAt"] as? Double) ?? 0) > (($1["updatedAt"] as? Double) ?? 0) }
            .compactMap { $0["childSessionKey"] as? String }
        var seen = Set<String>()
        for key in wanted where !seen.contains(key) {
            seen.insert(key)
            if seen.count > 20 { break }
            if historyFetched.contains(key) { continue }
            fetchHistory(key)
        }
    }

    // MARK: - subscriptions

    private func subscribeSessions() {
        // sessions.subscribe registers the subscription *before* projecting the
        // list, so this one call is both the subscribe and the snapshot.
        rpc("sessions.subscribe", ["limit": 60, "ownerFirst": true]) { [weak self] payload in
            guard let self else { return }
            guard let list = payload["list"] as? [String: Any] else {
                // {} params answer with an acknowledgment only; a missing list
                // here means an older gateway, so fetch it explicitly.
                self.rpc("sessions.list", ["limit": 60]) { self.adopt($0) }
                return
            }
            self.adopt(list)
        }
    }

    private func refreshSessions() {
        rpc("sessions.list", ["limit": 60, "ownerFirst": true]) { [weak self] in self?.adopt($0) }
    }

    private func adopt(_ list: [String: Any]) {
        let all = list["sessions"] as? [[String: Any]] ?? []
        rows = all
        emit(["type": "sessions", "rows": all.map(Gateway.trimRow)])
        set(.live, "\(all.count) sessions")

        // Transcripts for the rows most likely to be looked at, then their
        // message subscriptions. Backfill first so a live event that lands
        // between the two is decoration on a transcript that already exists.
        for row in all.prefix(Self.liveSessionCap) {
            guard let key = row["key"] as? String else { continue }
            fetchHistory(key)
            rpc("sessions.messages.subscribe", ["key": key]) { _ in }
        }
    }

    private var historyFetched = Set<String>()

    private func fetchHistory(_ key: String) {
        historyFetched.insert(key)
        rpc("chat.history", ["sessionKey": key, "limit": Self.historyLimit]) { [weak self] payload in
            guard let self else { return }
            var msg: [String: Any] = [
                "type": "history",
                "sessionKey": key,
                "messages": (payload["messages"] as? [[String: Any]] ?? []).map(Gateway.trimMessage),
                "totalMessages": payload["totalMessages"] as? Int ?? 0,
            ]
            if let pi = payload["pendingInputs"] as? [String: Any] {
                msg["pendingInputs"] = pi["items"] as? [[String: Any]] ?? []
            }
            self.emit(msg)
            // A room session's backfill is also the room's input. The UNTRIMMED
            // messages go over: trimMessage clips content for display, and a
            // relayed hand-off must be the agent's actual words rather than the
            // first 4000 characters of them.
            if Room.agentId(fromRoomKey: key) != nil {
                let raw = payload["messages"] as? [[String: Any]] ?? []
                DispatchQueue.main.async { Room.shared.observe(key: key, messages: raw) }
            }
        }
    }

    /// A run emits many events per turn and each one could mean new transcript.
    /// Refetching per event would hammer the gateway; refetching never would
    /// leave the pane a tool-call ticker with no prose. One refetch per session
    /// per 3s is the compromise, and live tool events cover the gap.
    private func scheduleHistory(_ key: String) {
        if historyDebounce[key] != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.historyDebounce[key] = nil
            self.fetchHistory(key)
        }
        historyDebounce[key] = work
        q.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - events

    private func onEvent(_ name: String, _ payload: [String: Any]) {
        switch name {
        case "session.tool":
            guard let key = payload["sessionKey"] as? String,
                  let data = payload["data"] as? [String: Any] else { return }
            var msg: [String: Any] = [
                "type": "tool", "sessionKey": key,
                "phase": data["phase"] as? String ?? "start",
                "name": data["name"] as? String ?? "tool",
                "toolCallId": data["toolCallId"] as? String ?? "",
                "seq": payload["seq"] as? Int ?? 0,
                "ts": payload["ts"] as? Double ?? Date().timeIntervalSince1970 * 1000,
            ]
            if let args = data["args"] as? [String: Any] { msg["args"] = Gateway.trimArgs(args) }
            if let r = data["result"] { msg["result"] = Gateway.trimResult(r) }
            if let e = data["isError"] as? Bool { msg["isError"] = e }
            emit(msg)
            // A tool `end` usually means the assistant is about to say something.
            if (data["phase"] as? String) == "end" { scheduleHistory(key) }

        case "session.message", "chat":
            guard let key = payload["sessionKey"] as? String else { return }
            // The event carries the message, but reconciling one delta against a
            // page fetched with a different normalization is how transcripts go
            // subtly wrong. Events are best-effort and drop for slow subscribers
            // anyway, so the honest move is to treat the event as "something
            // changed" and re-read the authoritative page.
            emit(["type": "activity", "sessionKey": key,
                  "ts": payload["ts"] as? Double ?? Date().timeIntervalSince1970 * 1000])
            scheduleHistory(key)

        case "agent", "session.operation", "session.observer":
            guard let key = payload["sessionKey"] as? String else { return }
            emit(["type": "activity", "sessionKey": key,
                  "ts": payload["ts"] as? Double ?? Date().timeIntervalSince1970 * 1000])

        case "sessions.changed":
            // The event usually carries the whole updated row, which is worth
            // taking: on a busy gateway this fires several times a minute and a
            // full sessions.list round-trip for each is wasteful and laggy.
            //
            // When it does NOT carry a row it is a delete notification or a
            // rowless global invalidation, which means the cached index itself
            // is untrustworthy — and then the only correct move is to re-read.
            // A key-only delete event must never be treated as "remove this
            // key": a replacement generation can share it.
            if let row = payload["session"] as? [String: Any], let key = row["key"] as? String {
                if let i = rows.firstIndex(where: { ($0["key"] as? String) == key }) {
                    rows[i] = row
                } else {
                    rows.insert(row, at: 0)
                    // A session Bridge has never seen needs its transcript and
                    // its own subscription before anything it does will show up.
                    fetchHistory(key)
                    rpc("sessions.messages.subscribe", ["key": key]) { _ in }
                }
                emit(["type": "sessions", "rows": rows.map(Gateway.trimRow)])
            } else {
                refreshSessions()
            }

        case "task":
            // One delegated task moved. The payload is the same shape tasks.list
            // returns, so it is patched into the same index rather than parsed
            // twice — and the whole index goes over, because the inbox has to
            // re-decide which tasks are roots after any of them changes.
            guard let id = payload["id"] as? String ?? payload["taskId"] as? String else { return }
            tasks[id] = Gateway.trimTask(payload)
            emit(["type": "tasks", "tasks": Array(tasks.values), "replace": true])

        case "question.requested":
            // The whole record, forwarded verbatim. Phase B emitted five
            // flattened fields, which was enough to prove the wire worked and
            // not enough to draw a question: the options — the thing the inbox
            // has to render as buttons — live inside `questions[]`.
            emit(["type": "questions", "questions": [payload], "replace": false])

        case "question.resolved":
            // Payload is { id, status, answers? } — not a record. It removes the
            // entry rather than updating one.
            emit(["type": "questionResolved",
                  "id": payload["id"] as? String ?? "",
                  "status": payload["status"] as? String ?? "answered"])

        case "shutdown":
            retry("the gateway is shutting down")

        default:
            break   // tick, health, heartbeat, presence, cron, task, node.* …
        }
    }

    // MARK: - the write path
    //
    // Phase B implemented this expecting to be REFUSED, and it was: the
    // connection held `operator.read`, the gateway answered FORBIDDEN / missing
    // scope: operator.write, and the UI drew that refusal with the scope and the
    // command on it.
    //
    // Phase C holds `operator.write`, so the same code now actually writes — and
    // the refusal path stays exactly as it was rather than being deleted. It is
    // still the correct rendering of any FORBIDDEN, and a scope can be revoked
    // as easily as it was granted; a client that only handles success handles
    // the wrong half.
    //
    // What this must never be is a silent no-op or a fake success. Nothing is
    // added to any transcript until the gateway says it landed, and every send
    // ends in a state that came back from the gateway.

    /// Steer or start a turn. `queueMode` is the distinction the UI draws:
    /// a message to a session with an active run is admitted to its pending
    /// queue; a reply to a stopped one lands immediately and starts a turn.
    func sendMessage(sessionKey: String, text: String, queueMode: String, requestId: String) {
        q.async {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // This used to `return` without a word. The page had ALREADY set
                // S.write to 'sending' in startWrite and armed the 31s timeout at
                // live.js:1291, so a whitespace-only send left the composer
                // spinning for half a minute and then blamed the gateway for a
                // message this process itself declined to send. Pass 6 found it
                // and left it for whoever had a build.
                //
                // Refuse it out loud. The write path's whole doctrine is that a
                // send ends in a stated result -- the same doctrine that makes a
                // cached `ok: true` a bug -- and "silently dropped" is the one
                // outcome the UI has no way to draw.
                self.emitWriteResult("chat.send", requestId, sessionKey, nil,
                                     ["code": "EMPTY_MESSAGE",
                                      "message": "nothing to send: the composer held only whitespace"])
                return
            }
            // `idempotencyKey` is REQUIRED, and Phase B did not send it. That was
            // invisible for as long as the connection held only operator.read,
            // because the scope check fires first and every send came back
            // FORBIDDEN — the exact refusal the UI was built to draw. The moment
            // operator.write landed, every send would instead have answered
            //
            //   INVALID_REQUEST: invalid chat.send params:
            //     must have required property 'idempotencyKey'
            //
            // which is a bug wearing a refusal's clothes. Probed against the live
            // gateway before this line was written, not inferred from a schema.
            //
            // The value doubles as the run id the gateway echoes back, so it is
            // the request id when there is one and a fresh uuid otherwise.
            let idem = requestId.isEmpty ? "bridge-\(UUID().uuidString.lowercased())" : requestId
            var params: [String: Any] = ["sessionKey": sessionKey, "message": text,
                                         "idempotencyKey": idem]
            if !queueMode.isEmpty { params["queueMode"] = queueMode }
            self.call("chat.send", params) { [weak self] payload, error in
                self?.emitWriteResult("chat.send", requestId, sessionKey, payload, error)
            }
        }
    }

    /// Stop a run now. Unlike a queued steer this is immediate — which is the
    /// whole reason the UI offers both.
    func abortRun(sessionKey: String, requestId: String) {
        q.async {
            self.call("chat.abort", ["sessionKey": sessionKey]) { [weak self] payload, error in
                self?.emitWriteResult("chat.abort", requestId, sessionKey, payload, error)
            }
        }
    }

    private func emitWriteResult(_ method: String, _ requestId: String, _ sessionKey: String,
                                 _ payload: [String: Any]?, _ error: [String: Any]?) {
        var msg: [String: Any] = ["type": "writeResult", "method": method,
                                  "requestId": requestId, "sessionKey": sessionKey]
        if let error {
            let details = error["details"] as? [String: Any] ?? [:]
            msg["ok"] = false
            msg["code"] = error["code"] as? String ?? "ERROR"
            msg["message"] = error["message"] as? String ?? "the gateway refused the request"
            // The specific field the UI turns into "approve this scope". Carried
            // separately from the message so the page is not regex-ing prose.
            if let m = details["missingScope"] as? String { msg["missingScope"] = m }
            if let r = details["requiredScopes"] as? [String] { msg["requiredScopes"] = r }
        } else {
            msg["ok"] = true
            // Which of the two states the message actually reached. The gateway
            // is the authority on this, not the row we happened to be showing.
            if let p = payload {
                if let q = p["queued"] as? Bool { msg["queued"] = q }
                if let id = p["messageId"] as? String { msg["messageId"] = id }
                if let st = p["status"] as? String { msg["status"] = st }
            }
            // Something changed; re-read rather than guess at the new transcript.
            scheduleHistory(sessionKey)
        }
        emit(msg)

        // A relay's result belongs to the ROOM as well as to the page. The room
        // is drawn from its own document, not from `writeResult`, so a relay
        // that never left the socket was displayed as a delivered hand-off
        // forever. `room-` is the prefix Room.deliver stamps on its request ids.
        if requestId.hasPrefix("room-") {
            let failed = error != nil
            let code = msg["code"] as? String ?? "ERROR"
            let text = msg["message"] as? String ?? ""
            DispatchQueue.main.async {
                if failed { Room.shared.sendFailed(requestId: requestId, code: code, message: text) }
                else { Room.shared.sendLanded(requestId: requestId) }
            }
        }
    }

    // MARK: - trimming
    //
    // A sessions.list row is ~4 KB and a session.tool event carries a full copy
    // of the row inside it. Sending all of that across the JS bridge on every
    // event would be most of the CPU this app spends. These keep the fields the
    // view layer's contract actually names, and nothing else.

    static let rowFields = [
        "key", "sessionId", "agentId", "label", "displayName", "category", "kind",
        "classification", "isMain", "isBackground", "archived", "status",
        "hasActiveRun", "hasActiveSubagentRun", "lastRunError", "abortedLastRun",
        "model", "modelProvider", "contextTokens", "totalTokens", "inputTokens",
        "outputTokens", "totalTokensFresh", "startedAt", "runtimeMs", "updatedAt",
        "parentSessionKey", "spawnedBy", "spawnDepth", "observerDigest", "cwd",
    ]

    static func trimRow(_ row: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in rowFields { if let v = row[k], !(v is NSNull) { out[k] = v } }
        return out
    }

    /// chat.history messages, with oversized content clipped. The pane shows a
    /// transcript, not a file viewer, and a 200 KB tool result is a stalled
    /// window rather than information.
    static let maxBlockChars = 4000

    static func trimMessage(_ m: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out["role"] = m["role"] ?? "assistant"
        out["timestamp"] = m["timestamp"] ?? 0
        if let s = m["content"] as? String {
            out["content"] = clip(s, maxBlockChars)
        } else if let blocks = m["content"] as? [[String: Any]] {
            out["content"] = blocks.map { b -> [String: Any] in
                var o: [String: Any] = ["type": b["type"] ?? "text"]
                if let t = b["text"] as? String { o["text"] = clip(t, maxBlockChars) }
                if let c = b["content"] as? String { o["content"] = clip(c, maxBlockChars) }
                if let c = b["content"] as? [[String: Any]] {
                    o["content"] = c.map { ["type": $0["type"] ?? "text",
                                            "text": clip($0["text"] as? String ?? "", maxBlockChars)] }
                }
                for k in ["id", "name", "tool_use_id", "toolCallId", "is_error"] {
                    if let v = b[k], !(v is NSNull) { o[k] = v }
                }
                if let a = b["arguments"] as? [String: Any] { o["arguments"] = trimArgs(a) }
                if let a = b["input"] as? [String: Any] { o["input"] = trimArgs(a) }
                return o
            }
        }
        return out
    }

    /// A task row, kept to the fields the inbox names. `lastActivity` is the
    /// agent's own last line and is what the completion summary prints, so it
    /// gets more room than a tool argument and less than a transcript.
    static let taskFields = [
        "id", "taskId", "kind", "runtime", "status", "title", "agentId",
        "sessionKey", "childSessionKey", "ownerKey", "runId",
        "createdAt", "updatedAt", "startedAt", "endedAt",
        "toolUseCount", "lastToolName", "error",
        // Terminal state. `terminalOutcome: "blocked"` with an `error` means the
        // task finished but its result never reached whoever asked for it —
        // which is precisely an inbox's business and is invisible from `status`
        // alone, since those rows still read `completed`.
        "terminalOutcome", "deliveryStatus",
    ]

    static func trimTask(_ t: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in taskFields { if let v = t[k], !(v is NSNull) { out[k] = v } }
        if out["id"] == nil, let tid = t["taskId"] { out["id"] = tid }
        // Three different fields, three different meanings, and Phase B's first
        // cut kept only the one that is never set on a finished task:
        //   lastActivity    — RUNNING tasks only. Absent once a task ends.
        //   progressSummary — the agent's OPENING note, not its conclusion.
        //   terminalSummary — set on 2 of 19 real rows, and in both it was a
        //                     delivery-failure notice rather than a summary.
        // None of them is reliably "what the task concluded", so live.js ranks
        // them and labels which one it ended up showing. See §I.
        if let a = t["lastActivity"] as? String { out["lastActivity"] = clip(a, 1200) }
        if let a = t["progressSummary"] as? String, !a.isEmpty { out["progressSummary"] = clip(a, 1200) }
        if let a = t["terminalSummary"] as? String, !a.isEmpty { out["terminalSummary"] = clip(a, 1200) }
        if let d = t["diffStat"] as? [String: Any] { out["diffStat"] = d }
        return out
    }

    static func trimArgs(_ args: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in args {
            if let s = v as? String { out[k] = clip(s, 2000) }
            else if v is NSNumber || v is Bool { out[k] = v }
            else if let d = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) {
                out[k] = clip(String(decoding: d, as: UTF8.self), 600)
            }
        }
        return out
    }

    static func trimResult(_ r: Any) -> String {
        if let s = r as? String { return clip(s, maxBlockChars) }
        if let d = try? JSONSerialization.data(withJSONObject: r, options: .fragmentsAllowed) {
            return clip(String(decoding: d, as: UTF8.self), maxBlockChars)
        }
        return String(describing: r)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n)) + "\n… \(s.count - n) more characters"
    }
}
