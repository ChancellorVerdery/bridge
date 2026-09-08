import SwiftUI
import WebKit

// The WKWebView that is the app, pointed at the local server's origin, plus the
// one-way channel Gateway pushes through.
//
// Phase A's channel was one-way: the page's only inbound message was "ready".
// Phase B needs steering, preferences and a settings entry point, so the inbound
// surface widens — and the rule it widens under is worth writing down, because
// it is the whole security posture of this app:
//
//   NOTHING THE PAGE CAN SEND RETURNS A SECRET, AND NOTHING IT CAN SEND
//   CARRIES ONE.
//
// The accepted messages are `ready`, `prefs` (the whole preferences document,
// which contains no secrets), `send` and `abort` (a session key and user-typed
// text), `settings` (open the NATIVE sheet), and Phase C's five: `room.send`,
// `room.pause`, `room.clear`, `question.resolve` and `voice`. There is no
// message that reads the keychain, no message that returns the token, and no
// message that supplies one.
//
// `voice` deserves its own line, because the shorter road was to let the page
// call getUserMedia. That would put a live microphone inside the web layer —
// the one part of this app whose entire security posture is that it holds
// nothing and reaches nothing. Instead the page sends the two strings "start"
// and "stop"; the audio, the model and the transcript never exist in JS until
// the finished text comes back. See Voice.swift.
//
// That last point is a deliberate design choice rather than an oversight. The
// brief asks Settings to offer gateway-token entry; it would have been easy to
// add a `setToken` message and let the web field post its value. That is NOT
// what this does. The token would then exist as a JavaScript string in a
// WKWebView heap, and PROTOCOL.md §8's claim — that the token never crosses
// into the web view — would quietly stop being true in both directions. So the
// web Settings page renders the section, shows whether a token is stored, and
// its button opens the native SecureField sheet. Token entry is real; the token
// never enters JS.

@MainActor
final class ActiveWebView {
    static let shared = ActiveWebView()
    private init() {}

    weak var webView: WKWebView?
    private var queued: [[String: Any]] = []
    private var pageReady = false

    private static let zoomKey = "bridge.webview.pageZoom"
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 3.0
    private static let step: CGFloat = 0.1

    func zoomIn() { setZoom((webView?.pageZoom ?? 1) + Self.step) }
    func zoomOut() { setZoom((webView?.pageZoom ?? 1) - Self.step) }
    func resetZoom() { setZoom(1) }
    private func setZoom(_ z: CGFloat) {
        let clamped = min(Self.maxZoom, max(Self.minZoom, z))
        webView?.pageZoom = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.zoomKey)
    }

    func attach(_ web: WKWebView) {
        webView = web
        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        web.pageZoom = saved > 0 ? min(Self.maxZoom, max(Self.minZoom, CGFloat(saved))) : 1
    }

    /// The page is up and live.js has installed __bridgeEmit. Anything Gateway
    /// produced during the boot race is delivered now, in order — otherwise the
    /// first session list, which arrives fast on a warm gateway, lands before
    /// there is anything to receive it and the window sits on "Connecting".
    func markReady() {
        pageReady = true
        let pending = queued
        queued = []
        for msg in pending { deliver(msg) }
    }

    func markReloading() { pageReady = false }

    func emit(_ msg: [String: Any]) {
        guard pageReady else {
            queued.append(msg)
            // A page that never comes back must not grow this without bound.
            if queued.count > 400 { queued.removeFirst(queued.count - 400) }
            return
        }
        deliver(msg)
    }

    private func deliver(_ msg: [String: Any]) {
        guard let web = webView,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        // Passed as a JSON string and parsed on the other side: interpolating an
        // object literal into source would make every transcript containing a
        // backtick or a line separator a syntax error.
        let escaped = BridgeWebView.Coordinator.jsQuote(json)
        web.evaluateJavaScript("window.__bridgeEmit && window.__bridgeEmit(JSON.parse(\(escaped)))") { _, err in
            if let err { NSLog("bridge: emit failed: \(err.localizedDescription)") }
        }
    }
}

