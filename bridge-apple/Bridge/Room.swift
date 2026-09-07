import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// BRIDGE IS THE ROOM.
//
// OpenClaw has no multi-agent room. A session belongs to exactly one agent, and
// an agent can only see its own transcript. So the room is not something the
// gateway provides and Bridge displays — Bridge *is* it, and this file is the
// whole of it.
//
// THE SHAPE
//
//   * One persistent session per agent, keyed `agent:<agentId>:bridge`. Not one
//     per task: clicking a tab returns to a live thread that remembers last
//     week. `chat.send` to a key that does not exist CREATES it (verified on the
//     live gateway before this was written — see PROTOCOL.md §11.1), so no
//     provisioning step is needed and none is attempted.
//   * ONE transcript, owned here, holding every turn regardless of who it was
//     addressed to. Pings decide who takes a turn; they do not decide who is
//     displayed. That distinction is Chancellor's spec and it is the reason the
//     room can exist at all.
//   * Bridge relays. The AGENTS DO NOT. Nothing in a lane calls a session tool.
//
// WHY THAT LAST POINT IS THE WHOLE DESIGN
//
// The obvious implementation is to turn on `tools.agentToAgent` and
// `tools.sessions.visibility: "all"` and let lanes message each other directly.
// That would grant every lane on the host cross-transcript read access to every
// other session, permanently, to buy a feature that is only about routing. Doing
// the routing HERE — in an operator client that already holds `operator.write`
// for exactly this — needs neither key, and neither is set. Bridge does not read
// or write the gateway's configuration.
//
// THE COSTS, NAMED
//
// A relay chain is agents spending money without a human in the loop, so both
// bounds are enforced here and both are printed into the room rather than
// applied quietly:
//
//   * hop depth — Chancellor's message is hop 0. Each relay adds one. At
//     `maxHops` the chain stops and says so in the transcript.
//   * rate — at most `maxRelaysPerWindow` automatic relays in a rolling window.
//     Tripping it pauses the room, which is a state you can see and undo.
//
// A silent cap would read as "the agents decided to stop", which is a lie about
// whose decision it was.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class Room {
    static let shared = Room()
    private init() { doc = Room.load() }

    /// One relayed turn, as the room remembers it.
    struct Msg: Codable, Equatable {
        var id: String
        var at: Double            // epoch ms
        var from: String          // "chancellor", an agent id, or "bridge" for a note
        /// The lanes this turn was handed to. A LIST, not one id: a reply can
        /// ping two teammates, and the hand-off is the single most important
        /// thing this transcript displays — collapsing it to the first target
        /// would silently lose the second.
        var to: [String] = []
        var text: String
        var kind: String          // "say" | "note" | "error"
        var hop: Int
    }

    struct Doc: Codable, Equatable {
        var version = 1
        var messages: [Msg] = []
        /// Room session key -> the transcript seq Bridge has already taken into
        /// the room. Persisted, so a relaunch does not replay a whole session's
        /// history back into the room as if it had just been said.
        var seen: [String: Int] = [:]
        /// Room session key -> turns delivered since the standing preamble was
        /// last sent. See `preamble` for why this is not sent every time.
        var since: [String: Int] = [:]
        /// Room session key -> hop depth of the last thing delivered there, so
        /// an agent's reply inherits its position in the chain.
        var hop: [String: Int] = [:]
        var paused = false
        var pauseReason: String = ""
    }

    private(set) var doc: Doc
    /// The real agent roster, from `agents.list`. Ping targets are matched
    /// against this rather than a hardcoded list, so a gateway that grows a
    /// tenth lane needs no code change.
    private(set) var agents: [(id: String, name: String)] = []

    /// Chancellor's message is hop 0. His stated chain — he pings frontend,
    /// frontend pings backend, backend pings full-stack, full-stack reviews —
    /// is hop 3, so this leaves headroom above the workflow it has to support
    /// without leaving the ceiling effectively absent.
    static let maxHops = 6
    static let maxRelaysPerWindow = 14
    static let relayWindow: TimeInterval = 300
    /// Re-anchor the standing preamble every N delivered turns. Context gets
    /// compacted; a convention stated once at the top of a long session is a
    /// convention that eventually is not in context at all.
    static let reanchorEvery = 20
    static let maxMessages = 600

    private var relayTimes: [Date] = []
    private var seq = 0

    /// `--room-probe` runs a SECOND Bridge process against the same gateway and
    /// the same `room.json` while the real app is open on the desk. Measuring
    /// subscriptions must not cost a turn or a byte: with this set, `observe`
    /// takes nothing in, relays nothing, and `save` writes nothing. A diagnostic
    /// that can start a relay chain is not a diagnostic.
    var readOnlyProbe = false

    /// requestId -> the lane the send was addressed to, for the window between
    /// handing a relay to Gateway and hearing whether it landed. Bounded by
    /// `maxInflight`: a write that never answers times out in 30s, so this holds
    /// seconds of traffic, and dropping the oldest is better than growing
    /// without limit in a process that runs for weeks.
    private var inflight: [(id: String, target: String)] = []
    private static let maxInflight = 64

    // MARK: - keys and roster

    // `nonisolated`: both are pure string functions with no state behind them,
    // and Gateway calls them from its own serial queue on every history
    // backfill. Hopping to the main actor to concatenate a string would put a
    // main-thread await in the hot path of every session's transcript.
    nonisolated static func key(_ agentId: String) -> String { "agent:\(agentId):bridge" }
    nonisolated static func agentId(fromRoomKey key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "agent", parts[2] == "bridge" else { return nil }
        return parts[1]
    }
    var keys: [String] { agents.map { Room.key($0.id) } }

    func setAgents(_ list: [(id: String, name: String)]) {
        agents = list
        push()
    }
    func name(_ id: String) -> String {
        agents.first { $0.id == id }?.name ?? id
    }

    // MARK: - the standing preamble
    //
    // Prepended to a relayed turn so an agent knows the convention it is inside:
    // who else is here, what @ means, and that Bridge — not the agent — moves
    // messages. It is deliberately one paragraph: it rides on every anchored
    // turn and every word is billed.
    //
    // It is NOT sent on every message. The session is persistent, so the
    // convention is already in context after the first turn; re-sending it 40
    // times would cost more than the conversation. It goes out on the first
    // message to a session and every `reanchorEvery` turns after that, which
    // covers the real failure mode — a compaction dropping the top of the
    // window — without paying for it constantly.

    func preamble(for target: String) -> String {
        let others = agents.map { $0.id == "main" ? "main (Thuban)" : $0.id }.joined(separator: ", ")
        return "[Bridge room] You are in a shared room with Chancellor and: \(others). "
            + "Everything said here is shown to him in one transcript. To hand work to a "
            + "teammate, write @<agent-id> anywhere in your reply — Bridge relays your message "
            + "to them and they take the next turn. A reply with no @ goes to Chancellor only. "
            + "Bridge does the routing: do not call session, spawn or messaging tools for this."
    }

    // MARK: - sending

    /// Deliver one turn into a target agent's room session, and record it.
    ///
    /// `from` is "chancellor" or the agent id that produced the text. Returns
    /// the wire text actually sent, which is what the smoke test asserts on.
    @discardableResult
    func deliver(to target: String, from sender: String, text: String, hop: Int,
                 record: Bool = true) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        guard agents.contains(where: { $0.id == target }) else {
            note("No agent id '\(target)' on this gateway — nothing was sent.", kind: "error")
            return nil
        }
        let roomKey = Room.key(target)
        let n = (doc.since[roomKey] ?? Room.reanchorEvery)          // unseen session -> anchor
        let anchor = n >= Room.reanchorEvery
        let who = sender == "chancellor" ? "Chancellor" : "\(name(sender)) (@\(sender))"
        let header = "[room] \(who) → @\(target)"
        let wire = (anchor ? preamble(for: target) + "\n\n" : "") + header + "\n" + body

        if record {
            append(Msg(id: newId(), at: Date().timeIntervalSince1970 * 1000,
                       from: sender, to: [target], text: body, kind: "say", hop: hop))
        }
        doc.since[roomKey] = anchor ? 1 : n + 1
        doc.hop[roomKey] = hop
        save()

        let reqId = "room-\(newId())"
        inflight.append((id: reqId, target: target))
        if inflight.count > Room.maxInflight { inflight.removeFirst(inflight.count - Room.maxInflight) }
        Gateway.shared.sendMessage(sessionKey: roomKey, text: wire, queueMode: "",
                                   requestId: reqId)
        push()
        return wire
    }

    /// Chancellor typed in the room. No ping means `main` — Thuban sees every
    /// unpinged message and nothing else does; a ping means that lane, and main
    /// does NOT see it. That asymmetry is the spec, verbatim.
    func fromChancellor(text: String, ping: String?) {
        let target = ping ?? "main"
        deliver(to: target, from: "chancellor", text: text, hop: 0)
    }

    // MARK: - receiving
    //
    // Gateway hands every room session's backfilled transcript here. Anything
    // with a seq above the high-water mark is a turn the room has not taken in
    // yet: it goes into the transcript, and its pings are relayed.
    //
    // Working from the BACKFILL rather than from live `session.message` events
    // is deliberate and matches the rest of the app (PROTOCOL.md §6): the event
    // stream drops frames for slow subscribers, so a relay driven by events
    // would silently miss turns. chat.history is the authority.

    func observe(key: String, messages: [[String: Any]]) {
        guard !readOnlyProbe else { return }
        guard let lane = Room.agentId(fromRoomKey: key) else { return }
        let high = doc.seen[key]
        var maxSeq = high ?? 0
        var fresh: [(Int, String)] = []

        for m in messages {
            guard (m["role"] as? String) == "assistant" else { continue }
            let meta = m["__openclaw"] as? [String: Any] ?? [:]
            let s = meta["seq"] as? Int ?? 0
            maxSeq = max(maxSeq, s)
            guard let high, s > high else { continue }
            let text = Room.plainText(m)
            if !text.isEmpty { fresh.append((s, text)) }
        }

        // FIRST SIGHT OF A SESSION. Seed the high-water mark and emit nothing.
        // Without this, launching Bridge against a session that already has 40
        // turns would pour all 40 into the room, re-fire every ping in them, and
        // start a relay storm out of history. That is not a hypothetical: the
        // probe session this feature was verified against already had turns in
        // it before the room existed.
        if high == nil {
            doc.seen[key] = maxSeq
            save()
            return
        }

        guard !fresh.isEmpty else { return }
        doc.seen[key] = maxSeq

        let hop = doc.hop[key] ?? 0
        for (_, text) in fresh {
            // Targets are resolved BEFORE the row is appended so the row itself
            // carries the hand-off. The relay below then delivers without
            // recording a second row: the agent said one thing, and who it was
            // given to is a property of that thing rather than a separate event.
            // Written the other way round first, and agent-to-agent hand-offs —
            // the entire point of the room — rendered with no target chip at all.
            let targets = Room.pings(in: text, agents: agents.map { $0.id }, excluding: lane)
            append(Msg(id: newId(), at: Date().timeIntervalSince1970 * 1000,
                       from: lane, to: targets, text: text, kind: "say", hop: hop))
            relayPings(in: text, from: lane, hop: hop)
        }
        save()
        push()
    }

    /// Everything the agent addressed, in the order it addressed it.
    nonisolated static func pings(in text: String, agents: [String], excluding self_: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "@([A-Za-z][A-Za-z0-9-]{1,39})") else { return [] }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // Trailing hyphens are stripped, then the handle must match an agent
            // id EXACTLY.
            //
            // This was `raw == $0 || raw.hasPrefix($0)` against a longest-first
            // sort. The sort was there so "@full-stack" would not be taken as
            // "@full" — but the sort alone does that, and the hasPrefix it was
            // guarding turned every agent id into a live prefix of any longer
            // word. "@maintainer", "@mainline", "@coursework-notes" each
            // resolved to a real lane, and a false positive here is not a
            // cosmetic error: it hands an agent's whole reply to a lane nobody
            // addressed, which spends a turn and starts a relay chain.
            //
            // The token is already delimited by the regex, whose class stops at
            // anything that is not a letter, digit or hyphen — so "@main." and
            // "@main," and "@main's" all arrive here as "main" without any help
            // from prefix matching. A trailing hyphen is the one separator the
            // class swallows, so it is trimmed rather than left to fail.
            let raw = ns.substring(with: m.range(at: 1)).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard let hit = agents.first(where: { raw == $0 }) else { continue }
            if hit == self_ || out.contains(hit) { continue }
            out.append(hit)
        }
        return out
    }

    private func relayPings(in text: String, from lane: String, hop: Int) {
        let targets = Room.pings(in: text, agents: agents.map { $0.id }, excluding: lane)
        guard !targets.isEmpty else { return }

        if doc.paused {
            note("\(name(lane)) pinged \(targets.map { "@" + $0 }.joined(separator: ", ")), but the "
                 + "room is paused, so nothing was relayed. Resume to hand the work over.", kind: "note")
            return
        }
        if hop + 1 > Room.maxHops {
            note("\(name(lane)) pinged \(targets.map { "@" + $0 }.joined(separator: ", ")) at hop "
                 + "\(hop + 1), past the \(Room.maxHops)-hop ceiling. The chain stops here — send it "
                 + "on yourself if that is what you want.", kind: "note")
            return
        }
        // Rolling-window rate limit. Tripping it pauses the room rather than
        // dropping one message: a chain that is running away does not get better
        // by having a hole punched in it.
        let cutoff = Date().addingTimeInterval(-Room.relayWindow)
        relayTimes.removeAll { $0 < cutoff }
        if relayTimes.count + targets.count > Room.maxRelaysPerWindow {
            doc.paused = true
            doc.pauseReason = "\(Room.maxRelaysPerWindow) relays in \(Int(Room.relayWindow / 60)) minutes"
            note("Relay paused: \(Room.maxRelaysPerWindow) automatic hand-offs in "
                 + "\(Int(Room.relayWindow / 60)) minutes. \(name(lane))'s ping to "
                 + "\(targets.map { "@" + $0 }.joined(separator: ", ")) was not sent. Resume in the "
                 + "room header when you have read what happened.", kind: "error")
            save(); push()
            return
        }
        for t in targets {
            relayTimes.append(Date())
            // `record: false` — the agent's own turn is already in the
            // transcript above; a relay is a delivery of it, not a second thing
            // said. The row it produced carries the ping in its own text.
            deliver(to: t, from: lane, text: text, hop: hop + 1, record: false)
        }
    }

    /// The assistant's prose for one message, tool blocks and thinking dropped.
    /// Thinking is private reasoning and is never relayed anywhere — the same
    /// rule live.js applies to the transcript, for the same reason.
    nonisolated static func plainText(_ m: [String: Any]) -> String {
        if let s = m["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = m["content"] as? [[String: Any]] else { return "" }
        return blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - did it actually land?
    //
    // `deliver` records the turn, hands the wire text to Gateway and returned.
    // That was the whole of it, and it was a fake success in the one file whose
    // stated doctrine is that a send is never one: with the socket down the
    // frame is dropped, `call` times out thirty seconds later into a
    // `writeResult` that goes to the PAGE, and the room went on displaying a
    // hand-off — with a target chip on it — that had reached nobody. The agent
    // it names never got the message and nothing on screen said so.
    //
    // Gateway now routes every `room-…` write result back here.

    func sendLanded(requestId: String) {
        inflight.removeAll { $0.id == requestId }
    }

    func sendFailed(requestId: String, code: String, message: String) {
        let target = inflight.first { $0.id == requestId }?.target
        inflight.removeAll { $0.id == requestId }
        let who = target.map { "@" + $0 } ?? "its target"
        note("Not delivered to \(who) — \(code): \(message). The turn above is in this "
             + "transcript but never reached the gateway. Send it again once the connection "
             + "is back.", kind: "error")
    }

    // MARK: - controls

    func setPaused(_ p: Bool) {
        doc.paused = p
        doc.pauseReason = p ? "paused by hand" : ""
        if !p { relayTimes.removeAll() }
        note(p ? "Relay paused. Your own messages still send; agent-to-agent hand-offs do not."
               : "Relay resumed.", kind: "note")
    }

    /// Replace the whole document. Exists for the smoke test, which exercises
    /// the first-sight seeding against the REAL store and must put Chancellor's
    /// actual room back exactly as it found it — the same discipline the prefs
    /// round-trip check already follows.
    func restore(_ d: Doc) { doc = d; save(); push() }

    func clear() {
        // The high-water marks are KEPT. Clearing the room empties what is on
        // screen; it must not make Bridge re-read every session's history back
        // in as new, which is what dropping `seen` would do.
        doc.messages = []
        save(); push()
    }

    func note(_ text: String, kind: String) {
        append(Msg(id: newId(), at: Date().timeIntervalSince1970 * 1000,
                   from: "bridge", to: [], text: text, kind: kind, hop: 0))
        save(); push()
    }

    private func append(_ m: Msg) {
        doc.messages.append(m)
        if doc.messages.count > Room.maxMessages {
            doc.messages.removeFirst(doc.messages.count - Room.maxMessages)
        }
    }

    /// A room id is a message id AND — through `deliver`'s `room-<id>` request
    /// id — the gateway's `chat.send` idempotencyKey, which the gateway turns
    /// into the run id verbatim and caches under `chat:<runId>` with no session
    /// in the key. `seq` restarts at 1 in every process, so two Bridge processes
    /// in the same second (the real app and `--room-probe`, which is exactly how
    /// this app is diagnosed) minted the same key, and the second send would be
    /// answered `ok: true` from cache without ever being delivered. The nonce is
    /// per-process; the second and the counter stay because they make the id
    /// sortable and readable in `room.json`.
    private static let idNonce = String(UUID().uuidString.prefix(8)).lowercased()
    /// The smoke suite asserts the nonce is really in the id; `newId` is private
    /// because nothing else may mint one.
    func debugNewId() -> String { newId() }

    private func newId() -> String {
        seq += 1
        return "\(Int(Date().timeIntervalSince1970))-\(seq)-\(Room.idNonce)"
    }

    // MARK: - the page

    func push() {
        ActiveWebView.shared.emit([
            "type": "room",
            "messages": doc.messages.map { [
                "id": $0.id, "at": $0.at, "from": $0.from,
                "to": $0.to, "text": $0.text, "kind": $0.kind, "hop": $0.hop,
            ] },
            "paused": doc.paused,
            "pauseReason": doc.pauseReason,
            "agents": agents.map { ["id": $0.id, "name": $0.name, "key": Room.key($0.id)] },
            "maxHops": Room.maxHops,
            "relayWindowMin": Int(Room.relayWindow / 60),
            "maxRelays": Room.maxRelaysPerWindow,
            "relaysInWindow": relayTimes.filter { $0 > Date().addingTimeInterval(-Room.relayWindow) }.count,
        ])
    }

    // MARK: - store
    //
    // Its own document, not a field in prefs.json: the room grows on every turn
    // and prefs is written on every roster click. One file that is both would
    // rewrite hundreds of messages to record a checkbox, and lose the room to a
    // malformed prefs payload. Same atomic-write rule as Prefs.

    static var url: URL { Prefs.directory.appendingPathComponent("room.json") }

    private static func load() -> Doc {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Doc.self, from: $0) } ?? Doc()
    }

    func save() {
        guard !readOnlyProbe else { return }
        var scratch: URL?
        do {
            try FileManager.default.createDirectory(at: Prefs.directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(doc)
            let tmp = Prefs.directory.appendingPathComponent("room.json.tmp-\(UUID().uuidString.prefix(8))")
            scratch = tmp
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(Room.url, withItemAt: tmp)
        } catch {
            // Same as Prefs: a failed rename leaves the scratch file behind, and
            // the room saves on every turn — so a directory that is failing
            // would accumulate one per message rather than one per session.
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            NSLog("bridge: room save failed: \(error.localizedDescription)")
        }
    }
}
