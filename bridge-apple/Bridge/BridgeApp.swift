import SwiftUI
import AppKit

// Bridge as a native shell: one SwiftUI window, a WKWebView over the app's own
// loopback origin, and a native WebSocket to the OpenClaw Gateway.
//
// The split is the point. Swift owns the socket and the token; the web layer
// owns the pixels and never learns either. See Gateway.swift and PROTOCOL.md.

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var shell = Shell()

    var body: some Scene {
        WindowGroup {
            Group {
                if let origin = shell.origin {
                    BridgeWebView(origin: origin)
                } else {
                    Text("Bridge could not start its local server — see Console.app for the reason.")
                        .padding()
                }
            }
            .background(Color(red: 0x09 / 255, green: 0x0B / 255, blue: 0x11 / 255))
            .frame(minWidth: 960, minHeight: 640)
            .sheet(isPresented: $shell.showSettings) { SettingsSheet(shell: shell) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            TextEditingCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { shell.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Zoom In") { ActiveWebView.shared.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { ActiveWebView.shared.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { ActiveWebView.shared.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Reconnect") { Gateway.shared.reconnectNow() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // In --smoke and --shot the SwiftUI WindowGroup's window is never shown (or
    // is closed immediately), and "quit after the last window closes" then tears
    // the process down mid-check — which looked exactly like a silent crash:
    // exit 0, no output, no file written.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        let args = CommandLine.arguments
        return !(args.contains("--smoke") || args.contains("--shot")
                 || args.contains("--room-probe"))
    }
    func applicationWillTerminate(_ n: Notification) {
        Gateway.shared.stop()
        Tunnel.shared.stop()
    }
}

@MainActor
final class Shell: ObservableObject {
    @Published var origin: URL?
    @Published var showSettings = false
    @Published var status: String = "starting"

    init() {
        let args = CommandLine.arguments

        // `Bridge --set-token` reads the token from stdin and writes it to the
        // Keychain as the app itself, so later reads never raise a keychain
        // prompt. It is also the only way to install the token without it ever
        // appearing in a shell history, an argv, or a log:
        //
        //   ssh atlas 'jq -r .gateway.auth.token ~/.openclaw/openclaw.json' \
        //     | Bridge.app/Contents/MacOS/Bridge --set-token
        if args.contains("--set-token") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { print("no token on stdin"); exit(2) }
            Keychain.token = token
            print(Keychain.token == token ? "token stored in the keychain" : "keychain write failed")
            exit(Keychain.token == token ? 0 : 1)
        }

        let smoke = args.contains("--smoke")
        let shotIndex = args.firstIndex(of: "--shot")
        if smoke { NSApplication.shared.setActivationPolicy(.prohibited) }
        // --shot needs a window that actually composites, so .accessory rather
        // than .prohibited: a WKWebView with no window on screen snapshots blank.
        if shotIndex != nil { NSApplication.shared.setActivationPolicy(.accessory) }

        do {
            try LocalServer.shared.start()
            origin = LocalServer.shared.origin
        } catch {
            NSLog("bridge: local server failed to start: \(error)")
        }

        // The one wire between the two halves, outbound.
        Gateway.shared.onEmit = { msg in
            ActiveWebView.shared.emit(msg)
            if let c = msg["connection"] as? String { self.status = c }
        }

        // …and inbound. Five message kinds, none of which carries or returns a
        // secret — see the note at the top of WebView.swift.
        BridgeWebView.Coordinator.onMessage = { [weak self] body in
            MainActor.assumeIsolated { self?.handle(body) }
        }

        if smoke {
            guard let origin else { print("FAIL local server did not start"); exit(1) }
            Task { await Smoke.run(origin: origin) }
            return
        }
        if let i = shotIndex {
            guard let origin else { print("FAIL local server did not start"); exit(1) }
            let path = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "bridge.png"
            Task { await Smoke.shot(origin: origin, path: path) }
            return
        }

        // `--room-probe` measures the one thing no unit test on this machine can
        // reach: whether a RECONNECT re-subscribes the room's per-agent sessions.
        //
        // The room only sees an agent's reply because Gateway subscribes and
        // backfills `agent:<id>:bridge`. Those subscriptions do not survive a
        // reconnect (PROTOCOL.md §4, §6), and `subscribeRoom`'s dedup set is
        // process-lifetime, so the question "does the room still work after the
        // socket drops?" has an answer that is invisible from inside the app and
        // catastrophic when it is no: no error, no log, the room simply stops
        // taking in replies. This connects, counts, forces a reconnect, and
        // counts again.
        if args.contains("--room-probe") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            // The real app is open on his desk against the same room.json and
            // the same gateway. This process must not take a turn in, relay one,
            // or write the store — it is here to count subscriptions.
            Room.shared.readOnlyProbe = true
            Gateway.shared.start()
            Task { @MainActor in
                // Phase 1 — a first connection. However many lanes the gateway
                // has, this is how many room sessions a working room subscribes.
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                let base = Gateway.shared.roomSubscribesIssued
                print("room-probe: first connect            roomSubscribes=\(base)")

                // Phase 2 — reconnect with the connection-scoped caches left
                // standing, which is exactly what the code did before this pass.
                // Expected: ZERO. That is the bug, reproduced live rather than
                // argued from a reading of the source.
                Gateway.debugSkipCacheReset = true
                Gateway.shared.reconnectNow()
                try? await Task.sleep(nanoseconds: 22_000_000_000)
                let stale = Gateway.shared.roomSubscribesIssued - base
                print("room-probe: reconnect, caches kept   roomSubscribes=\(stale)   (pre-fix behaviour)")

                // Phase 3 — the same reconnect with the caches dropped.
                Gateway.debugSkipCacheReset = false
                Gateway.shared.reconnectNow()
                try? await Task.sleep(nanoseconds: 22_000_000_000)
                let fixed = Gateway.shared.roomSubscribesIssued - base - stale
                print("room-probe: reconnect, caches reset  roomSubscribes=\(fixed)   (fixed)")

                let ok = base > 0 && stale == 0 && fixed == base
                print(ok
                      ? "room-probe: PASS — the defect reproduces (0/\(base)) and the fix restores it (\(fixed)/\(base))"
                      : "room-probe: FAIL — base=\(base) stale=\(stale) fixed=\(fixed)")
                exit(ok ? 0 : 1)
            }
            return
        }

        // MIGRATE ONCE, AT LAUNCH, RATHER THAN LEAVING IT IMPLICIT.
        //
        // `Prefs.current` sanitises on read, so the app is correct either way —
        // v1's tool tabs are gone, `g-` project ids are renamed, and a leaked
        // screenshot fixture like `p-shotempty` is dropped. But until something
        // saves, the FILE still says otherwise, and "the sidebar and prefs.json
        // disagree" is the kind of state that costs an hour to diagnose later.
        // Writing it here makes the upgrade a fact on disk at first launch.
        if Prefs.needsMigration {
            let migrated = Prefs.current
            NSLog("bridge: migrating prefs to v\(Prefs.currentVersion) — "
                  + "projects=\(migrated.projects.map { $0.id }.joined(separator: ","))")
            _ = Prefs.save(migrated)
        }
        Room.shared.setProjects(Prefs.current.projects)

        if Keychain.token == nil { showSettings = true }
        // The running app can photograph itself on SIGUSR1. `screencapture -l`
        // needs a Screen Recording grant this machine has not given, and a
        // WKWebView snapshotting its own contents needs none — see Smoke.liveShot.
        Smoke.installLiveShotHandler()
        Gateway.shared.start()
    }

    /// The page asked for something. Everything here is either a preference
    /// write, a gateway write, or "open the native sheet".
    func handle(_ body: [String: Any]) {
        switch body["t"] as? String {
        case "ready":
            // The page has just booted and has no state. Hand it the stored
            // preferences before anything else, so the first paint draws the
            // user's own projects and rosters rather than defaults that then
            // flicker away — and so a project made last week is simply there.
            pushPrefs()
            // The Study tool's data lives in Bridge's own file store, not the
            // ephemeral WebView — hand it over on boot so its courses survive a
            // relaunch the same way projects do.
            pushStudyStore()
            // …and the room, which is persisted the same way and for the same
            // reason: the main chat is a thread, not a session log, and it has
            // to be there when the window opens rather than after the gateway
            // answers.
            Room.shared.push()

        case "prefs":
            // The page sends the WHOLE document. Partial merges across a bridge
            // are how two halves end up disagreeing about what was saved.
            guard let obj = body["prefs"] as? [String: Any], let p = Prefs.from(obj) else {
                NSLog("bridge: rejected a malformed prefs document"); return
            }
            let before = Prefs.current
            guard Prefs.save(p) else {
                // The save did not happen and `Prefs.current` is still the old
                // document, so the page is now the only thing holding the new
                // one. Hand it the truth back rather than leaving the screen
                // showing a roster that no longer exists anywhere else.
                pushPrefs()
                return
            }
            // A changed ssh host only takes effect on a new forward, and saying
            // so is better than a setting that silently does nothing until the
            // next launch.
            if p.sshHost != before.sshHost { Gateway.shared.reconnectNow() }

            // THE PROJECT LIST CHANGED, SO THE SET OF CLONES CHANGED.
            //
            // `Prefs.current` is the SANITISED document — not `p` — which is the
            // point: whatever the page sent, Room is told what was actually
            // stored. A new project's clones get subscribed here rather than at
            // the next reconnect, so its `main` tab is live immediately; a
            // removed project's room is dropped inside `setProjects`.
            let after = Prefs.current
            if after.projects != before.projects {
                Room.shared.setProjects(after.projects)
                Gateway.shared.subscribeRoom(Room.shared.keys)
                // The page's copy of the document is now stale in exactly the
                // case that matters: it asked for something `sanitized` refused.
                // Hand back what was really written.
                if after.projects != p.projects { pushPrefs() }
            }

        case "send":
            guard let key = body["sessionKey"] as? String, let text = body["text"] as? String else { return }
            Gateway.shared.sendMessage(sessionKey: key, text: text,
                                       queueMode: body["queueMode"] as? String ?? "",
                                       requestId: body["requestId"] as? String ?? "")

        case "abort":
            guard let key = body["sessionKey"] as? String else { return }
            Gateway.shared.abortRun(sessionKey: key, requestId: body["requestId"] as? String ?? "")

        // ── PHASE C ──────────────────────────────────────────────────────
        //
        // The room. The page never addresses a gateway session directly for
        // these: it says "send this, pinging that", and Room decides which
        // session key that means, whether the standing preamble is due, and what
        // goes into the shared transcript. Routing lives in one place.

        // Every one of these now carries a PROJECT, because a room belongs to a
        // project. A message with no project is dropped rather than routed to a
        // default: guessing which room Chancellor meant is how a message ends up
        // in the wrong project's transcript, which is the one thing isolation is
        // supposed to make impossible.

        case "room.send":
            guard let text = body["text"] as? String,
                  let project = body["project"] as? String, !project.isEmpty else { return }
            let ping = body["ping"] as? String
            Room.shared.fromChancellor(text: text, ping: (ping?.isEmpty ?? true) ? nil : ping,
                                       project: project)

        // THE LIFE OF A CLONE. Launch, park, kill — each of them Chancellor's
        // decision, each arriving from a click and from nothing else. Room does
        // the gateway half and pushes the new clone set back; the page mirrors
        // it into the preference document it owns.
        case "clone":
            guard let project = body["project"] as? String, !project.isEmpty,
                  let agent = body["agent"] as? String, !agent.isEmpty else { return }
            switch body["op"] as? String {
            case "launch": Room.shared.launch(agent, project: project)
            case "idle":   Room.shared.setIdle(agent, project: project)
            case "kill":   Room.shared.kill(agent, project: project)
            default:       NSLog("bridge: unknown clone op")
            }

        case "room.pause":
            guard let project = body["project"] as? String, !project.isEmpty else { return }
            Room.shared.setPaused(body["paused"] as? Bool ?? true, project: project)

        case "room.clear":
            guard let project = body["project"] as? String, !project.isEmpty else { return }
            Room.shared.clear(project: project)

        case "question.resolve":
            // The answers map is keyed by the INNER questionId, not the record
            // id. The page sends both because it read both off the record.
            guard let id = body["id"] as? String,
                  let qid = body["questionId"] as? String,
                  let value = body["value"] as? String else { return }
            Gateway.shared.resolveQuestion(id: id, answers: [qid: [value]],
                                           requestId: body["requestId"] as? String ?? "")

        case "voice":
            // Hold-to-talk. The page sends two strings and receives text back;
            // the microphone, the audio and the model all stay on this side.
            let rid = body["requestId"] as? String ?? ""
            switch body["phase"] as? String {
            case "start": Voice.shared.start(requestId: rid)
            case "stop": Voice.shared.stop(requestId: rid)
            default: Voice.shared.cancel()
            }

        case "settings":
            // Token entry is native. The page can ask for the sheet; it cannot
            // supply, read, or receive the token itself.
            showSettings = true

        case "reconnect":
            Gateway.shared.reconnectNow()

        case "studyStore":
            // The Study tool sends its WHOLE store as a JSON string on every
            // change. It is local only — never forwarded to the gateway — so a
            // question bank and its chat stay on this Mac.
            guard let data = body["data"] as? String else { return }
            StudyStore.save(data)

        default:
            break
        }
    }

    func pushStudyStore() {
        ActiveWebView.shared.emit(["type": "studyStore", "data": StudyStore.load()])
    }

    func pushPrefs() {
        ActiveWebView.shared.emit([
            "type": "prefs",
            "prefs": Prefs.asDictionary(Prefs.current),
            "path": Prefs.url.path,
            "tokenPresent": Keychain.token != nil,
            // Which transcription route the composer will actually take. Stated
            // rather than discovered: "local" and "gateway" send the audio to
            // different machines and the difference is the user's business.
            "voice": Voice.describe(),
        ])
    }
}

