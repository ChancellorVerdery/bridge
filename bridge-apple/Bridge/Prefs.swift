import Foundation

// Bridge's own preferences: the projects, their agent rosters, the ssh host, and
// which inbox entries have been read.
//
// WHY A FILE AND NOT UserDefaults
//
// The store is a single JSON document at
//
//     ~/Library/Application Support/Bridge/prefs.json
//
// rather than UserDefaults, for three reasons:
//
//   * The shape is nested — projects hold rosters — and UserDefaults is a flat
//     plist keyed by string. Encoding a tree into it means either one
//     blob-under-a-key (in which case UserDefaults is only a worse file) or a
//     key-per-leaf naming scheme that has to be kept in sync by hand.
//   * It is inspectable. `cat prefs.json` is a debugging step; `defaults read`
//     against an unsandboxed app that has also been run from a build directory
//     is a guessing game about which domain won.
//   * It is portable. The file can be copied to another Mac, diffed, or deleted
//     to reset, without touching cfprefsd's cache — which is a real hazard: a
//     write can sit in that daemon and lose a race with a process that exits.
//
// UserDefaults keeps exactly one thing, the WKWebView page zoom, because that
// was already there and is genuinely a single scalar.
//
// Writes are atomic (write to a sibling temp file, then rename) so a crash
// mid-save leaves the previous document intact rather than a half-written one.
// The page is the only writer, and it sends the whole document each time.
//
// ─────────────────────────────────────────────────────────────────────────────
// VERSION 3 — ACCESS IS CHANCELLOR'S, AND A CLONE HAS A LIFE
//
// v1 had three kinds of sidebar entry (gateway groups, local projects, tool
// tabs) and a project was a filter over sessions that already existed. v2 made
// the project the unit of isolation but assumed a project holds a clone of
// EVERY agent — it back-filled every project to the full gateway list and
// deleted the control that would have let anyone say otherwise.
//
// That assumption was wrong, and Chancellor's own document is the evidence: his
// Bridge project rostered seven of nine agents and his Atlas project rostered
// one. v2 would have overwritten both with nine.
//
// v3 therefore splits what v2 had conflated into a single `roster` list:
//
//   * `access` — WHICH AGENTS CHANCELLOR HAS ALLOWED INTO THIS PROJECT. His
//     choice, made in the picker, and the boundary `Room.deliver` enforces. An
//     agent outside it is unreachable from inside this project.
//   * `clones` — WHICH OF THOSE HAVE ACTUALLY BEEN LAUNCHED HERE, and for each,
//     whether it is working or parked. A clone is a real gateway session
//     (`Room.key`); launching one is what brings it into being, and after a task
//     Chancellor either kills it (session deleted, tab gone) or leaves it IDLE
//     (session and memory kept, doing nothing). Both are his call, so both are
//     stored here rather than inferred.
//
// `main` is in every project's access list and is never in `clones`: a
// project's main clone IS its room, it is created with the project, and it is
// removed only by removing the project.
//
// Everything else v2 established still holds: `projects` is the ONLY source of
// projects, nothing on the wire creates one, and `toolTabs` and `Project.note`
// are gone.
// ─────────────────────────────────────────────────────────────────────────────

struct Prefs: Codable, Equatable {
    var version: Int = Prefs.currentVersion
    var sshHost: String = Prefs.defaultSSHHost
    /// The projects Chancellor made. The unit of isolation, and the only thing
    /// the sidebar's PROJECTS section is built from.
    var projects: [Project] = []
    /// Custom tools Chancellor builds — see `Tool`. A separate list from
    /// `projects` because a tool is not a project: one agent and one page, not
    /// a multi-agent room.
    var tools: [Tool] = []
    /// Inbox entries the user has opened, by task id. Read state is Bridge's
    /// own: the gateway has no notion of "Chancellor has looked at this".
    var inboxRead: [String] = []

    static let currentVersion = 3
    static let defaultSSHHost = "atlas"

    /// One launched clone: an agent that has been brought into a project as its
    /// own gateway session.
    ///
    /// `state` is deliberately a stored fact rather than something derived from
    /// whether the session happens to be running right now. "Idle" is a decision
    /// Chancellor made about a clone he wants to keep — it has to survive a
    /// relaunch, and it has to be distinguishable from "busy at this instant",
    /// which the gateway already reports and which nobody needs persisted.
    struct Clone: Codable, Equatable {
        /// Working, or ready to. A relayed ping goes through.
        static let active = "active"
        /// Parked by hand: session and memory kept, nothing running. A ping
        /// delivered here wakes it back to `active`.
        static let idle = "idle"

        var id: String
        var state: String = Clone.active

        init(id: String, state: String = Clone.active) {
            self.id = id
            self.state = state
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            state = (try? c.decode(String.self, forKey: .state)) ?? Clone.active
        }
    }