struct BridgeWebView: NSViewRepresentable {
    let origin: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral: Bridge keeps no page state. Everything on screen came from
        // the Gateway this launch, and a cached copy of someone's transcript on
        // disk is a liability with no upside.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "bridge")
        config.userContentController.addUserScript(WKUserScript(
            source: """
            window.__BRIDGE_NATIVE__ = { platform: 'macos' };
            window.__bridgeReady = function () {
              window.webkit.messageHandlers.bridge.postMessage({ t: 'ready' });
            };
            // The page's only way to reach native code. It can send the five
            // message kinds Coordinator accepts and receives nothing back from
            // this call — every reply arrives asynchronously through
            // __bridgeEmit, like all other state.
            window.__bridgeSend = function (msg) {
              try { window.webkit.messageHandlers.bridge.postMessage(msg); } catch (e) { /* not native */ }
            };
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.underPageBackgroundColor = NSColor(srgbRed: 0x09 / 255, green: 0x0B / 255, blue: 0x11 / 255, alpha: 1)
        context.coordinator.webView = web
        ActiveWebView.shared.attach(web)
        web.load(URLRequest(url: origin))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            ActiveWebView.shared.markReloading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // live.js may not have run its handler installation yet if the page
            // is slow; ask, and fall back to marking ready after the run loop
            // turns so a page without __bridgeReady still receives events.
            webView.evaluateJavaScript("window.__bridgeReady && window.__bridgeReady(), true") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    ActiveWebView.shared.markReady()
                }
            }
        }

        /// Called with each accepted inbound message. Set by Shell at startup so
        /// the routing lives next to the things it drives rather than in here.
        static var onMessage: (([String: Any]) -> Void)?

        // The whole inbound surface. Every branch is listed; anything else is
        // dropped without comment.
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "bridge",
                  let body = message.body as? [String: Any],
                  let t = body["t"] as? String else { return }
            switch t {
            case "ready":
                ActiveWebView.shared.markReady()
                Self.onMessage?(body)
            // PHASE C adds five, and every one of them still satisfies the rule
            // at the top of this file: room.send / room.pause / room.clear carry
            // user-typed text and an agent id; question.resolve carries two ids
            // and a chosen option label the page read off the record it was
            // shown; voice carries "start" or "stop" and nothing else. None
            // returns a secret and none carries one.
            case "prefs", "send", "abort", "settings", "reconnect",
                 "room.send", "room.pause", "room.clear", "question.resolve", "voice",
                 "studyStore":
                Self.onMessage?(body)
            default:
                break
            }
        }

        // Bridge never navigates away from its own origin, and never opens a
        // popup: an external link goes to the system browser.
        //
        // THIS IS AN ALLOW-LIST, and it did not used to be. The old shape was a
        // `guard scheme == http || https … else { .allow }`, whose else-branch
        // permitted every navigation it had not thought about — `file:`,
        // `data:`, `javascript:`, `blob:`, any registered app scheme — because
        // failing the http test fell straight into `.allow`. So the one rule
        // this method exists to enforce, stated in the sentence above it, was
        // the exact set of URLs it did not enforce against.
        //
        // Nothing reachable exploits it today: the transcript renderer builds
        // no anchors from agent output, so there is no path from a tool result
        // to a navigation. That is a property of the renderer, not of this
        // method, and it is one refactor away from not being true. A guard for
        // an invariant should hold because of what it says, not because of what
        // some other file currently happens not to do.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            let scheme = url.scheme?.lowercased() ?? ""
            // Bridge's own loopback origin — the only thing that may render here.
            if scheme == "http", url.host == "127.0.0.1", url.port == Int(LocalServer.shared.port) {
                decisionHandler(.allow); return
            }
            // WebKit's own internal navigations. Refusing these breaks the frame
            // machinery rather than protecting anything.
            if scheme == "about" { decisionHandler(.allow); return }
            // A real outbound link: hand it to the system browser, as before.
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
                return
            }
            // Neither this app's origin nor a link. Refuse it, and say so —
            // silence here would be indistinguishable from a broken link.
            NSLog("bridge: refused a navigation to a non-origin scheme: \(scheme):")
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }

        /// A JSON-safe single-quoted JS string literal.
        static func jsQuote(_ s: String) -> String {
            var out = "'"
            for u in s.unicodeScalars {
                switch u {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\u{2028}": out += "\\u2028"
                case "\u{2029}": out += "\\u2029"
                default: out.unicodeScalars.append(u)
                }
            }
            return out + "'"
        }
    }
}