// Token entry, and only token entry.
//
// Phase B's Settings is a real page inside the web layer — scopes, ssh host, API
// keys — because that is where it belongs and where it can be styled in Atlas.
// This sheet stays, and stays native, for the one field that must never exist as
// a JavaScript string: SecureField writes straight to the Keychain, in-process,
// and nothing hands the value back out. The web page's "Enter gateway token…"
// button opens this.
struct SettingsSheet: View {
    @ObservedObject var shell: Shell
    @State private var token: String = ""
    @State private var note: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gateway token").font(.headline)
            Text("`gateway.auth.token` from ~/.openclaw/openclaw.json on the gateway host. "
                 + "It is stored in the macOS Keychain and is never written to disk, logged, "
                 + "or made visible to the web view.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("paste the token", text: $token)
                .textFieldStyle(.roundedBorder).frame(width: 460)
            if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                Button("Save and connect") {
                    Keychain.token = token
                    token = ""
                    note = Keychain.token == nil ? "keychain write failed" : "saved — reconnecting"
                    Gateway.shared.reconnectNow()
                    shell.pushPrefs()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 520)
        .onAppear { note = Keychain.token == nil ? "" : "A token is already stored. Saving replaces it." }
    }

    private var statusLine: String {
        "connection: " + shell.status
    }
}
