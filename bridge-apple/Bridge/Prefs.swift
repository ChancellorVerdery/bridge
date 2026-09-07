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
// VERSION 2 — THE PROJECT IS THE UNIT OF ISOLATION
//
// v1 had three kinds of sidebar entry (gateway groups, local projects, tool
// tabs) and a project was a filter over sessions that already existed. v2 has
// one kind. A project OWNS a full set of agent clones: `frontend-design` in
// Bridge and `frontend-design` in CalcNotes are two separate gateway sessions
// under two separate room keys, running at the same time, sharing no state. See
// Room.swift for the key scheme and the memory layout.
//
// What that means for this file:
//
//   * `projects` is the ONLY source of projects. Nothing on the wire creates
//     one any more — see `sanitized` below and live.js `buildCategories`.
//   * `toolTabs` is gone. So is `Project.note`, which only ever described an
//     empty tool tab.
//   * A project's roster is its clone set. The page fills it with every agent
//     the gateway reports, `main` first; this file enforces the shape.
// ─────────────────────────────────────────────────────────────────────────────

struct Prefs: Codable, Equatable {
    var version: Int = Prefs.currentVersion
    var sshHost: String = Prefs.defaultSSHHost
    /// The projects Chancellor made. The unit of isolation, and the only thing
    /// the sidebar's PROJECTS section is built from.
    var projects: [Project] = []
    /// Inbox entries the user has opened, by task id. Read state is Bridge's
    /// own: the gateway has no notion of "Chancellor has looked at this".
    var inboxRead: [String] = []

    static let currentVersion = 2
    static let defaultSSHHost = "atlas"

    struct Project: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// This project's clone set: one agent id per tab, `main` first. Every
        /// entry is a real, separate session — see `Room.key(_:project:)`.
        var roster: [String] = []

        init(id: String, name: String, roster: [String] = []) {
            self.id = id
            self.name = name
            self.roster = roster
        }

        /// Explicit, because v1 documents carry a `note` this shape no longer
        /// has and synthesised Codable does not fall back to property defaults
        /// for a key that is simply absent.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decode(String.self, forKey: .name)) ?? id
            roster = (try? c.decode([String].self, forKey: .roster)) ?? []
        }
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

    /// `main` first, then the order given, deduplicated. Tab order is roster
    /// order and the room tab is not in the roster — `main` here is the agent,
    /// not the room. See Room.swift.
    static func normalisedRoster(_ roster: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in roster where !id.isEmpty {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        if let i = out.firstIndex(of: "main"), i != 0 {
            out.remove(at: i)
            out.insert("main", at: 0)
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
            guard !Prefs.fixtureProjectIDs.contains(proj.id) else { continue }
            guard Prefs.isValidProjectID(proj.id) else { continue }
            guard !seen.contains(proj.id) else { continue }
            let name = proj.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            seen.insert(proj.id)
            projects.append(Project(id: proj.id, name: name,
                                    roster: Prefs.normalisedRoster(proj.roster)))
        }
        out.projects = projects
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
