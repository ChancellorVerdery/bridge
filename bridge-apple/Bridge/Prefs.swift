import Foundation

// Bridge's own preferences: projects, per-project agent rosters, tool tabs, the
// ssh host, and which inbox entries have been read.
//
// WHY A FILE AND NOT UserDefaults
//
// Phase A had nothing to persist, so this is a new decision and worth stating.
// The store is a single JSON document at
//
//     ~/Library/Application Support/Bridge/prefs.json
//
// rather than UserDefaults, for three reasons:
//
//   * The shape is nested — projects hold rosters, tool tabs hold rosters — and
//     UserDefaults is a flat plist keyed by string. Encoding a tree into it
//     means either one blob-under-a-key (in which case UserDefaults is only a
//     worse file) or a key-per-leaf naming scheme that has to be kept in sync
//     by hand.
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

struct Prefs: Codable, Equatable {
    var version: Int = 1
    var sshHost: String = Prefs.defaultSSHHost
    /// Projects the user made in Bridge. Gateway session groups arrive
    /// separately over the wire and are merged in the view layer, not here —
    /// this file holds only what the user chose locally.
    var projects: [Project] = []
    /// Tool tabs (the TOOLS sidebar section). Education ships as the first one.
    var toolTabs: [Project] = Prefs.defaultToolTabs
    /// Inbox entries the user has opened, by task id. Read state is Bridge's
    /// own: the gateway has no notion of "Chancellor has looked at this".
    var inboxRead: [String] = []

    static let defaultSSHHost = "atlas"

    /// Education is a real tool tab with a real roster and no contents. The
    /// brief is explicit that nothing inside it gets built in Phase B, and an
    /// empty pane that says nothing reads as broken three days later — so the
    /// note is part of the data, not a placeholder string in the view.
    static let defaultToolTabs: [Project] = [
        Project(id: "tool-education", name: "Education",
                roster: ["coursework", "main", "frontend-design"],
                note: "Coursework, main and a design lane, grouped for study work. "
                    + "Nothing inside Education is built yet: no chat surface, no maths "
                    + "rendering, no practice problems. The three tabs below are real "
                    + "agents and open their real sessions."),
    ]

    struct Project: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// Agent ids chosen for this project's top tabs. Empty means "show every
        /// session that carries this group", which is Phase A's behaviour.
        var roster: [String] = []
        /// What an empty tool tab would hold, written by whoever created it.
        var note: String = ""
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

    static var current: Prefs {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) }
            ?? Prefs()
        cache = loaded
        return loaded
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
    @discardableResult
    static func save(_ p: Prefs) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var scratch: URL?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(p)
            let tmp = directory.appendingPathComponent("prefs.json.tmp-\(UUID().uuidString.prefix(8))")
            scratch = tmp
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            cache = p
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
