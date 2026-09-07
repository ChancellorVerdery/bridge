import Foundation
import Network

// Bridge's own web host: the WKWebView loads http://127.0.0.1:<port>/ rather
// than a file:// URL. Two reasons, both from atlas-apple:
//
//   * a loopback http origin is a secure context, so the page gets crypto,
//     structured clone and the rest; file:// is not and quietly is not,
//   * one origin means one place to reason about what the page can reach.
//
// Bridge's server is smaller than Atlas's: there is no proxy, no sidecar splice
// and no OAuth callback, because the only thing behind this origin is a folder
// of static files. Everything dynamic arrives over the JS bridge from Gateway,
// which is native and does not go through HTTP at all.
//
// Connection: close on every response, like Atlas — one request per TCP
// connection keeps the parser trivial and costs nothing on loopback.

struct HTTPRequest {
    let method: String
    let target: String              // path + query, as sent on the wire
    let headers: [String: String]   // names lowercased, last wins
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    func serialize() -> Data {
        let reasons: [Int: String] = [
            200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error",
        ]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

final class LocalServer {
    static let shared = LocalServer()

    // Unlike Atlas, Bridge has no OAuth client pinned to a port, so any free
    // port is fine and there is no "port busy breaks sign-in" trade to make.
    private let queue = DispatchQueue(label: "bridge.localserver")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var origin: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Overridden by the smoke test so fixtures never shadow the shipped bundle.
    static var rootOverride: URL?
    static var root: URL {
        rootOverride ?? Bundle.main.resourceURL!.appendingPathComponent("dist")
    }

    @discardableResult
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        var result: Result<UInt16, Error>?
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: result = .success(l.port?.rawValue ?? 0); ready.signal()
            case .failed(let e): result = .failure(e); ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard case .success(let bound)? = result else {
            l.cancel()
            if case .failure(let e)? = result { throw e }
            throw POSIXError(.ETIMEDOUT)
        }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("bridge: local server listener failed: \(e)") }
        }
        listener = l
        port = bound
        return bound
    }

    // ---- one request per connection ------------------------------------------

    private func accept(_ nw: NWConnection) {
        var buffer = Data()
        nw.start(queue: queue)
        func step() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, err in
                if let data { buffer.append(data) }
                if err != nil { nw.cancel(); return }
                // Cap the head so a client that never sends CRLFCRLF cannot grow
                // this buffer without bound.
                if buffer.count > 64 * 1024 {
                    self.reply(nw, HTTPResponse(status: 413)); return
                }
                if let headEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer.subdata(in: 0..<headEnd.lowerBound), as: UTF8.self)
                    guard let req = Self.parse(head) else {
                        self.reply(nw, HTTPResponse(status: 400)); return
                    }
                    self.reply(nw, Self.staticFile(req))
                    return
                }
                if done { nw.cancel(); return }
                step()
            }
        }
        step()
    }

    private func reply(_ nw: NWConnection, _ res: HTTPResponse) {
        nw.send(content: res.serialize(), completion: .contentProcessed { _ in nw.cancel() })
    }

    static func parse(_ head: String) -> HTTPRequest? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative or non-numeric Content-Length is a malformed request, not a
        // reason to crash: Atlas's smoke test found that one the hard way.
        if let cl = headers["content-length"], Int(cl) == nil || Int(cl)! < 0 { return nil }
        return HTTPRequest(method: String(start[0]), target: String(start[1]),
                           headers: headers, body: Data())
    }

    static func staticFile(_ req: HTTPRequest) -> HTTPResponse {
        guard req.method == "GET" || req.method == "HEAD" else { return HTTPResponse(status: 405) }
        guard let comps = URLComponents(string: req.target), !comps.path.isEmpty else {
            return HTTPResponse(status: 400)
        }
        var rel = comps.path
        if rel.hasSuffix("/") { rel += "index.html" }
        let root = Self.root.standardizedFileURL
        // standardizedFileURL collapses any '..' before the containment check —
        // including the ones that only appear after %2F decoding.
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path == root.path || file.path.hasPrefix(root.path + "/") else {
            return HTTPResponse(status: 403, headers: [("Content-Type", "text/plain")],
                                body: Data("forbidden".utf8))
        }
        guard let data = try? Data(contentsOf: file) else {
            return HTTPResponse(status: 404, headers: [("Content-Type", "text/plain")],
                                body: Data("not found".utf8))
        }
        return HTTPResponse(status: 200, headers: [
            ("Content-Type", mime(file.pathExtension.lowercased())),
            ("Cache-Control", "no-store"),
        ], body: req.method == "HEAD" ? Data() : data)
    }

    static func mime(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
