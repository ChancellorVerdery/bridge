import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// BRIDGE IS THE ROOM, AND THERE IS ONE ROOM PER PROJECT.
//
// OpenClaw has no multi-agent room. A session belongs to exactly one agent, and
// an agent can only see its own transcript. So the room is not something the
// gateway provides and Bridge displays — Bridge *is* it, and this file is the
// whole of it.
//
// THE SHAPE
//
//   * THE PROJECT IS THE UNIT OF ISOLATION, and CHANCELLOR DECIDES WHO IS IN
//     ONE. Each project carries an ACCESS LIST — the agents he has allowed in —
//     and a set of launched CLONES drawn from it. `frontend-design` in Bridge
//     and `frontend-design` in CalcNotes are two separate sessions under two
//     separate keys, alive at the same time, sharing no transcript.
//
//     A project does NOT hold a clone of every agent. That was the previous
//     pass's assumption and it was wrong: his own preference document rostered
//     seven agents in Bridge and one in Atlas. Access is his; launching brings
//     a clone into being; and after a task he either kills the clone or leaves
//     it idle. See `launch`, `setIdle` and `kill` below.
//
//         agent:<agentId>:bridge:<projectId>
//
//     `chat.send` to a key that does not exist CREATES it (verified on the live
//     gateway — see PROTOCOL.md §11.1), so cloning needs no provisioning step
//     and none is attempted. Launching a clone is therefore exactly: record it,
//     and let the first delivered turn bring the session into being.
//
//   * ONE TRANSCRIPT PER PROJECT, owned here, holding every turn in that
//     project regardless of who it was addressed to. Pings decide who takes a
//     turn; they do not decide who is displayed. That distinction is
//     Chancellor's spec and it is the reason the room can exist at all.
//
//   * A PROJECT'S `main` TAB *IS* THAT PROJECT'S ROOM. It is the first tab, it
//     is where Chancellor talks to the project, and it is where the project's
//     agents talk to each other. There is no global room and no Room entry in
//     the sidebar: a room belongs to a project now.
//
//   * AN AGENT CAN ONLY REACH AGENTS INSIDE ITS OWN PROJECT. `deliver` refuses
//     a target that is not in that project's ACCESS LIST, and a ping is resolved
//     against the access list of the project the ping was said in — never
//     against the gateway's whole agent list. There is no cross-project
//     messaging and no way to ask for one.
//
//   * Bridge relays. The AGENTS DO NOT. Nothing in a lane calls a session tool.
//
// MEMORY AND IDENTITY ARE PER AGENT TYPE, NOT PER PROJECT
//
// Every clone of the same agent writes the SAME two files, wherever it is
// running:
//
//     ~/.openclaw/workspace/memory/bridge/<agentId>/SOUL.md
//     ~/.openclaw/workspace/memory/bridge/<agentId>/MEMORY.md
//
// `frontend-design` in Bridge and `frontend-design` in CalcNotes are separate
// SESSIONS with separate transcripts, and they are the same AGENT: one identity,
// one accumulated memory, read and appended by both. A lane that learned
// something in one project knows it in the next.
//
// This is the correction that defines v3. The previous pass gave each clone a
// file scoped to (project, agent) — a private memory per project — which made
// the same agent nine strangers who happened to share a name, and meant nothing
// any of them learned survived being asked to work somewhere else. Isolation is
// about TRANSCRIPT AND REACH. It was never meant to be about identity.
//
// A third file stays as it was, and is deliberately common to everyone:
//
//     ~/.openclaw/workspace/memory/bridge/SHARED.md
//
// read and appended by every agent in every project, so a lane knows the other
// projects exist. Bridge does not own the contents of any of these — the agents
// read and append with their own file tools, on the gateway host where they
// actually run. All this file does is name the paths in the standing preamble,
// which is the only place a clone could learn them.
//
// WHY BRIDGE RELAYS RATHER THAN THE AGENTS
//
// The obvious implementation is to turn on `tools.agentToAgent` and
// `tools.sessions.visibility: "all"` and let lanes message each other directly.
// That would grant every lane on the host cross-transcript read access to every
// other session, permanently, to buy a feature that is only about routing — and
// it would blow a hole straight through project isolation, because visibility
// "all" does not know what a project is. Doing the routing HERE — in an operator
// client that already holds `operator.write` for exactly this — needs neither
// key, and neither is set. Bridge does not read or write the gateway's
// configuration.
//
// THE COSTS, NAMED
//
// A relay chain is agents spending money without a human in the loop, so both
// bounds are enforced here and both are printed into the room rather than
// applied quietly:
//
//   * hop depth — Chancellor's message is hop 0. Each relay adds one. At
//     `maxHops` the chain stops and says so in the transcript.
//   * rate — at most `maxRelaysPerWindow` automatic relays in a rolling window,
//     COUNTED PER PROJECT. A runaway chain in one project pauses that project
//     and leaves the others alone; a shared counter would let one project's
//     accident silence work Chancellor is doing somewhere else.
//
// A silent cap would read as "the agents decided to stop", which is a lie about
// whose decision it was.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class Room {
    static let shared = Room()
    private init() { store = Room.load() }

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

    /// One project's room. The fields that used to be the whole document are
    /// now per-project, which is what isolation means here: a paused relay, a
    /// high-water mark and a hop depth in one project say nothing about another.
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

    /// The whole store: one `Doc` per project id.
    ///
    /// Keyed by project rather than held as a list so a project that has never
    /// been spoken in costs nothing, and so removing a project is a dictionary
    /// removal rather than a search. v1's single-document `room.json` decodes
    /// into `legacy`, which is reported once and then dropped — see `load`.
    struct Store: Codable, Equatable {
        var version = Room.storeVersion
        var rooms: [String: Doc] = [:]
    }

    private(set) var store: Store

    /// Every agent the gateway defines, from `agents.list`. This is the menu
    /// Chancellor picks a project's access list FROM; it is never the access
    /// list itself, and a ping is resolved against the project's, not this.
    private(set) var agents: [(id: String, name: String)] = []

    /// The projects, mirrored from Prefs so routing can answer "is this target
    /// in this project" without reaching into the preference store on every
    /// relayed turn. Set by `setProjects`; Prefs remains the owner.
    private(set) var projects: [Prefs.Project] = []

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
    /// `nonisolated` because `Store`'s default value reads it, and a struct's
    /// memberwise default is evaluated outside the actor. Isolating a constant
    /// integer buys nothing and is an error under the Swift 6 language mode.
    nonisolated static let storeVersion = 2

    /// Where an agent's identity and memory live, on the gateway host where the
    /// agents run. Bridge is on the Mac and never touches these files; it only
    /// tells each clone the paths, because the preamble is the only channel
    /// through which a clone could learn them.
    ///
    /// KEYED BY AGENT, NOT BY (PROJECT, AGENT). Every clone of an agent gets the
    /// same two paths in every project, which is what makes them one agent with
    /// one memory rather than a name shared by strangers.
    static let memoryRoot = "~/.openclaw/workspace/memory/bridge"
    static var sharedMemoryPath: String { "\(memoryRoot)/SHARED.md" }
    static func soulPath(agent: String) -> String { "\(memoryRoot)/\(agent)/SOUL.md" }
    static func memoryPath(agent: String) -> String { "\(memoryRoot)/\(agent)/MEMORY.md" }

    /// Per project, so one project's runaway chain cannot pause another.
    private var relayTimes: [String: [Date]] = [:]
    private var seq = 0

    /// `--room-probe` runs a SECOND Bridge process against the same gateway and
    /// the same `room.json` while the real app is open on the desk. Measuring
    /// subscriptions must not cost a turn or a byte: with this set, `observe`
    /// takes nothing in, relays nothing, and `save` writes nothing. A diagnostic
    /// that can start a relay chain is not a diagnostic.
    var readOnlyProbe = false

    /// requestId -> the (project, lane) the send was addressed to, for the
    /// window between handing a relay to Gateway and hearing whether it landed.
    /// Bounded by `maxInflight`: a write that never answers times out in 30s, so
    /// this holds seconds of traffic, and dropping the oldest is better than
    /// growing without limit in a process that runs for weeks.
    private var inflight: [(id: String, project: String, target: String)] = []
    private static let maxInflight = 64

    // MARK: - keys, access and clones

    // `nonisolated`: both are pure string functions with no state behind them,
    // and Gateway calls them from its own serial queue on every history
    // backfill. Hopping to the main actor to concatenate a string would put a
    // main-thread await in the hot path of every session's transcript.

    /// The clone's session key. The project is the LAST component, so two
    /// projects holding the same agent are two different sessions and the
    /// gateway keeps them apart for us.
    nonisolated static func key(_ agentId: String, project: String) -> String {
        "agent:\(agentId):bridge:\(project)"
    }

    /// `(agentId, projectId)` for a Bridge room key, or nil for anything else —
    /// including a v1 three-part key, which is no longer a room key at all.
    nonisolated static func route(fromRoomKey key: String) -> (agent: String, project: String)? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "agent", parts[2] == "bridge" else { return nil }
        guard !parts[1].isEmpty, !parts[3].isEmpty else { return nil }
        return (agent: parts[1], project: parts[3])
    }

    /// Every clone session Bridge needs to watch: each project's `main` — whose
    /// session is the room and always exists — plus the clones actually launched
    /// there. This is what Gateway subscribes to.
    ///
    /// Drawn from `clones` rather than from `access`, because access is a
    /// permission and a subscription is a claim that a session exists. An agent
    /// Chancellor has allowed in but never launched has no session to watch.
    var keys: [String] {
        projects.flatMap { p in
            [Room.key("main", project: p.id)] + p.clones.map { Room.key($0.id, project: p.id) }
        }
    }

    func setAgents(_ list: [(id: String, name: String)]) {
        agents = list
        push()
    }

    /// Mirror the projects from Prefs, and drop the rooms of projects that no
    /// longer exist. Removing a project removes its transcript with it: the
    /// project was the thing that owned it, and leaving orphan documents behind
    /// would mean a project recreated under the same name silently inherits a
    /// conversation from a previous life.
    func setProjects(_ list: [Prefs.Project]) {
        projects = list
        let live = Set(list.map { $0.id })
        let stale = store.rooms.keys.filter { !live.contains($0) }
        if !stale.isEmpty {
            for id in stale { store.rooms.removeValue(forKey: id) }
            for id in stale { relayTimes.removeValue(forKey: id) }
            save()
        }
        push()
    }

    func project(_ id: String) -> Prefs.Project? { projects.first { $0.id == id } }

    /// The agents a message said inside `project` is allowed to reach: the
    /// access list Chancellor set. Empty for an unknown project, which is what
    /// makes an unknown project unroutable rather than unrestricted.
    func access(of project: String) -> [String] { self.project(project)?.access ?? [] }

    /// The clones actually launched in `project`, in tab order. `main` is not
    /// among them — its session is the room.
    func clones(of project: String) -> [Prefs.Clone] { self.project(project)?.clones ?? [] }

    /// The tabs a project shows: `main` first, because the room IS main's tab,
    /// then one per launched clone. An agent with access but no clone has no tab
    /// and no session; that is the difference between being allowed in and being
    /// here.
    func tabs(of project: String) -> [String] {
        ["main"] + clones(of: project).map { $0.id }
    }

    /// "active", "idle", or nil when this agent is not launched here. `main` is
    /// always active: the room cannot be parked.
    func cloneState(_ agentId: String, project: String) -> String? {
        if agentId == "main" { return self.project(project) == nil ? nil : Prefs.Clone.active }
        return self.project(project)?.cloneState(agentId)
    }

    func isLaunched(_ agentId: String, project: String) -> Bool {
        cloneState(agentId, project: project) != nil
    }

    func name(_ id: String) -> String {
        agents.first { $0.id == id }?.name ?? id
    }
    func projectName(_ id: String) -> String { project(id)?.name ?? id }

    func doc(_ project: String) -> Doc { store.rooms[project] ?? Doc() }
    private func mutate(_ project: String, _ body: (inout Doc) -> Void) {
        var d = store.rooms[project] ?? Doc()
        body(&d)
        store.rooms[project] = d
    }

    // MARK: - the standing preamble
    //
    // Prepended to a relayed turn so a clone knows the convention it is inside:
    // which project it is in, who else is in that project, what @ means, that
    // Bridge — not the agent — moves messages, and where its two memory files
    // are. It is deliberately compact: it rides on every anchored turn and every
    // word is billed.
    //
    // It is NOT sent on every message. The session is persistent, so the
    // convention is already in context after the first turn; re-sending it 40
    // times would cost more than the conversation. It goes out on the first
    // message to a session and every `reanchorEvery` turns after that, which
    // covers the real failure mode — a compaction dropping the top of the
    // window — without paying for it constantly.

    func preamble(for target: String, project: String) -> String {
        let mates = access(of: project)
            .filter { $0 != target }
            .map { $0 == "main" ? "main (Thuban)" : $0 }
            .joined(separator: ", ")
        let pname = projectName(project)
        let others = mates.isEmpty ? "no other agents yet" : mates
        return "[Bridge room · project \(pname)] You are the \(target) agent working in the "
            + "project \(pname), in a shared room with Chancellor and: \(others). Everything said "
            + "here is shown to him in one transcript. To hand work to a teammate, write "
            + "@<agent-id> anywhere in your reply — Bridge relays your message to them and they "
            + "take the next turn. A reply with no @ goes to Chancellor only. Bridge does the "
            + "routing: do not call session, spawn or messaging tools for this. "
            + "YOU CAN ONLY REACH AGENTS IN \(pname) — an @ for anyone else is not delivered, and "
            + "there is no way to message another project. "
            + "MEMORY: \(Room.soulPath(agent: target)) is who you are and "
            + "\(Room.memoryPath(agent: target)) is what you have learned. BOTH ARE SHARED BY EVERY "
            + "CLONE OF \(target) IN EVERY PROJECT — the same two files you write when you work "
            + "anywhere else, so read them when you start and append what a future you would need, "
            + "wherever it is working. \(Room.sharedMemoryPath) is shared by every agent in every "
            + "project — read it to learn what the other projects are doing, and append anything "
            + "they should know. Create any of these if it is not there yet."
    }

    // MARK: - sending

    /// Deliver one turn into a target clone's session, and record it.
    ///
    /// `from` is "chancellor" or the agent id that produced the text. Returns
    /// the wire text actually sent, which is what the smoke test asserts on.
    @discardableResult
    func deliver(to target: String, project: String, from sender: String, text: String,
                 hop: Int, record: Bool = true) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        guard self.project(project) != nil else {
            NSLog("bridge: refused a room delivery into unknown project '\(project)'")
            return nil
        }
        // ISOLATION, ENFORCED AT THE ONLY DOOR. Every send — Chancellor's, a
        // relay, a smoke assertion — comes through here, so a target outside
        // this project's access list is unreachable by construction rather than
        // by every caller remembering to check.
        guard access(of: project).contains(target) else {
            note("@\(target) does not have access to \(projectName(project)), so nothing was sent. "
                 + "Agents can only reach agents inside their own project, and only the ones "
                 + "Chancellor has let into it.",
                 project: project, kind: "error")
            return nil
        }
        // DELIVERING TO AN AGENT LAUNCHES IT. Access is the authorisation and
        // Chancellor already gave it; requiring him to also press Launch before
        // any teammate could be handed work would make the room unusable for the
        // one thing it exists to do. A ping to a clone he has parked wakes it,
        // for the same reason — "idle" is a rest state, not a refusal.
        launchIfNeeded(target, project: project)
        let roomKey = Room.key(target, project: project)
        let d = doc(project)
        let n = (d.since[roomKey] ?? Room.reanchorEvery)          // unseen session -> anchor
        let anchor = n >= Room.reanchorEvery
        let who = sender == "chancellor" ? "Chancellor" : "\(name(sender)) (@\(sender))"
        let header = "[room · \(projectName(project))] \(who) → @\(target)"
        let wire = (anchor ? preamble(for: target, project: project) + "\n\n" : "") + header + "\n" + body

        if record {
            append(Msg(id: newId(), at: Date().timeIntervalSince1970 * 1000,
                       from: sender, to: [target], text: body, kind: "say", hop: hop),
                   project: project)
        }
        mutate(project) {
            $0.since[roomKey] = anchor ? 1 : n + 1
            $0.hop[roomKey] = hop
        }
        save()

        let reqId = "room-\(newId())"
        inflight.append((id: reqId, project: project, target: target))
        if inflight.count > Room.maxInflight { inflight.removeFirst(inflight.count - Room.maxInflight) }
        Gateway.shared.sendMessage(sessionKey: roomKey, text: wire, queueMode: "",
                                   requestId: reqId)
        push()
        return wire
    }

    /// Chancellor typed in a project's room. No ping means that project's own
    /// `main` clone — Thuban sees every unpinged message in this project and
    /// nothing else does; a ping means that lane, and main does NOT see it. That
    /// asymmetry is the spec, verbatim, now scoped to one project.
    func fromChancellor(text: String, ping: String?, project: String) {
        let target = ping ?? "main"
        deliver(to: target, project: project, from: "chancellor", text: text, hop: 0)
    }

    // MARK: - receiving
    //
    // Gateway hands every clone session's backfilled transcript here. Anything
    // with a seq above the high-water mark is a turn that project's room has not
    // taken in yet: it goes into that project's transcript, and its pings are
    // relayed inside that project.
    //
    // Working from the BACKFILL rather than from live `session.message` events
    // is deliberate and matches the rest of the app (PROTOCOL.md §6): the event
    // stream drops frames for slow subscribers, so a relay driven by events
    // would silently miss turns. chat.history is the authority.

    func observe(key: String, messages: [[String: Any]]) {
        guard !readOnlyProbe else { return }
        guard let r = Room.route(fromRoomKey: key) else { return }
        let lane = r.agent, project = r.project
        // A clone whose project has been removed is not ours to take in. Its
        // session may still exist on the gateway; its room does not.
        guard self.project(project) != nil else { return }
        let high = doc(project).seen[key]
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
            mutate(project) { $0.seen[key] = maxSeq }
            save()
            return
        }

        guard !fresh.isEmpty else { return }
        mutate(project) { $0.seen[key] = maxSeq }

        let hop = doc(project).hop[key] ?? 0
        for (_, text) in fresh {
            // Targets are resolved BEFORE the row is appended so the row itself
            // carries the hand-off. The relay below then delivers without
            // recording a second row: the agent said one thing, and who it was
            // given to is a property of that thing rather than a separate event.
            // Written the other way round first, and agent-to-agent hand-offs —
            // the entire point of the room — rendered with no target chip at all.
            //
            // Resolved against THIS PROJECT'S ROSTER, which is what stops an
            // agent reaching out of its project by naming a lane that exists
            // somewhere else on the gateway.
            let targets = Room.pings(in: text, agents: access(of: project), excluding: lane)
            append(Msg(id: newId(), at: Date().timeIntervalSince1970 * 1000,
                       from: lane, to: targets, text: text, kind: "say", hop: hop),
                   project: project)
            relayPings(in: text, from: lane, project: project, hop: hop)
        }
        save()
        push()
    }

    /// Everything the agent addressed, in the order it addressed it. `agents` is
    /// the caller's allowed set — for a relay that is the project's access list,
    /// and a handle naming a lane outside it simply does not match.
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

    private func relayPings(in text: String, from lane: String, project: String, hop: Int) {
        let targets = Room.pings(in: text, agents: access(of: project), excluding: lane)
        guard !targets.isEmpty else { return }

        if doc(project).paused {
            note("\(name(lane)) pinged \(targets.map { "@" + $0 }.joined(separator: ", ")), but the "
                 + "room is paused, so nothing was relayed. Resume to hand the work over.",
                 project: project, kind: "note")
            return
        }
        if hop + 1 > Room.maxHops {
            note("\(name(lane)) pinged \(targets.map { "@" + $0 }.joined(separator: ", ")) at hop "
                 + "\(hop + 1), past the \(Room.maxHops)-hop ceiling. The chain stops here — send it "
                 + "on yourself if that is what you want.", project: project, kind: "note")
            return
        }
        // Rolling-window rate limit, per project. Tripping it pauses this
        // project's room rather than dropping one message: a chain that is
        // running away does not get better by having a hole punched in it.
        let cutoff = Date().addingTimeInterval(-Room.relayWindow)
        var times = (relayTimes[project] ?? []).filter { $0 >= cutoff }
        if times.count + targets.count > Room.maxRelaysPerWindow {
            relayTimes[project] = times
            mutate(project) {
                $0.paused = true
                $0.pauseReason = "\(Room.maxRelaysPerWindow) relays in \(Int(Room.relayWindow / 60)) minutes"
            }
            note("Relay paused in \(projectName(project)): \(Room.maxRelaysPerWindow) automatic "
                 + "hand-offs in \(Int(Room.relayWindow / 60)) minutes. \(name(lane))'s ping to "
                 + "\(targets.map { "@" + $0 }.joined(separator: ", ")) was not sent. Resume in the "
                 + "room header when you have read what happened.", project: project, kind: "error")
            save(); push()
            return
        }
        for t in targets {
            times.append(Date())
            relayTimes[project] = times
            // `record: false` — the agent's own turn is already in the
            // transcript above; a relay is a delivery of it, not a second thing
            // said. The row it produced carries the ping in its own text.
            deliver(to: t, project: project, from: lane, text: text, hop: hop + 1, record: false)
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
        let hit = inflight.first { $0.id == requestId }
        inflight.removeAll { $0.id == requestId }
        // A failure whose request we no longer hold has no project to be
        // reported into. Dropping it is right: the alternative is picking a
        // project at random and telling Chancellor a lie about which room lost
        // a message.
        guard let hit else { return }
        note("Not delivered to @\(hit.target) — \(code): \(message). The turn above is in this "
             + "transcript but never reached the gateway. Send it again once the connection "
             + "is back.", project: hit.project, kind: "error")
    }

    // MARK: - the life of a clone
    //
    // A clone is a real gateway session. It comes into being when it is launched
    // — either by Chancellor, or by the first turn delivered to it — and it ends
    // one of two ways, BOTH OF WHICH ARE HIS DECISION AND NEITHER OF WHICH IS
    // AUTOMATIC:
    //
    //   * IDLE. The task is done; keep the clone. Its run is stopped, its
    //     session and its transcript stay, its tab stays, and its memory is the
    //     agent's own and was never in here anyway. A later ping wakes it.
    //   * KILL. The task is done; the clone is not wanted. Its run is stopped,
    //     its gateway session is deleted, and its tab goes.
    //
    // Nothing here decides between them and nothing here times out into one.
    // Bridge does not garbage-collect a clone he has not spoken about.
    //
    // WHO OWNS THE RECORD. `projects` is a MIRROR of Prefs, and the page is the
    // only writer of that document. So these methods update the mirror, act on
    // the gateway, and `push()` the result; live.js `reconcileClones` sees the
    // new clone set and saves it back through the ordinary `prefs` message. The
    // alternative — writing prefs.json from here — races the page, which sends
    // the WHOLE document on every save and would silently undo it.

    /// Bring a clone into being, or wake a parked one. Returns true if anything
    /// changed. Refuses an agent that is not in the project's access list: this
    /// is the same boundary `deliver` enforces, checked here too because a
    /// launch is the thing that creates the session.
    @discardableResult
    func launchIfNeeded(_ agentId: String, project: String) -> Bool {
        guard agentId != "main" else { return false }              // its clone is the room
        guard let pi = projects.firstIndex(where: { $0.id == project }) else { return false }
        guard projects[pi].access.contains(agentId) else { return false }
        if let ci = projects[pi].clones.firstIndex(where: { $0.id == agentId }) {
            guard projects[pi].clones[ci].state != Prefs.Clone.active else { return false }
            projects[pi].clones[ci].state = Prefs.Clone.active
        } else {
            projects[pi].clones.append(Prefs.Clone(id: agentId, state: Prefs.Clone.active))
            Gateway.shared.subscribeRoom(keys)
        }
        push()
        return true
    }

    /// Launch by hand, from the picker. Says so in the room, because a new clone
    /// in a project is a thing that happened and the transcript is where the
    /// project's history is kept.
    func launch(_ agentId: String, project: String) {
        guard agentId != "main", self.project(project) != nil else { return }
        guard access(of: project).contains(agentId) else {
            note("@\(agentId) has not been given access to \(projectName(project)), so it was not "
                 + "launched.", project: project, kind: "error")
            return
        }
        guard !isLaunched(agentId, project: project) else {
            launchIfNeeded(agentId, project: project)              // wake it if it was parked
            return
        }
        launchIfNeeded(agentId, project: project)
        note("Launched @\(agentId) in \(projectName(project)). It is a clone of \(name(agentId)) "
             + "scoped to this project: its own session, sharing this project's room and this "
             + "agent's memory.", project: project, kind: "note")
    }

    /// Park a clone: stop what it is doing, keep everything it is.
    func setIdle(_ agentId: String, project: String) {
        guard agentId != "main" else { return }                    // the room is not parkable
        guard let pi = projects.firstIndex(where: { $0.id == project }),
              let ci = projects[pi].clones.firstIndex(where: { $0.id == agentId }) else { return }
        guard projects[pi].clones[ci].state != Prefs.Clone.idle else { return }
        projects[pi].clones[ci].state = Prefs.Clone.idle
        // Stop the run. Parking a clone that is mid-turn and letting the turn
        // finish anyway would make "idle" a label rather than a state.
        Gateway.shared.abortRun(sessionKey: Room.key(agentId, project: project),
                                requestId: "room-idle-\(newId())")
        note("@\(agentId) is idle in \(projectName(project)). Its session and its memory are kept; "
             + "ping it and it picks the work back up.", project: project, kind: "note")
        push()
    }

    /// End a clone: stop it, delete its gateway session, drop its tab.
    ///
    /// The agent's SOUL.md and MEMORY.md are untouched. They belong to the agent
    /// and are shared by its clones everywhere else; deleting them because one
    /// project is finished with it would erase what it learned in all the
    /// others.
    func kill(_ agentId: String, project: String) {
        guard agentId != "main" else { return }                    // that is removing the project
        guard let pi = projects.firstIndex(where: { $0.id == project }),
              projects[pi].clones.contains(where: { $0.id == agentId }) else { return }
        projects[pi].clones.removeAll { $0.id == agentId }
        let key = Room.key(agentId, project: project)
        // The high-water mark goes with it. If he ever launches this agent here
        // again, the gateway hands back a fresh session under the same key, and a
        // stale mark would make the room ignore its first turns.
        mutate(project) { $0.seen.removeValue(forKey: key)
                          $0.since.removeValue(forKey: key)
                          $0.hop.removeValue(forKey: key) }
        Gateway.shared.abortRun(sessionKey: key, requestId: "room-kill-\(newId())")
        Gateway.shared.deleteSession(sessionKey: key, requestId: "room-kill-\(newId())")
        note("Killed @\(agentId) in \(projectName(project)): its session here is deleted and its "
             + "tab is gone. \(name(agentId))'s own memory is untouched — it is shared with every "
             + "other project this agent works in.", project: project, kind: "note")
        save(); push()
    }

    // MARK: - controls

    func setPaused(_ p: Bool, project: String) {
        mutate(project) {
            $0.paused = p
            $0.pauseReason = p ? "paused by hand" : ""
        }
        if !p { relayTimes[project] = [] }
        note(p ? "Relay paused. Your own messages still send; agent-to-agent hand-offs do not."
               : "Relay resumed.", project: project, kind: "note")
    }

    /// Replace the whole store. Exists for the smoke test, which exercises the
    /// first-sight seeding against the REAL store and must put Chancellor's
    /// actual rooms back exactly as it found them — the same discipline the
    /// prefs round-trip check already follows.
    func restore(_ s: Store) { store = s; save(); push() }

    func clear(project: String) {
        // The high-water marks are KEPT. Clearing the room empties what is on
        // screen; it must not make Bridge re-read every session's history back
        // in as new, which is what dropping `seen` would do.
        mutate(project) { $0.messages = [] }
        save(); push()
    }

    func note(_ text: String, project: String, kind: String) {
        append(Msg(id: newId(), at: Date().timeIntervalSince1970 * 1000,
                   from: "bridge", to: [], text: text, kind: kind, hop: 0), project: project)
        save(); push()
    }

    private func append(_ m: Msg, project: String) {
        mutate(project) {
            $0.messages.append(m)
            if $0.messages.count > Room.maxMessages {
                $0.messages.removeFirst($0.messages.count - Room.maxMessages)
            }
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

    /// Register an in-flight send without going near the socket.
    ///
    /// `sendFailed` reports into the project the send was addressed to, which it
    /// learns from `inflight` — so a failure for a request nobody is holding is
    /// correctly dropped rather than blamed on an arbitrary room. That makes the
    /// failure path untestable without either a live gateway or this seam, and a
    /// seam is the smaller cost. Same idiom, and the same reason, as
    /// `Prefs.directoryOverride`.
    func debugTrackInflight(requestId: String, project: String, target: String) {
        inflight.append((id: requestId, project: project, target: target))
    }

    private func newId() -> String {
        seq += 1
        return "\(Int(Date().timeIntervalSince1970))-\(seq)-\(Room.idNonce)"
    }

    // MARK: - the page

    /// One payload carrying every project's room, because the page keeps them
    /// all and switches between them without a round trip: clicking from one
    /// project's `main` tab to another's must not wait on the socket.
    func push() {
        var rooms: [String: Any] = [:]
        for p in projects {
            let d = doc(p.id)
            let live = (relayTimes[p.id] ?? []).filter { $0 > Date().addingTimeInterval(-Room.relayWindow) }
            rooms[p.id] = [
                "messages": d.messages.map { [
                    "id": $0.id, "at": $0.at, "from": $0.from,
                    "to": $0.to, "text": $0.text, "kind": $0.kind, "hop": $0.hop,
                ] },
                "paused": d.paused,
                "pauseReason": d.pauseReason,
                "relaysInWindow": live.count,
                // The tabs, in tab order: main first, then the launched clones.
                "agents": tabs(of: p.id).map {
                    ["id": $0, "name": name($0), "key": Room.key($0, project: p.id),
                     "state": cloneState($0, project: p.id) ?? Prefs.Clone.active]
                },
                // Who is allowed in, and who is actually here. live.js mirrors
                // `clones` straight back into prefs — see `reconcileClones` — so
                // a clone launched by a relayed ping is persisted without this
                // file writing the document the page owns.
                "access": p.access,
                "clones": p.clones.map { ["id": $0.id, "state": $0.state] },
            ]
        }
        ActiveWebView.shared.emit([
            "type": "room",
            "rooms": rooms,
            "maxHops": Room.maxHops,
            "relayWindowMin": Int(Room.relayWindow / 60),
            "maxRelays": Room.maxRelaysPerWindow,
            "sharedMemory": Room.sharedMemoryPath,
            "memoryRoot": Room.memoryRoot,
        ])
    }

    // MARK: - store
    //
    // Its own document, not a field in prefs.json: the rooms grow on every turn
    // and prefs is written on every project change. One file that is both would
    // rewrite hundreds of messages to record a rename, and lose every room to a
    // malformed prefs payload. Same atomic-write rule as Prefs.

    static var url: URL { Prefs.directory.appendingPathComponent("room.json") }

    /// v1's `room.json` is ONE document with `messages` at the top level and no
    /// `rooms` key. There is no honest way to split it across projects — the
    /// keys it recorded (`agent:x:bridge`) do not name one — so it is dropped
    /// rather than guessed at, and the drop is logged. The alternative is
    /// attributing a conversation to a project it was not had in.
    private static func load() -> Store {
        guard let data = try? Data(contentsOf: url) else { return Store() }
        if let s = try? JSONDecoder().decode(Store.self, from: data), s.rooms.isEmpty == false {
            return s
        }
        if let s = try? JSONDecoder().decode(Store.self, from: data), s.version >= Room.storeVersion {
            return s
        }
        if let legacy = try? JSONDecoder().decode(Doc.self, from: data), !legacy.messages.isEmpty {
            NSLog("bridge: dropped a v1 room.json with \(legacy.messages.count) messages — "
                  + "a single global room does not map onto per-project rooms")
        }
        return Store()
    }

    func save() {
        guard !readOnlyProbe else { return }
        var scratch: URL?
        do {
            try FileManager.default.createDirectory(at: Prefs.directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(store)
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
