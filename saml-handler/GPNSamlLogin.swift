// GPNSamlLogin — performs a GlobalProtect SAML login and hands the result to
// a waiting `gpn connect`.
//
// A GlobalProtect portal does not finish SAML with a tidy redirect. It returns
// the result in one of three ways, depending on how the portal is configured,
// and a client has to accept all of them:
//
//   1. HTTP response headers on the final page: saml-username, prelogin-cookie
//      (or portal-userauthcookie).
//   2. The same fields as an XML fragment inside an HTML comment in the body —
//      the page that renders as a bare "authentication successful".
//   3. A redirect to globalprotectcallback:<base64> wrapping the same fields.
//
// Only 3 can escape a browser, and most portals do not use it, so the login
// has to happen somewhere we can read headers: this window.
//
// The cookie is a live credential. It is never written to a file, logged, or
// passed as an argument — only into the FIFO gpn is blocked on, which holds it
// in kernel memory until gpn reads it. Three lines go in: the username, which
// cookie was returned, and its value. Which cookie it is decides openconnect's
// --usergroup, so gpn has to be told rather than guess.
//
// Usage: GPNSamlLogin <saml-url>

import Cocoa
import WebKit

// gpn passes the FIFO it is blocked on; the fallback is only for running
// this by hand.
let fifoPath = ProcessInfo.processInfo.environment["GPN_SAML_FIFO"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/gpn/saml.fifo")

let cookieKeys = ["prelogin-cookie", "portal-userauthcookie"]

func isWanted(_ key: String) -> Bool {
    key.hasPrefix("saml-") || cookieKeys.contains(key)
}

// O_NONBLOCK: if no `gpn connect` is waiting, fail fast rather than hang.
func deliver(_ user: String, _ name: String, _ cookie: String) {
    let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var bytes = Array("\(user)\n\(name)\n\(cookie)\n".utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes {
            write(fd, $0.baseAddress!.advanced(by: off), bytes.count - off)
        }
        if n <= 0 { break }
        off += n
    }
    for i in bytes.indices { bytes[i] = 0 }
}

func tagValue(_ name: String, in text: String) -> String? {
    guard let o = text.range(of: "<\(name)>"),
          let c = text.range(of: "</\(name)>", range: o.upperBound..<text.endIndex)
    else { return nil }
    let v = String(text[o.upperBound..<c.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
}

final class Login: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var found: [String: String] = [:]
    private var done = false
    private let window: NSWindow
    private let web: WKWebView

    init(url: URL) {
        let cfg = WKWebViewConfiguration()
        // The persistent store is the point: the identity provider session
        // survives between connects, so most logins need no typing at all.
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                        configuration: cfg)

        window = NSWindow(contentRect: web.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "VPN sign-in"
        window.contentView = web
        window.center()

        super.init()
        web.navigationDelegate = self
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: url))
    }

    private func finishIfComplete() {
        guard !done,
              let user = found["saml-username"],
              let name = cookieKeys.first(where: { found[$0] != nil }),
              let cookie = found[name]
        else { return }
        done = true
        deliver(user, name, cookie)
        NSApp.terminate(nil)
    }

    // 3 — the callback scheme, when a portal does use it.
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, u.scheme == "globalprotectcallback" {
            decisionHandler(.cancel)
            var b64 = u.absoluteString
                .replacingOccurrences(of: "globalprotectcallback:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            b64 = (b64.removingPercentEncoding ?? b64)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            if b64.count % 4 != 0 { b64 += String(repeating: "=", count: 4 - b64.count % 4) }
            if let d = Data(base64Encoded: b64), let xml = String(data: d, encoding: .utf8) {
                for k in ["saml-username"] + cookieKeys {
                    if let v = tagValue(k, in: xml) { found[k] = v }
                }
                finishIfComplete()
            }
            return
        }
        decisionHandler(.allow)
    }

    // 1 — response headers, the most common delivery.
    func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse {
            for (k, v) in http.allHeaderFields {
                let key = String(describing: k).lowercased()
                if isWanted(key) { found[key] = String(describing: v) }
            }
        }
        decisionHandler(.allow)
        finishIfComplete()
    }

    // 2 — the same fields hidden in an HTML comment in the body.
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        guard !done else { return }
        w.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else { return }
            var rest = Substring(html)
            while let o = rest.range(of: "<!--"), let c = rest.range(of: "-->", range: o.upperBound..<rest.endIndex) {
                let comment = String(rest[o.upperBound..<c.lowerBound])
                for k in ["saml-username"] + cookieKeys {
                    if let v = tagValue(k, in: comment) { self.found[k] = v }
                }
                rest = rest[c.upperBound...]
            }
            self.finishIfComplete()
        }
    }

    // Closing the window is how you cancel; gpn then times out and says so.
    func windowWillClose(_ note: Notification) {
        if !done { NSApp.terminate(nil) }
    }
}

let args = CommandLine.arguments
guard args.count > 1, let url = URL(string: args[1]) else {
    FileHandle.standardError.write("usage: GPNSamlLogin <saml-url>\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let login = Login(url: url)
app.run()
