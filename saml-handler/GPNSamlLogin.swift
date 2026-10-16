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
// window, no stolen focus. It appears only when a person is needed: a field
// 1Password is not filling, or `revealAfter` seconds without progress (an
// Authenticator push, a banner, anything this cannot recognise).
//
// Two Entra ID pages that only ask "continue?" are answered automatically:
// "Stay signed in?" gets Yes, so the next sign-in can be silent too, and
// "Pick an account" with exactly one account picks it. Each is tried at most
// once per run, only on the fill hosts (login.microsoftonline.com unless
// configured), and only when its markers match; anything else is left for
// the person.
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
//   GPN_FILL_HOSTS    hosts that may be filled or clicked (default login.microsoftonline.com)
// and for testing against a local fixture with a fake `op`:
//   GPN_OP_BIN        the op binary; found on PATH when unset

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

// Progress notes for debugging; gpn appends them to the profile's log. They
// name hosts and field names at most — never a path, a query, a page's
// content, a cookie or a filled value.
let noteTime: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func note(_ s: String) {
    let line = "[\(noteTime.string(from: Date()))] sign-in: \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// Classifies the current page. Returns:
//   "input" — a visible field to type into, or several accounts to choose
//             from: a person is needed now. Unknown fields come back as
//             "input:<name,…>" — their names only, for the log.
//   "fillable" — only sign-in fields 1Password knows (`names`), which it
//             may be about to fill.
//   "kmsi"  — Entra's "Stay signed in?" page.
//   "pick"  — Entra's account picker with exactly one account.
//   ""      — nothing recognisable; keep waiting.
// Both scripts are function bodies run with callAsyncJavaScript in the client
// content world; `hosts` (the fill allowlist), `names` (the fillable field
// names) and `kind` arrive as arguments.
// Kept at column 0 inside a raw string so the source text is the script.
let pageStateJS = #"""
return (() => {
  const shown = e => {
    if (!e) return false;
    const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const typing = [...document.querySelectorAll(
    'input:not([type]), input[type=text], input[type=email], input[type=password],' +
    ' input[type=tel], input[type=number], textarea')].filter(shown);
  if (typing.length)
    return typing.every(e => names.includes(e.name)) ? 'fillable'
      : 'input:' + typing.map(e => e.name || e.id || e.type).join(',');
  if (!hosts.includes(location.hostname.toLowerCase().replace(/\.mcas\.ms$/, ''))) return '';
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
return (kind => {
  if (!hosts.includes(location.hostname.toLowerCase().replace(/\.mcas\.ms$/, ''))) return false;
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
})(kind)
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

// The sign-in fields 1Password can fill, by the input's name, and the item
// field each one reads: Entra's own pages, and NetIQ Access Manager (the
// provider many institutions federate Entra to). Kept in the order a page
// should be filled: username before password, so a page that shows both
// is submitted once, with both.
let fillFields: KeyValuePairs<String, String> = [
    "loginfmt": "username",          // Entra: email
    "Ecom_User_ID": "username",      // NetIQ
    "passwd": "password",            // Entra
    "Ecom_Password": "password",     // NetIQ
    "otc": "one-time password?attribute=otp",  // Entra: verification code
]
let fillNames = fillFields.map { $0.key }

let fillHosts: [String] = (env["GPN_FILL_HOSTS"] ?? "login.microsoftonline.com")
    .split(whereSeparator: { $0 == "," || $0 == " " })
    .map { $0.lowercased() }

// Defender for Cloud Apps proxies a site as <host>.mcas.ms; behind it, the
// host to check is the one being proxied. The scripts strip it the same way.
func unproxied(_ host: String) -> String {
    host.hasSuffix(".mcas.ms") ? String(host.dropLast(".mcas.ms".count)) : host
}

func fillAllowed(_ url: URL?) -> Bool {
    guard let url, let host = url.host?.lowercased(), fillHosts.contains(unproxied(host)) else { return false }
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
// the DOM rather than waiting for didFinish. It reports the name of the first
// empty field it can fill.
let watcherJS = """
(() => {
  if (window.__gpn) return;
  const names = __NAMES__;
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
    for (const n of names) { const el = pick(`input[name="${n}"]`); if (el && !el.value) return n; }
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

// Fills one field, and submits once no other fillable field on the page is
// empty. `kind` (the input's name), `value`, `names` and `hosts` arrive as
// arguments, never as source. Rechecks the host: the page may have moved on
// while `op` waited for Touch ID.
let fillJS = """
if (!window.__gpn || !hosts.includes(location.hostname.toLowerCase().replace(/\\.mcas\\.ms$/, ''))) return "host";
const el = window.__gpn.pick(`input[name="${CSS.escape(kind)}"]`);
if (!el || el.value) return "absent";
// Entra wants an email; a bare username would only earn an error, and an
// error ends autofill. Leave it to the person.
if (kind === "loginfmt" && !value.includes("@")) return "not an email";
el.focus();
// The prototype setter, then events, so knockout or React sees the value.
Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
for (const t of ["input", "change"]) el.dispatchEvent(new Event(t, { bubbles: true }));
if (window.__gpn.need()) return "filled";
await new Promise(r => setTimeout(r, 200));
const button = window.__gpn.pick("#idSubmit_SAOTCC_Continue") || window.__gpn.pick("#idSIButton9")
  || window.__gpn.pick("#loginButton2");
if (button) { button.click(); return "submitted"; }
if (el.form) { el.form.requestSubmit(); return "submitted"; }
return "filled";
"""

final class Filler: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    private let item: String
    private let bin: String
    private let autofill: Bool
    private var filled: Set<String> = []
    private var stopped = false
    private(set) var busy = false
    // The window stays hidden while a fill is under way: progress restarts
    // its reveal clock, and a hand-off shows it, since the person must take over.
    var onProgress: (() -> Void)?
    var onHandOff: (() -> Void)?

    /// Whether fields will be filled as they appear.
    var active: Bool { autofill && !stopped }

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
        let names = String(data: try! JSONSerialization.data(withJSONObject: fillNames), encoding: .utf8)!
        let source = watcherJS.replacingOccurrences(of: "__NAMES__", with: names)
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
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
        onHandOff?()
    }

    private func fill(_ kind: String) {
        guard let web, fillAllowed(web.url) else { return }
        guard let field = fillFields.first(where: { $0.key == kind })?.value else { return }
        busy = true
        filled.insert(kind)
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
        web.callAsyncJavaScript(fillJS, arguments: ["kind": kind, "value": value,
                                                    "names": fillNames, "hosts": fillHosts],
                                in: nil, in: .defaultClient) { [weak self] r in
            guard let self else { return }
            self.busy = false
            self.onProgress?()
            let outcome = (try? r.get()) as? String ?? ""
            note("1Password: \(kind) \(outcome)")
            // Not filled, but not refused either: the person types this one,
            // and autofill carries on for the fields after it. No rescan — it
            // would report this field again and read as a refusal.
            if outcome == "not an email" { self.onHandOff?(); return }
            // Anything that changed while busy was swallowed; look again.
            self.web?.callAsyncJavaScript("window.__gpn && window.__gpn.rescan()",
                                          arguments: [:], in: nil, in: .defaultClient)
        }
    }
}

final class Login: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var found: [String: String] = [:]
    private var done = false
    private var revealed = false
    private var revealAt = Date().addingTimeInterval(revealAfter)
    private var answered: Set<String> = []
    private var poll: Timer?
    private var lastHost = ""
    private let window: NSWindow
    private let web: WKWebView
    let filler: Filler?
    private var urlObservation: NSKeyValueObservation?

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
        window.initialFirstResponder = web
        // There is no address bar, so the title names the host being typed
        // into — the one check a person can make before entering a password.
        urlObservation = web.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
            guard let self else { return }
            let host = web.url?.host ?? ""
            self.window.title = host.isEmpty ? "VPN sign-in" : "VPN sign-in — \(host)"
        }
        filler?.onProgress = { [weak self] in
            self?.revealAt = Date().addingTimeInterval(revealAfter)
        }
        filler?.onHandOff = { [weak self] in self?.reveal("1Password fill stopped") }
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
        // Waiting on 1Password, which may be waiting on Touch ID: not a stall.
        if filler?.busy == true { revealAt = Date().addingTimeInterval(revealAfter) }
        if !revealed && Date() >= revealAt {
            reveal("no result after \(Int(revealAfter))s")
        }
        web.callAsyncJavaScript(pageStateJS, arguments: ["hosts": fillHosts],
                                in: nil, in: .defaultClient) { [weak self] r in
            guard let self, !self.done else { return }
            guard case .success(let result) = r else { return }
            let state = result as? String ?? ""
            if state.hasPrefix("input") {
                let fields = state.dropFirst("input:".count)
                self.reveal(fields.isEmpty ? "the page wants input"
                                           : "the page wants input: \(fields)")
                return
            }
            switch state {
            case "fillable" where self.filler?.active != true:
                self.reveal("the page wants input")
            case let kind where (kind == "kmsi" || kind == "pick") && !self.answered.contains(kind):
                // Once each per run, so a page that keeps coming back is left
                // to the person rather than clicked in a loop.
                self.answered.insert(kind)
                self.web.callAsyncJavaScript(answerJS, arguments: ["kind": kind, "hosts": fillHosts],
                                             in: nil, in: .defaultClient) { r in
                    guard case .success(let v) = r, (v as? Bool) == true else { return }
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
        // Which hosts the sign-in passes through — the first thing to know
        // when a provider adds a hop (a proxy, a federated login page). The
        // host only: paths and queries carry SAML state.
        if action.targetFrame?.isMainFrame == true, let host = action.request.url?.host,
           host != lastHost {
            lastHost = host
            note("page \(host)")
        }
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

// An AppKit app with no main menu has no key equivalents: Cmd-V, Cmd-C, Cmd-A
// and Cmd-Z are routed through the menu bar, so without one the web view never
// sees them and pasting a password copied from a password manager silently
// does nothing. Universal Autofill in 1Password (Cmd-\) is a global hotkey and
// fills through the Accessibility API, so it does not need this — but paste,
// the fallback for every password manager, does.
func installMainMenu(fill target: Filler?) {
    let bar = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide VPN sign-in", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit VPN sign-in", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    bar.addItem(appItem)

    // Targets are nil: each action goes down the responder chain to whatever
    // has focus, which inside the window is the web view's focused field.
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
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
    editItem.submenu = edit
    bar.addItem(editItem)

    let windowItem = NSMenuItem()
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = win
    bar.addItem(windowItem)

    NSApp.mainMenu = bar
    NSApp.windowsMenu = win
}

let app = NSApplication.shared
// No Dock icon and no activation until the window is needed; reveal()
// switches to .regular.
app.setActivationPolicy(.accessory)
let login = Login(url: url)
installMainMenu(fill: login.filler)
app.run()
