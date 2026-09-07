import Foundation
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────────
// HOLD SPACE TO TALK.
//
// The composer's dictation path. Hold SPACE, speak, release: the audio is
// recorded natively, transcribed ON THIS MAC, and the text is inserted at the
// caret. Nothing is uploaded anywhere.
//
// THE RULE, LIFTED FROM CLAUDE CODE
//
// Space-hold arms ONLY when the composer is empty. That single condition is what
// makes the feature usable rather than infuriating: without it, the space bar
// stops being the space bar and you cannot type "hello world". The check lives
// in app.js where the composer's value is, and is asserted in the smoke test,
// because it is the one thing about this feature that is easy to get wrong and
// impossible to miss when it is.
//
// WHY THE RECORDING IS NATIVE
//
// A WKWebView could ask for `getUserMedia`, and that was the shorter road. It
// would put a live microphone stream inside the web layer and make the page —
// the one part of this app whose whole security posture is "it holds no
// secrets and reaches nothing" — the thing holding an open mic. Recording here
// keeps the page's inbound surface to two strings: "start" and "stop".
//
// WHY THE TRANSCRIPTION IS LOCAL
//
// `whisper-cli` from Homebrew, against a GGML model in Application Support.
// Dictation is the most sensitive text this app will ever handle — it is
// whatever he says out loud at his desk — and sending it to a hosted API to
// save 400ms is a trade nobody asked for. The gateway host also has a working
// `~/.local/bin/transcribe` (faster-whisper) and that is the FALLBACK, used only
// when the local binary or model is missing. Which one ran is reported to the
// page on every result and printed on screen, so "local" is never assumed.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class Voice {
    static let shared = Voice()
    private init() {}

    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var active: String?           // requestId of the hold in progress
    private var startedAt: Date?

    /// Longest single hold. A key-up that never arrives — the window losing
    /// focus mid-hold is the ordinary way — must not leave a microphone open
    /// forever.
    static let maxSeconds: TimeInterval = 120
    /// Below this a "hold" was a keystroke, not speech. Transcribing 80ms of
    /// room tone produces confident garbage, which is worse than nothing.
    static let minSeconds: TimeInterval = 0.35

    // MARK: - discovery

    /// The whisper binary, if Homebrew has one. `whisper-cli` is the current
    /// name; `whisper-cpp` and `main` are what older bottles installed.
    static var binary: URL? {
        let names = ["whisper-cli", "whisper-cpp", "main"]
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            for n in names {
                let u = URL(fileURLWithPath: d).appendingPathComponent(n)
                if FileManager.default.isExecutableFile(atPath: u.path) { return u }
            }
        }
        return nil
    }

    /// Bigger model first: small.en is materially better on technical words —
    /// agent ids, file paths, "WKWebView" — which is most of what gets dictated
    /// into this box.
    static var model: URL? {
        let dir = Prefs.directory.appendingPathComponent("models", isDirectory: true)
        for n in ["ggml-small.en.bin", "ggml-base.en.bin", "ggml-tiny.en.bin"] {
            let u = dir.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static var localAvailable: Bool { binary != nil && model != nil }

    /// What the Settings page prints, so the transcription route is a stated
    /// fact rather than something you find out by using it.
    static func describe() -> [String: Any] {
        [
            "binary": binary?.path ?? "",
            "model": model?.lastPathComponent ?? "",
            "route": localAvailable ? "local" : "gateway",
            "fallback": "ssh \(Tunnel.sshHost) ~/.local/bin/transcribe",
        ]
    }

    // MARK: - permission

    private func authorize(_ then: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: then(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { then(ok) }
            }
        default: then(false)
        }
    }

    // MARK: - the hold

    func start(requestId: String) {
        guard active == nil else { return }                 // a hold is already open
        active = requestId
        emit(requestId, "arming", nil, nil)
        authorize { [weak self] ok in
            guard let self else { return }
            guard self.active == requestId else { return }  // released before the grant
            guard ok else {
                self.active = nil
                self.emit(requestId, "error", nil,
                          "Bridge has no microphone permission. Grant it in System Settings → "
                          + "Privacy & Security → Microphone, then hold space again.")
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge-voice-\(UUID().uuidString.prefix(8)).wav")
            // 16 kHz mono 16-bit LinearPCM: exactly what whisper wants, so
            // nothing has to resample it afterwards.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            do {
                let rec = try AVAudioRecorder(url: url, settings: settings)
                guard rec.record(forDuration: Voice.maxSeconds) else {
                    throw NSError(domain: "bridge.voice", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "the recorder refused to start"])
                }
                self.recorder = rec
                self.file = url
                self.startedAt = Date()
                self.emit(requestId, "recording", nil, nil)
            } catch {
                self.active = nil
                self.emit(requestId, "error", nil, "could not open the microphone: \(error.localizedDescription)")
            }
        }
    }

    func stop(requestId: String) {
        guard active == requestId, let rec = recorder, let url = file else {
            // A stop with no matching start is the ordinary result of releasing
            // space during the permission prompt. Say nothing rather than
            // reporting an error for something that is not one.
            if active == requestId { active = nil }
            emit(requestId, "idle", nil, nil)
            return
        }
        let held = Date().timeIntervalSince(startedAt ?? Date())
        rec.stop()
        recorder = nil
        file = nil
        startedAt = nil
        active = nil

        guard held >= Voice.minSeconds else {
            try? FileManager.default.removeItem(at: url)
            emit(requestId, "idle", nil, nil)
            return
        }
        emit(requestId, "transcribing", nil, nil)
        transcribe(url) { [weak self] text, route, err in
            try? FileManager.default.removeItem(at: url)
            if let err { self?.emit(requestId, "error", nil, err); return }
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.emit(requestId, t.isEmpty ? "empty" : "done", t, nil, route: route)
        }
    }

    /// Released without a recording ever opening, or the window lost focus.
    func cancel() {
        guard let id = active else { return }
        recorder?.stop()
        if let f = file { try? FileManager.default.removeItem(at: f) }
        recorder = nil; file = nil; startedAt = nil; active = nil
        emit(id, "idle", nil, nil)
    }

    // MARK: - transcription

    private func transcribe(_ wav: URL, _ done: @escaping (String?, String, String?) -> Void) {
        if let bin = Voice.binary, let model = Voice.model {
            run(bin, ["-m", model.path, "-f", wav.path, "-nt", "-np", "-t", "6"]) { out, err in
                if let out, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    done(Voice.clean(out), "local", nil)
                } else {
                    // Local whisper existed and produced nothing. That is a real
                    // failure, not a reason to quietly ship the audio to another
                    // machine — the fallback is for a MISSING local install.
                    done(nil, "local", "whisper-cli produced no text" + (err.map { ": " + $0 } ?? ""))
                }
            }
            return
        }
        // Fallback: the gateway host's own faster-whisper, over the ssh path
        // Bridge already uses. Copied there, transcribed, removed. Reported as
        // "gateway" on screen so this is never mistaken for the local route.
        let remote = "/tmp/bridge-voice-\(UUID().uuidString.prefix(8)).wav"
        run(URL(fileURLWithPath: "/usr/bin/scp"),
            ["-B", "-q", wav.path, "\(Tunnel.sshHost):\(remote)"], env: Tunnel.pathEnv) { _, scpErr in
            guard scpErr == nil else { done(nil, "gateway", "could not copy audio to the gateway host"); return }
            self.run(URL(fileURLWithPath: "/usr/bin/ssh"),
                     ["-o", "BatchMode=yes", Tunnel.sshHost,
                      "~/.local/bin/transcribe \(remote) small.en; rm -f \(remote)"],
                     env: Tunnel.pathEnv) { out, err in
                let t = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { done(nil, "gateway", err ?? "the gateway host returned no text") }
                else { done(Voice.clean(t), "gateway", nil) }
            }
        }
    }

    /// whisper prints bracketed non-speech markers — [BLANK_AUDIO], [ Silence ],
    /// (wind blowing) — and inserting those into the composer is worse than
    /// inserting nothing.
    static func clean(_ s: String) -> String {
        var out = s
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)"] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Internal rather than private ONLY so the smoke test can drive the real
    /// drain against a real child that floods stderr. The sequential shape this
    /// replaced deadlocked, and a deadlock is not visible in any output.
    func run(_ exe: URL, _ args: [String], env: [String: String]? = nil,
                     _ done: @escaping (String?, String?) -> Void) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, b in b } }
        let out = Pipe(), errp = Pipe()
        p.standardOutput = out
        p.standardError = errp
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { done(nil, error.localizedDescription) }
                return
            }
            // BOTH pipes must be drained CONCURRENTLY. Reading stdout to EOF
            // first deadlocks the moment the child writes more than a pipe
            // buffer (64 KiB) to stderr: the child blocks on a full stderr,
            // never closes stdout, and this thread waits forever. Measured —
            // 20k stderr lines against the sequential shape returns nothing and
            // never comes back, which for dictation is a hold that silently
            // produces no text and leaks a thread per attempt. whisper-cli is
            // exactly the kind of tool that does this: model-load and timing
            // chatter goes to stderr while the transcript goes to stdout.
            var o = Data(), e = Data()
            let drained = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: drained) {
                o = out.fileHandleForReading.readDataToEndOfFile()
            }
            DispatchQueue.global(qos: .userInitiated).async(group: drained) {
                e = errp.fileHandleForReading.readDataToEndOfFile()
            }
            drained.wait()
            p.waitUntilExit()
            let text = String(decoding: o, as: UTF8.self)
            let errText = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                done(p.terminationStatus == 0 ? text : nil,
                     p.terminationStatus == 0 ? nil : (errText.isEmpty ? "exit \(p.terminationStatus)" : errText))
            }
        }
    }

    private func emit(_ requestId: String, _ state: String, _ text: String?, _ error: String?,
                      route: String = "") {
        var msg: [String: Any] = ["type": "voice", "requestId": requestId, "state": state,
                                  "available": Voice.localAvailable || Keychain.token != nil]
        if let text { msg["text"] = text }
        if let error { msg["error"] = error }
        if !route.isEmpty { msg["route"] = route }
        ActiveWebView.shared.emit(msg)
    }
}
