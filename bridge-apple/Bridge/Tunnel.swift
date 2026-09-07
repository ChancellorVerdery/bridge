import Foundation
import Network

// The Gateway listens on 127.0.0.1:18789 on the Linux box and nowhere else —
// that is the whole security posture, and Bridge does not get to change it. The
// Mac already reaches that box over SSH as host `atlas`, whose config tries
// atlas.local on the LAN and falls back to a cloudflared tunnel off it. So the
// transport is an SSH local forward, managed here as a child process in the
// spirit of atlas-apple's Sidecar.swift.
//
// Nothing about this widens the Gateway's exposure: the forward terminates on
// loopback at both ends and dies with the app. `ssh` gets the whole thing —
// host resolution, ProxyCommand fallback, keys — from the user's own
// ~/.ssh/config, so there is no second copy of that configuration to drift.
final class Tunnel {
    static let shared = Tunnel()

    // A fixed-ish window rather than :0 — a stable port makes the thing
    // greppable in `lsof` when it misbehaves, and 10 candidates is plenty.
    static let portRange: ClosedRange<UInt16> = 18790...18799
    /// The ssh destination, from Bridge's own prefs. It is a NAME, resolved by
    /// the user's ~/.ssh/config — which is where the LAN-then-cloudflared
    /// fallback lives. Bridge keeps no second copy of that, so making this
    /// editable does not turn into "now Bridge also needs a hostname, a port,
    /// a user and a key path".
    static var sshHost: String {
        let h = Prefs.current.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? Prefs.defaultSSHHost : h
    }
    static let remote = "127.0.0.1:18789"

    /// A GUI app inherits a bare PATH. The `atlas` host's ProxyCommand shells
    /// out to `nc` and to cloudflared under Homebrew; without these, ssh fails
    /// with a command-not-found message OFF LAN ONLY — the worst possible time
    /// to discover it.
    ///
    /// Exposed rather than inlined because Voice.swift's gateway fallback shells
    /// out to the same `ssh` and `scp` against the same host, and two copies of
    /// this that drift is exactly how the off-LAN case breaks again in a place
    /// nobody thought to look.
    static var pathEnv: [String: String] {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ["PATH": base + ":/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"]
    }

