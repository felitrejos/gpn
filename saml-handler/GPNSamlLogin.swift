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
// The window starts hidden. With a saved identity-provider session the whole
// exchange is redirects, so it usually finishes without ever showing — no
// window, no stolen focus. It appears only when a person is needed: a page
// with a visible field to type into, or `revealAfter` seconds without a
// result (MFA prompts, banners, anything this cannot recognise).
//
// Two Entra ID pages that only ask "continue?" are answered automatically:
// "Stay signed in?" gets Yes, so the next sign-in can be silent too, and
// "Pick an account" with exactly one account picks it. Each is tried at most
// once per run, only on login.microsoftonline.com, and only when its markers
// match; anything else is left for the person. Nothing here ever types into
// a page — usernames, passwords and codes are the person's to enter.
//
// Usage: GPNSamlLogin <saml-url>

import Cocoa
import WebKit

// gpn passes the FIFO it is blocked on; the fallback is only for running
// this by hand.
let fifoPath = ProcessInfo.processInfo.environment["GPN_SAML_FIFO"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/gpn/saml.fifo")

let cookieKeys = ["prelogin-cookie", "portal-userauthcookie"]

// How long a silent sign-in may take before the window shows itself anyway.
// An auto-answered Entra page restarts the clock, since it proves progress.
let revealAfter: TimeInterval = 4
// How often the hidden page is checked for something that wants a person.
let pollEvery: TimeInterval = 0.5

// Progress notes for debugging. gpn discards them; they never carry a URL,
// a page's content or a cookie.
func note(_ s: String) {
    FileHandle.standardError.write("GPNSamlLogin: \(s)\n".data(using: .utf8)!)
}

// Classifies the current page. Returns:
//   "input" — a visible field to type into, or several accounts to choose
//             from: a person is needed now.
//   "kmsi"  — Entra's "Stay signed in?" page.
//   "pick"  — Entra's account picker with exactly one account.
//   ""      — nothing recognisable; keep waiting.
// Kept at column 0 inside a raw string so the source text is the script.
let pageStateJS = #"""
(() => {
  const shown = e => {
    if (!e) return false;
    const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const typing = [...document.querySelectorAll(
    'input:not([type]), input[type=text], input[type=email], input[type=password],' +
    ' input[type=tel], input[type=number], textarea')].some(shown);
  if (typing) return 'input';
  if (location.hostname !== 'login.microsoftonline.com') return '';
  if (document.getElementById('KmsiCheckboxField') && shown(document.getElementById('idSIButton9')))
    return 'kmsi';
  const tiles = [...document.querySelectorAll('#tilesHolder [data-test-id]')]
    .filter(t => (t.getAttribute('data-test-id') || '').includes('@') && shown(t));
  if (tiles.length === 1) return 'pick';
  if (tiles.length > 1) return 'input';
  return '';
})()
"""#

// Answers a page pageStateJS recognised. Re-checks the same markers first and
// does nothing if they no longer match. Clicks only — never fills a field.
let answerJS = #"""
(kind => {
  if (location.hostname !== 'login.microsoftonline.com') return false;
  if (kind === 'kmsi') {
    const b = document.getElementById('idSIButton9');
    if (!document.getElementById('KmsiCheckboxField') || !b) return false;
    b.click();
    return true;
  }
  if (kind === 'pick') {
    const tiles = [...document.querySelectorAll('#tilesHolder [data-test-id]')]
      .filter(t => (t.getAttribute('data-test-id') || '').includes('@'));
    if (tiles.length !== 1) return false;
    tiles[0].click();
    return true;
  }
  return false;
})
"""#

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
    private var revealed = false
    private var revealAt = Date().addingTimeInterval(revealAfter)
    private var answered: Set<String> = []
    private var poll: Timer?
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
        // Not ordered in: the page loads in a window nobody can see yet.
        web.load(URLRequest(url: url))
        poll = Timer.scheduledTimer(withTimeInterval: pollEvery, repeats: true) { [weak self] _ in
            self?.inspect()
        }
    }

    private func finishIfComplete() {
        guard !done,
              let user = found["saml-username"],
              let name = cookieKeys.first(where: { found[$0] != nil }),
              let cookie = found[name]
        else { return }
        done = true
        poll?.invalidate()
        note(revealed ? "delivered" : "delivered without showing the window")
        deliver(user, name, cookie)
        NSApp.terminate(nil)
    }

    // Show the window and bring it forward: a person is needed.
    private func reveal(_ why: String) {
        guard !done, !revealed else { return }
        revealed = true
        note("showing the window (\(why))")
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Activation can be refused when launched from a terminal; the window
        // still has to come up, so order it front regardless.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func inspect() {
        guard !done else { return }
        if !revealed && Date() >= revealAt {
            reveal("no result after \(Int(revealAfter))s")
        }
        web.evaluateJavaScript(pageStateJS) { [weak self] result, _ in
            guard let self, !self.done else { return }
            switch result as? String ?? "" {
            case "input":
                self.reveal("the page wants input")
            case let kind where (kind == "kmsi" || kind == "pick") && !self.answered.contains(kind):
                // Once each per run, so a page that keeps coming back is left
                // to the person rather than clicked in a loop.
                self.answered.insert(kind)
                self.web.evaluateJavaScript("(\(answerJS))('\(kind)')") { r, _ in
                    guard (r as? Bool) == true else { return }
                    note("answered Entra \(kind == "kmsi" ? "\"Stay signed in?\"" : "account picker")")
                    self.revealAt = Date().addingTimeInterval(revealAfter)
                }
            default:
                break
            }
        }
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
            self.inspect()
        }
    }

    // A page that fails to load is a page the person should see. Not a load
    // that was merely superseded — a script redirecting mid-load, or the
    // callback scheme being cancelled above — which is routine in SAML.
    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }  // frame load interrupted
        reveal("a page failed to load")
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failed(error)
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
// No Dock icon and no activation until the window is needed; reveal()
// switches to .regular.
app.setActivationPolicy(.accessory)
let login = Login(url: url)
app.run()
