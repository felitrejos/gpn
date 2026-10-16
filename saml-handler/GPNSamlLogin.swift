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
// Optionally, 1Password fills the identity provider's sign-in (see Filler
// below). gpn passes a secret *reference*, never a secret; the window asks
// `op` for one field at a time, only when the page shows that field.
//
// Usage: GPNSamlLogin <saml-url>
//
// Environment, set by gpn:
//   GPN_SAML_FIFO     where to deliver the result
//   GPN_OP_ITEM       op://Vault/Item — enables 1Password fill
//   GPN_OP_AUTOFILL   1 = fill as fields appear, 0 = only on Cmd+Shift+L
//   GPN_FILL_HOSTS    hosts that may be filled (default login.microsoftonline.com)
// and for testing against a local fixture with a fake `op`:
//   GPN_OP_BIN        the op binary; found on PATH when unset

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

// MARK: - 1Password fill
//
// The window can fill the identity provider's sign-in from 1Password. Each
// field is read with `op read` only once the page asks for it, through a pipe:
// the value never reaches argv, the environment, a file or a log. It goes into
// the page as an argument to callAsyncJavaScript, which WebKit serialises, so
// no value is ever spliced into script source.
//
// The guard rails are the point. Only an allowlisted host over https is filled
// (loopback may use http, for testing). Each field is filled once per session:
// if the page asks for the same field again, or shows an error, the first
// attempt was refused and autofill stops for good — the user takes over, and
// no account is locked by a loop. A failed or cancelled `op` stops it too. An
// Authenticator push has no field and is left to the user.

let env = ProcessInfo.processInfo.environment

func note(_ s: String) {
    FileHandle.standardError.write("\(s)\n".data(using: .utf8)!)
}

/// GPN_OP_ITEM if it is a well-formed op://Vault/Item reference. Anything else
/// — a pasted password, say — is refused rather than passed to `op` in argv.
func opItemReference() -> String? {
    guard var ref = env["GPN_OP_ITEM"]?.trimmingCharacters(in: .whitespaces),
          !ref.isEmpty else { return nil }
    while ref.hasSuffix("/") { ref.removeLast() }
    let parts = ref.hasPrefix("op://")
        ? ref.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false) : []
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
          ref.rangeOfCharacter(from: CharacterSet(charactersIn: "?\n\r")) == nil
    else {
        note("GPN_OP_ITEM is not an op://Vault/Item reference; 1Password fill is off")
        return nil
    }
    return ref
}

func opBinary() -> String? {
    let fm = FileManager.default
    if let p = env["GPN_OP_BIN"], !p.isEmpty { return fm.isExecutableFile(atPath: p) ? p : nil }
    let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin"]
    return dirs.map { ($0 as NSString).appendingPathComponent("op") }
        .first { fm.isExecutableFile(atPath: $0) }
}

let fillHosts: [String] = (env["GPN_FILL_HOSTS"] ?? "login.microsoftonline.com")
    .split(whereSeparator: { $0 == "," || $0 == " " })
    .map { $0.lowercased() }

func fillAllowed(_ url: URL?) -> Bool {
    guard let url, let host = url.host?.lowercased(), fillHosts.contains(host) else { return false }
    let loopback = ["127.0.0.1", "localhost", "::1"].contains(host)
    return url.scheme == "https" || (loopback && url.scheme == "http")
}

/// One field from 1Password, or nil if `op` failed, was cancelled, or hung.
/// Blocking: never call it on the main thread.
func opRead(_ bin: String, _ ref: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["read", "--no-newline", ref]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    // Long enough to answer a Touch ID prompt, short enough not to wedge.
    let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: kill)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    kill.cancel()
    guard p.terminationReason == .exit, p.terminationStatus == 0,
          let v = String(data: data, encoding: .utf8), !v.isEmpty else { return nil }
    return v
}

// Runs in the page's main frame, in WebKit's client content world: the page
// can neither see these functions nor post to the handler they report to. It
// reports what the page wants each time that changes. Entra swaps the
// username view for the password view without a page load, so this watches
// the DOM rather than waiting for didFinish.
let watcherJS = """
(() => {
  if (window.__gpn) return;
  const fields = [["otp", 'input[name="otc"]'], ["password", 'input[name="passwd"]'],
                  ["username", 'input[name="loginfmt"]']];
  const errors = '#usernameError, #passwordError, #idTD_Error, #idSpan_SAOTCC_Error_OTC, .alert-error';
  // Entra keeps an off-screen copy of loginfmt on the password view; skip it.
  const shown = el => {
    if (!el || el.closest('[aria-hidden="true"]')) return false;
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 &&
           s.visibility !== "hidden" && s.display !== "none";
  };
  const pick = sel => [...document.querySelectorAll(sel)]
    .find(el => el.type !== "hidden" && !el.disabled && !el.readOnly && shown(el));
  const need = () => {
    for (const [kind, sel] of fields) { const el = pick(sel); if (el) return el.value ? "" : kind; }
    if (document.querySelector("#KmsiCheckboxField") && pick("#idSIButton9")) return "kmsi";
    return "";
  };
  const state = () =>
    [...document.querySelectorAll(errors)].some(e => shown(e) && e.textContent.trim()) ? "error" : need();
  let last = null, timer = null;
  const report = () => {
    timer = null;
    const s = state();
    if (s !== last) { last = s; if (s) webkit.messageHandlers.gpnFill.postMessage(s); }
  };
  const soon = () => { if (!timer) timer = setTimeout(report, 150); };
  window.__gpn = { need, pick, rescan: () => { last = null; soon(); } };
  new MutationObserver(soon).observe(document.documentElement,
    { subtree: true, childList: true, attributes: true, characterData: true });
  setInterval(soon, 1000);
  soon();
})();
"""