    private let lock = NSLock()
    private var process: Process?
    private var _port: UInt16 = 0
    private var _lastError: String?
    /// The last line ssh printed to stderr. DIAGNOSTIC CONTEXT, not a verdict:
    /// ssh says plenty on stderr that is not a failure. Used only to enrich an
    /// error this class has decided on for itself.
    private var _lastStderr: String?

    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return _port }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }
    var lastStderr: String? { lock.lock(); defer { lock.unlock() }; return _lastStderr }
    var isRunning: Bool { (process?.isRunning ?? false) && port != 0 }

    // An explicit override for a Mac that is already forwarding the port by hand
    // (or for a future build that reaches the Gateway directly).
    static var override: UInt16? {
        if let s = ProcessInfo.processInfo.environment["BRIDGE_GATEWAY_PORT"], let n = UInt16(s) { return n }
        return nil
    }

    /// Brings the forward up and returns the local port, or nil with `lastError` set.
    /// Blocks until the port accepts a connection (or the timeout elapses).
    @discardableResult
    func start() -> UInt16? {
        if let fixed = Self.override {
            lock.lock(); _port = fixed; _lastError = nil; lock.unlock()
            NSLog("bridge: BRIDGE_GATEWAY_PORT=\(fixed) — not spawning ssh")
            return fixed
        }
        if isRunning { return port }
        stop()
        lock.lock(); _lastStderr = nil; _lastError = nil; lock.unlock()

        guard let free = Self.firstFreePort() else {
            setError("no free local port in \(Self.portRange) — another Bridge, or a "
                     + "leaked ssh forward, is holding all ten")
            return nil
        }

        // ssh is launched through a tiny shell wrapper rather than directly, and
        // the reason is a bug this app actually hit: an ssh child outlived its
        // Bridge — the headless --smoke run calls exit(), which never runs a
        // termination handler — and went on holding its forwarded port. Four
        // such orphans later, the next launch found the whole range busy and
        // reported "no free local port", which reads like a Bridge bug and is
        // really a leak.
        //
        // The wrapper holds the read end of the parent's stdin pipe. Two paths
        // out, and both kill the forward:
        //   * Bridge goes away for any reason — clean quit, exit(), crash,
        //     SIGKILL — the write end closes, `cat` returns, EXIT trap fires.
        //   * stop() terminates the wrapper — TERM trap fires.
        // The trap is what makes the second case work; without it a SIGTERM to
        // the shell takes `cat` with it and the kill line is never reached.
        // Same idea as atlas-apple's Sidecar, which watches its stdin pipe for
        // exactly this reason; ssh itself will not do it with -N.
        let wrapper = """
        trap 'kill "$ssh_pid" 2>/dev/null' EXIT TERM INT
        /usr/bin/ssh "$@" &
        ssh_pid=$!
        cat > /dev/null
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c", wrapper, "bridge-ssh",
            "-N",
            "-o", "BatchMode=yes",              // never prompt; a hung prompt is a hung app
            "-o", "ExitOnForwardFailure=yes",   // fail loudly if the port is taken
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=20",
            "-L", "\(free):\(Self.remote)",
            Self.sshHost,
        ]
        p.environment = ProcessInfo.processInfo.environment
            .merging(Self.pathEnv) { _, b in b }
        p.standardInput = Pipe()
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        // ssh's stderr is the only place a forward failure is ever explained.
        //
        // Two things here are not incidental.
        //
        // The EOF nil is load-bearing. A FileHandle readabilityHandler that is
        // never cleared keeps firing with EMPTY data once the write end closes,
        // and the `guard !text.isEmpty` below returns from each one without
        // stopping any of them. Measured on this Mac: 741,795 invocations in
        // the first second after the child exits — a pinned core for as long as
        // the pipe stays alive, which is until something calls start()/stop().
        // ssh exiting on its own (wifi drop, ServerAliveCountMax, laptop sleep)
        // reaches exactly that state and nothing in terminationHandler releases
        // the process, so the spin outlives the tunnel it was reporting on.
        //
        // And this is `_lastStderr`, NOT `_lastError`. ssh writes non-failures
        // to stderr — "Warning: Permanently added '…' to the list of known
        // hosts" is the ordinary first-connect case. Recording those as THE
        // error meant the two `lastError ?? …` fallbacks below reported a
        // known-hosts warning as the cause of an unrelated 30-second timeout,
        // and left a stale "error" behind on a tunnel that came up fine.
        Self.drainStderr(err.fileHandleForReading) { [weak self] line in
            NSLog("bridge: ssh: \(line)")
            self?.setStderr(line)
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock(); self._port = 0; self.lock.unlock()
            NSLog("bridge: ssh forward exited (\(proc.terminationStatus))")
        }

        do { try p.run() } catch {
            setError("could not launch ssh: \(error.localizedDescription)")
            return nil
        }
        process = p

        // Ready means the forward accepts a TCP connection, not that ssh started:
        // ssh forks the ProxyCommand and binds the listener asynchronously, and
        // connecting too early is a connection refused that looks like a dead
        // gateway.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !p.isRunning {
                fail("ssh exited immediately (status \(p.terminationStatus))")
                return nil
            }
            if Self.accepts(port: free) {
                lock.lock(); _port = free; _lastError = nil; lock.unlock()
                NSLog("bridge: ssh forward up on 127.0.0.1:\(free) -> \(Self.sshHost):\(Self.remote)")
                return free
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        fail("ssh forward did not come up within 30s")
        p.terminate()
        return nil
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        lock.lock(); _port = 0; lock.unlock()
    }

    private func setError(_ s: String) {
        lock.lock(); _lastError = s; lock.unlock()
    }

    private func setStderr(_ s: String) {
        lock.lock(); _lastStderr = s; lock.unlock()
    }

    /// An error of this class's own choosing, with ssh's last word appended
    /// when there is one. `explain` is always the real cause; the stderr line
    /// is context, which is the opposite of the old `lastError ?? sshLine`.
    private func fail(_ explain: String) {
        let tail = lastStderr.map { " — ssh said: " + $0 } ?? ""
        setError(explain + tail)
    }

    // ---- port helpers -------------------------------------------------------

    /// Wires a line-reporting readability handler that CLEARS ITSELF AT EOF.
    /// Named and internal so the smoke test can drive this exact code against a
    /// real child process — the spin it prevents is invisible in every output
    /// the app produces and only shows up as a hot core.
    static func drainStderr(_ handle: FileHandle, _ onLine: @escaping (String) -> Void) {
        handle.readabilityHandler = { hnd in
            let data = hnd.availableData
            if data.isEmpty { hnd.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onLine(text.components(separatedBy: "\n").last ?? text)
        }
    }

    private static func firstFreePort() -> UInt16? {
        for candidate in portRange where canBind(candidate) { return candidate }
        return nil
    }

    /// True when nothing else holds the port. Uses a real bind: asking the OS is
    /// the only answer that is not a guess.
    private static func canBind(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ok == 0
    }

    private static func accepts(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ok == 0
    }
}