    struct Project: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// THE AGENTS CHANCELLOR HAS GIVEN ACCESS TO THIS PROJECT. Not the tabs:
        /// an agent with access that has never been launched has no session and
        /// no tab. This is the reach boundary — `Room.deliver` refuses anything
        /// outside it.
        var access: [String] = []
        /// The clones actually launched here, in tab order. Never contains
        /// `main`, whose clone is the room itself.
        var clones: [Clone] = []

        init(id: String, name: String, access: [String] = [], clones: [Clone] = []) {
            self.id = id
            self.name = name
            self.access = access
            self.clones = clones
        }

        /// Explicit, because v1 and v2 documents carry keys this shape no longer
        /// has (`note`, `roster`) and synthesised Codable does not fall back to
        /// property defaults for a key that is simply absent.
        ///
        /// `roster` is the v1/v2 spelling of `access` and is read as such. That
        /// is the whole migration for existing documents, and it is the right
        /// one: what he had rostered is exactly what he had allowed in. It is
        /// NOT read as a clone set — v2 never recorded whether an agent had been
        /// launched, and inventing a live clone for every rostered agent is the
        /// assumption this version exists to undo.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decode(String.self, forKey: .name)) ?? id
            access = (try? c.decode([String].self, forKey: .access))
                ?? (try? c.decode([String].self, forKey: .roster))
                ?? []
            clones = (try? c.decode([Clone].self, forKey: .clones)) ?? []
        }

        /// `roster` is decode-only: it is read from old documents and never
        /// written back, so an upgraded file stops carrying it.
        enum CodingKeys: String, CodingKey {
            case id, name, access, clones, roster
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(access, forKey: .access)
            try c.encode(clones, forKey: .clones)
        }

        /// The state of one launched clone, or nil when that agent is not
        /// launched here.
        func cloneState(_ agentId: String) -> String? {
            clones.first { $0.id == agentId }?.state
        }
    }

    /// A custom tool Chancellor builds: a study helper, a prelab writer. NOT a
    /// project — a tool is one agent and one page, not a multi-agent room. For
    /// now it is a name and an id that opens a blank page; the single backing
    /// agent comes later. Synthesised Codable is enough — unlike Project it
    /// carries no legacy keys to migrate.
    struct Tool: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        // What the tool's page IS. "study" = the ported study workbench (tutor
        // chat + question bank); "blank" = a named placeholder page, as before.
        // Decoded tolerantly so a tool written before this field existed loads
        // as "blank" instead of throwing and taking the whole tools array with
        // it (the list is decoded as one `try?`).
        var kind: String = "blank"
        enum CodingKeys: String, CodingKey { case id, name, kind }
        init(id: String, name: String, kind: String = "blank") { self.id = id; self.name = name; self.kind = kind }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? "blank"
        }
    }

    /// `toolTabs` is DECODE-ONLY: read from a v1 document so its tabs can become
    /// projects, and never written back, so an upgraded file stops carrying it.
    /// `projects`, `sshHost`, `inboxRead` and `version` are the whole of v3.
    enum CodingKeys: String, CodingKey {
        case version, sshHost, projects, tools, inboxRead, toolTabs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sshHost, forKey: .sshHost)
        try c.encode(projects, forKey: .projects)
        try c.encode(tools, forKey: .tools)
        try c.encode(inboxRead, forKey: .inboxRead)
    }

    init() {}

    /// Explicit for the same reason as `Project`: a v1 document has `toolTabs`
    /// and a v1 `version`, and must decode into a v2 value rather than throwing
    /// and silently resetting Chancellor's projects to nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        sshHost = (try? c.decode(String.self, forKey: .sshHost)) ?? Prefs.defaultSSHHost
        projects = (try? c.decode([Project].self, forKey: .projects)) ?? []
        tools = (try? c.decode([Tool].self, forKey: .tools)) ?? []
        // A v1 TOOL TAB BECOMES A PROJECT rather than being deleted.
        //
        // v2 dropped them, which threw away the one Chancellor had actually
        // built: "Education", holding coursework, main and frontend-design. A
        // tool tab was a name plus a chosen set of agents, and under v3 that is
        // precisely what a project is — so the honest migration is to carry it
        // across, not to decide on his behalf that he is finished with it.
        // Removing it is one click if he is; recreating it is retyping the name
        // and re-picking three agents if v2 had its way.
        //
        // `sanitized` renames the `tool-` id, exactly as it renames v1's `g-`.
        for tab in (try? c.decode([Project].self, forKey: .toolTabs)) ?? [] {
            guard !projects.contains(where: { $0.id == tab.id }) else { continue }
            projects.append(tab)
        }
        inboxRead = (try? c.decode([String].self, forKey: .inboxRead)) ?? []
    }

    // MARK: - what a project may be
    //
    // AGENTS MUST NOT BE ABLE TO CREATE PROJECTS. That is a rule about actors,
    // and the only way to enforce a rule about actors in code is to close every
    // door rather than to write it down. There are three doors and this is the
    // third:
    //
    //   1. live.js `buildCategories` builds the sidebar from `PREFS.projects`
    //      alone. A gateway session group, or a session carrying a `category`,
    //      no longer produces a project. That is the load-bearing one: it is the
    //      only path anything on the wire ever had.
    //   2. live.js gates every mutation of `PREFS.projects` behind a user-intent
    //      token set only by a DOM event handler, so a code path reached from a
    //      gateway message cannot call the mutators at all.
    //   3. Here. Every document that arrives from the page is normalised before
    //      it is written, so a malformed or hand-edited one cannot introduce a
    //      project with an id this app did not mint.

    /// Ids Bridge's own screenshot and test fixtures have leaked into real
    /// preference documents. `p-shotempty` sat in Chancellor's live sidebar for
    /// days; it is purged on load rather than left for someone to notice.
    static let fixtureProjectIDs: Set<String> = ["p-shotempty", "p-shotempty-check"]

    /// A project id is minted by `newProjectID` and looks like `p-<slug>-<n>`.
    /// v1's gateway-adopted ids (`g-bridge`) are migrated to this shape rather
    /// than grandfathered, because `g-` meant "came from a gateway group" and
    /// nothing comes from a gateway group any more.
    static func isValidProjectID(_ id: String) -> Bool {
        guard id.count >= 3, id.hasPrefix("p-") else { return false }
        let body = id.dropFirst(2)
        guard let f = body.first, f.isLowercase || f.isNumber else { return false }
        return body.allSatisfy { $0.isNumber || ($0.isLowercase && $0.isASCII) || $0 == "-" }
    }

    /// A tool id is minted by the page as `t-<slug>` (counting up on collision),
    /// the same shape as a project id but a `t-` prefix, so the two id spaces
    /// never collide.
    static func isValidToolID(_ id: String) -> Bool {
        guard id.count >= 3, id.hasPrefix("t-") else { return false }
        let body = id.dropFirst(2)
        guard let f = body.first, f.isLowercase || f.isNumber else { return false }
        return body.allSatisfy { $0.isNumber || ($0.isLowercase && $0.isASCII) || $0 == "-" }
    }

    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "x" : collapsed
    }

    static func newProjectID(name: String, existing: [String]) -> String {
        let base = "p-" + slug(name)
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// `main` first, then the order given, deduplicated.
    ///
    /// `main` is FORCED IN rather than merely sorted to the front. A project's
    /// room delivers to its own `main` clone, and `deliver` refuses a target
    /// outside the access list — so a project without `main` in it is a project
    /// whose room silently swallows everything Chancellor types. That is not a
    /// state he should be able to reach by unticking a box, and the picker
    /// disables the box for the same reason.
    static func normalisedAccess(_ access: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in access where !id.isEmpty {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        if let i = out.firstIndex(of: "main"), i != 0 {
            out.remove(at: i)
            out.insert("main", at: 0)
        } else if !seen.contains("main") {
            out.insert("main", at: 0)
        }
        return out
    }

    /// The launched clones, constrained to what the access list allows.
    ///
    /// REVOKING ACCESS KILLS THE CLONE. Dropping a clone whose agent is no
    /// longer allowed in is not tidying: leaving it would mean an agent that
    /// Chancellor has just excluded still holds a live session inside the
    /// project and still appears as a tab, which is the access control failing
    /// to control anything.
    ///
    /// `main` is never a clone — its session is the room.
    static func normalisedClones(_ clones: [Clone], access: [String]) -> [Clone] {
        let allowed = Set(access)
        var seen = Set<String>()
        var out: [Clone] = []
        for c in clones where !c.id.isEmpty && c.id != "main" {
            guard allowed.contains(c.id) else { continue }
            guard seen.insert(c.id).inserted else { continue }
            let state = (c.state == Clone.idle) ? Clone.idle : Clone.active
            out.append(Clone(id: c.id, state: state))
        }
        return out
    }

    /// The one gate every write goes through. Drops fixtures, drops ids this app
    /// could not have minted, migrates v1 ids, dedupes, and fixes roster order.
    static func sanitized(_ p: Prefs) -> Prefs {
        var out = p
        out.version = Prefs.currentVersion
        if out.sshHost.trimmingCharacters(in: .whitespaces).isEmpty {
            out.sshHost = Prefs.defaultSSHHost
        }
        var seen = Set<String>()
        var projects: [Project] = []
        for var proj in p.projects {
            // v1 adopted a gateway group as `g-<slug>`. Carry the project, drop
            // the prefix's meaning: rename rather than grandfather.
            if proj.id.hasPrefix("g-") { proj.id = "p-" + proj.id.dropFirst(2) }
            // v1's tool tabs, carried across as projects — see `init(from:)`.
            if proj.id.hasPrefix("tool-") { proj.id = "p-" + proj.id.dropFirst(5) }
            guard !Prefs.fixtureProjectIDs.contains(proj.id) else { continue }
            guard Prefs.isValidProjectID(proj.id) else { continue }
            guard !seen.contains(proj.id) else { continue }
            let name = proj.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            seen.insert(proj.id)
            let access = Prefs.normalisedAccess(proj.access)
            projects.append(Project(id: proj.id, name: name, access: access,
                                    clones: Prefs.normalisedClones(proj.clones, access: access)))
        }
        out.projects = projects
        // Tools go through the same gate: a valid `t-` id, a non-empty name, no
        // duplicates. A tool carries no agents or clones, so there is nothing
        // else here to normalise.
        var toolSeen = Set<String>()
        var tools: [Tool] = []
        for t in p.tools {
            guard Prefs.isValidToolID(t.id), !toolSeen.contains(t.id) else { continue }
            let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            toolSeen.insert(t.id)
            tools.append(Tool(id: t.id, name: name, kind: t.kind == "study" ? "study" : "blank"))
        }
        out.tools = tools
        var readSeen = Set<String>()
        out.inboxRead = p.inboxRead.filter { readSeen.insert($0).inserted }
        return out
    }

    // MARK: - store

    /// Overridden by the smoke test so a save can be pointed at a directory that
    /// cannot be created — the only way to reach the failure path below without
    /// waiting for a real disk to misbehave. Same idiom, and the same reason, as
    /// `LocalServer.rootOverride`. Room's store also hangs off this directory,
    /// so anything that sets it must put it back.
    static var directoryOverride: URL?
    static var directory: URL {
        if let o = directoryOverride { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Bridge", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("prefs.json") }

    private static let lock = NSLock()
    private static var cache: Prefs?

    /// Loading runs the document through `sanitized`, so the v1 → v2 migration
    /// and the fixture purge happen on the first read after an upgrade without
    /// waiting for the user to change something. The migrated document is NOT
    /// written back here: `current` is a getter and a getter that writes to disk
    /// is a getter that can fail. The next real save persists it, and until then
    /// the file on disk is still readable by the version that wrote it.
    static var current: Prefs {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let raw = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) }
            ?? Prefs()
        let loaded = Prefs.sanitized(raw)
        cache = loaded
        return loaded
    }

    /// True when the document on disk is not what this version would write —
    /// a v1 file, or one still carrying a fixture project. BridgeApp uses it to
    /// persist the migration once, at launch, rather than leaving it implicit.
    static var needsMigration: Bool {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Prefs.self, from: data) else { return false }
        return Prefs.sanitized(raw) != raw
    }

    /// Atomic: a crash mid-write leaves the previous document, not a truncated
    /// one. Returns false with the reason logged rather than throwing into the
    /// message handler, which has nowhere to put an error.
    ///
    /// THE CACHE IS SET LAST, ON PURPOSE. It used to be set first, so a save
    /// that threw left every subsequent reader of `Prefs.current` believing a
    /// document that is not on disk — and the one caller, the `prefs` message in
    /// BridgeApp, `return`s on false without telling the page. The user's screen
    /// and Bridge's memory would both show the roster they just built; only the
    /// disk would disagree, and only at the next launch, with nothing anywhere
    /// having said so. `false` now means "nothing changed", in memory as well as
    /// on disk, which is the only reading of it that a caller can act on.
    ///
    /// The temp file is removed if the rename does not happen, so a directory
    /// that is failing to write does not also fill with `prefs.json.tmp-…`.
    ///
    /// EVERY WRITE IS SANITISED. This is door 3 of the "agents cannot create
    /// projects" rule: whatever the page sends, what lands on disk is a document
    /// whose projects all have ids this app mints.
    @discardableResult
    static func save(_ p: Prefs) -> Bool {
        let clean = Prefs.sanitized(p)
        lock.lock(); defer { lock.unlock() }
        var scratch: URL?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(clean)
            let tmp = directory.appendingPathComponent("prefs.json.tmp-\(UUID().uuidString.prefix(8))")
            scratch = tmp
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            cache = clean
            return true
        } catch {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            NSLog("bridge: prefs save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The document as the JSON object the web layer consumes. Kept as one
    /// round-trip through Codable so the two representations cannot drift.
    static func asDictionary(_ p: Prefs) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func from(_ obj: [String: Any]) -> Prefs? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(Prefs.self, from: data)
    }
}