// Fills one field and submits. `kind`, `value` and `hosts` arrive as
// arguments, never as source. Rechecks the host: the page may have moved on
// while `op` waited for Touch ID.
let fillJS = """
if (!window.__gpn || !hosts.includes(location.hostname.toLowerCase())) return "host";
const sel = { username: 'input[name="loginfmt"]', password: 'input[name="passwd"]',
              otp: 'input[name="otc"]' }[kind];
if (sel) {
  const el = window.__gpn.pick(sel);
  if (!el || el.value) return "absent";
  el.focus();
  // The prototype setter, then events, so knockout or React sees the value.
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
  for (const t of ["input", "change"]) el.dispatchEvent(new Event(t, { bubbles: true }));
}
await new Promise(r => setTimeout(r, 200));
const button = window.__gpn.pick("#idSubmit_SAOTCC_Continue") || window.__gpn.pick("#idSIButton9");
if (!button) return "filled";
button.click();
return "submitted";
"""

final class Filler: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    private let item: String
    private let bin: String
    private let autofill: Bool
    private var filled: Set<String> = []
    private var stopped = false
    private var busy = false

    private static let fields = [
        "username": "username",
        "password": "password",
        "otp": "one-time password?attribute=otp",
    ]

    /// nil when 1Password fill is not configured or `op` is missing.
    init?(config: WKWebViewConfiguration) {
        guard let item = opItemReference() else { return nil }
        guard let bin = opBinary() else { note("op not found; 1Password fill is off"); return nil }
        self.item = item
        self.bin = bin
        autofill = env["GPN_OP_AUTOFILL"] != "0"
        super.init()
        let ucc = config.userContentController
        ucc.add(self, contentWorld: .defaultClient, name: "gpnFill")
        ucc.addUserScript(WKUserScript(source: watcherJS, injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true, in: .defaultClient))
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, let kind = m.body as? String else { return }
        if kind == "error" { stop("the page reported an error"); return }
        guard autofill, !stopped, !busy else { return }
        // Asked twice for the same field: the first fill was refused.
        if filled.contains(kind) { stop("asked for \(kind) again"); return }
        fill(kind)
    }

    /// Fill from 1Password (Cmd+Shift+L): whatever field is showing, even with
    /// autofill off or stopped. Still only on an allowed host.
    @objc func fillNow(_ sender: Any?) {
        guard !busy, let web, fillAllowed(web.url) else { return }
        web.callAsyncJavaScript("return window.__gpn ? window.__gpn.need() : \"\"",
                                arguments: [:], in: nil, in: .defaultClient) { [weak self] r in
            if case .success(let v) = r, let kind = v as? String, !kind.isEmpty {
                self?.fill(kind)
            }
        }
    }

    private func stop(_ why: String) {
        if !stopped { note("1Password: autofill stopped, \(why)") }
        stopped = true
    }

    private func fill(_ kind: String) {
        guard let web, fillAllowed(web.url) else { return }
        let field = Filler.fields[kind]
        guard field != nil || kind == "kmsi" else { return }
        busy = true
        filled.insert(kind)
        guard let field else { inject(kind, ""); return }
        let (bin, ref) = (bin, "\(item)/\(field)")
        DispatchQueue.global(qos: .userInitiated).async {
            let value = opRead(bin, ref)
            DispatchQueue.main.async {
                guard let value else {
                    // Failed or cancelled: the window is the user's now.
                    self.busy = false
                    self.stop("op could not read \(kind)")
                    return
                }
                self.inject(kind, value)
            }
        }
    }

    private func inject(_ kind: String, _ value: String) {
        guard let web, fillAllowed(web.url) else { busy = false; return }
        web.callAsyncJavaScript(fillJS, arguments: ["kind": kind, "value": value, "hosts": fillHosts],
                                in: nil, in: .defaultClient) { [weak self] r in
            guard let self else { return }
            self.busy = false
            if case .success(let v) = r { note("1Password: \(kind) \(v as? String ?? "")") }
            // Anything that changed while busy was swallowed; look again.
            self.web?.callAsyncJavaScript("window.__gpn && window.__gpn.rescan()",
                                          arguments: [:], in: nil, in: .defaultClient)
        }
    }
}

final class Login: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var found: [String: String] = [:]
    private var done = false
    private let window: NSWindow
    private let web: WKWebView
    let filler: Filler?

    init(url: URL) {
        let cfg = WKWebViewConfiguration()
        // The persistent store is the point: the identity provider session
        // survives between connects, so most logins need no typing at all.
        cfg.websiteDataStore = .default()
        filler = Filler(config: cfg)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                        configuration: cfg)
        filler?.web = web

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

// Without a main menu there are no key equivalents: no Quit, and no paste
// into the sign-in form.
func mainMenu(fill target: Filler?) -> NSMenu {
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit VPN sign-in",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    if let target {
        edit.addItem(.separator())
        let item = edit.addItem(withTitle: "Fill from 1Password",
                                action: #selector(Filler.fillNow(_:)), keyEquivalent: "l")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = target
    }

    let menu = NSMenu()
    for sub in [appMenu, edit] {
        let item = NSMenuItem()
        item.submenu = sub
        menu.addItem(item)
    }
    return menu
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let login = Login(url: url)
app.mainMenu = mainMenu(fill: login.filler)
app.run()
