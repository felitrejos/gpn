# Agent guide

Setup runbook for an AI agent. The user will say something like *"read
AGENTS.md and set up gpn for my VPN."*

gpn handles GlobalProtect portals that authenticate through an identity
provider. The work is mostly discovery: the portal hostname, confirming it
really does use SAML, which client version it will accept, and whether a client
certificate is involved. If the official GlobalProtect client works on this
machine, much of it is already on disk.

## Rules

1. **Never print a cookie or any other credential** — not to the terminal, not
   to a file. To check one is present, print its length, not its value.
2. **Never put a secret in the config.** A profile holds a hostname and a few
   flags; nothing sensitive belongs in it.
3. **Never commit a `.conf`.** Real profiles live in `~/.config/gpn/`.
   `.gitignore` blocks `*.conf` — leave that alone.
4. **Do not retry failed logins in a loop.** Institutional identity providers
   lock accounts, and repeated automated attempts are what risk-based policies
   are watching for. Two failures, then stop and report.
5. **Redact cookies** in anything you show. `authcookie`, `prelogin-cookie`
   and `*userauthcookie` values are live credentials.
6. **Ask first** before removing the official client, hand-editing sudoers, or
   deleting configuration profiles.
7. **The sign-in is the user's to perform.** Open the window and let them do
   it. Never script credential entry into an identity provider: the markup
   changes without notice, MFA blocks it anyway, and it trips exactly the
   policies rule 4 is about.

## 1. Dependencies

```bash
command -v openconnect swiftc || brew install openconnect
xcode-select -p   # swiftc comes from the command line tools
```

`swiftc` is not optional — it builds the sign-in window, which is the only way
gpn authenticates.

## 2. Read the official client's settings

```bash
plutil -convert xml1 -o - /Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist
```

| Config key | Comes from |
| --- | --- |
| `PORTAL` | `PanSetup` → `Portal` |
| `GP_VERSION` | `PanSetup` → `CurrentVersion` |

There is no username to read: the identity provider decides it, and the
sign-in reports the name the gateway expects. If the client is not installed,
ask the user for the portal hostname.

`/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log` holds gateway names
and past assigned IPs, but only if the client connected recently. A log of
nothing but startup lines means it has been disabled and will tell you nothing.

## 3. Confirm the portal uses SAML

No credentials needed, and the most informative single check:

```bash
curl -s "https://PORTAL/global-protect/prelogin.esp?clientVer=4100&clientos=Mac"
```

- **`<saml-request>` present** → good, continue. The value is a base64-encoded
  URL; decode it to see which identity provider you are dealing with.
- **Absent** → this portal wants a plain username and password. gpn does not
  support that; say so rather than improvising.
- **`<username-label>`** hints at the expected identity, sometimes in the local
  language. Worth reading: if it changed from a bare name to an email, the
  portal migrated and any old config is stale.

Ignore `<saml-default-browser>`. It advertises an agent preference, not what
the portal's ACS actually returns, and it is `yes` on portals that never emit a
`globalprotectcallback:` redirect. Never plan around it — see the last section.

## 4. Check for a client certificate

```bash
security find-identity -v
```

An identity is a certificate *with a private key*. If everything listed is
unrelated (Apple Development certs and so on), there is no VPN client
certificate and no extra flags are needed.

The trap: GlobalProtect caches `ServerCert.pan`, which looks like a client
cert but is not.

```bash
openssl x509 -inform DER -noout -subject -issuer \
  -in ~/Library/Application\ Support/PaloAltoNetworks/GlobalProtect/ServerCert.pan
```

If the subject `CN` is the portal's own hostname, it is the portal's *server*
certificate, kept for pinning — nothing to replicate. Confirm the system
already trusts it:

```bash
echo | openssl s_client -connect PORTAL:443 -servername PORTAL 2>&1 | grep "Verify return code"
```

`0 (ok)` means no `--cafile` or `--servercert` pin is needed. The neighbouring
`Pan*.dat` files are encrypted config caches — ignore them, openconnect fetches
the same config at login.

## 5. Write the config

```bash
mkdir -p ~/.config/gpn && chmod 700 ~/.config/gpn
cp config.example ~/.config/gpn/default.conf
chmod 600 ~/.config/gpn/default.conf
```

Fill in `PORTAL` and `GP_VERSION`. Leave `GATEWAY_MODE="1"`; step 7 confirms
it. There is no username to set.

The config is sourced by bash, so never drop unescaped user-pasted content
into it.

## 6. Install

```bash
./install.sh -t "Work VPN"
```

This builds `GPNSamlLogin.app` into `~/Applications`, so it has to happen
before step 7 — there is no sign-in without it.

Explain the tradeoff before running it and let the user decide: openconnect
needs root for the tunnel, so the installer adds a passwordless sudo rule for
that one binary. Since openconnect can run a script as root (`--script`), that
rule is effectively root for anything already running as this user.
`--no-sudoers` skips it, but then every connect prompts for a password and the
Raycast commands will not work.

## 7. Verify the sign-in

```bash
gpn test-auth
```

Runs the whole sign-in and spends the cookie at the gateway with
`--cookieonly`: no root, no tunnel, cookies redacted. Use it for every
diagnostic step — never debug by raising a real tunnel.

It opens a window, so the user has to be at the keyboard. Expect: window
appears, they sign in, window closes itself, trace ends with a cookie.

| In the trace | Meaning | Action |
| --- | --- | --- |
| ends with `userauthcookie` | success | go to step 8 |
| window closed with nothing returned | cancelled, or the portal returned neither headers nor a comment | re-run; if it repeats, dump the final page and look for where the fields are |
| cookie arrives, gateway refuses it | wrong endpoint for this cookie | `GATEWAY_MODE="0"` |
| refused either way round | provider may demand a managed device | nothing to fix; report it |

Portals print their own banners mid-login, sometimes alarming, sometimes in
another language. They are not errors — if the trace ends with a
`userauthcookie`, it worked. Change one setting at a time.

Then confirm the tunnel:

```bash
gpn connect && gpn status
gpn disconnect
```

A good connect reports an IP. If not, `gpn logs 60`.

## 8. Raycast

`install.sh` writes the commands to `~/.config/gpn/raycast/`. Tell the
user to add that directory under **Raycast → Settings → Extensions → Script
Commands → Add Directory**, then give Toggle a hotkey.

## Repo map

| Path | What it is |
| --- | --- |
| `gpn` | the whole tool, one bash script |
| `config.example` | every config key, documented |
| `install.sh` | symlink, config skeleton, sudoers rule, sign-in window, Raycast generation; `--uninstall` reverses it |
| `saml-handler/` | Swift source and build script for the sign-in window |
| `raycast-templates/` | rendered per profile by `install.sh` |

Runtime state, none of it in the repo: `~/.config/gpn/<profile>.conf`,
`~/.config/gpn/raycast/`, `~/.local/state/gpn/` (pidfile, cached IP, the
transient sign-in FIFO), `~/Library/Logs/gpn-<profile>.log`, and
`~/Applications/GPNSamlLogin.app`.

## Easy things to get wrong

From building this against a live portal:

- **The portal does not hand back a callback URL.** It returns the username and
  cookie in the HTTP response headers of the final page, or as an XML fragment
  in an HTML comment in that page's body. A `globalprotectcallback:` redirect
  is a third possibility that most portals never use — and `saml-default-browser:
  yes` in prelogin does **not** mean they will. Building around the callback
  costs a day and ends with a browser tab reading "authentication successful"
  while nothing is listening.
- **Which means the sign-in cannot happen in the user's own browser.** Nothing
  outside a browser can read those response headers. That is the entire reason
  the sign-in window exists, rather than shelling out to `open`.
- **openconnect cannot do GlobalProtect SAML by itself.** It prints the
  provider URL and gives up with `Failed to parse XML server response`. Its
  `--external-browser` flag looks like the answer and is not — that is
  AnyConnect's single-sign-on-external-browser method, a different protocol.
- **gp-saml-gui is not an option on macOS.** It imports WebKit2Gtk at module
  scope, and Homebrew's `webkitgtk` has no bottle and pulls `systemd`,
  `libcap`, `wayland` and `libdrm` — a Linux-only formula. Do not start that
  build; it cannot finish.
- **Both prelogin endpoints offer SAML,** but they yield different cookies:
  `/ssl-vpn/` returns `prelogin-cookie` (spend it with
  `--usergroup=gateway:prelogin-cookie`), `/global-protect/` returns
  `portal-userauthcookie` (`--usergroup=portal:portal-userauthcookie`).
  `GATEWAY_MODE` picks the endpoint; the window reports which cookie came back.
- **Open the FIFO read-write before launching the window.** Opening it
  read-only blocks until a writer appears, and a result that lands before the
  read is then buffered rather than lost.
- **The tunnel-up message differs by tunnel type.** A GlobalProtect ESP tunnel
  logs `Configured as <ip>`; a plain SSL one logs `Connected as <ip>`. Parse
  both.
- **Do not detect the tunnel by IP range.** Assigned ranges vary per
  institution. Read the address back from openconnect's own output.
- **openconnect reads each prompt with `fgets(stdin)`** when stdin is not a
  tty, which is why the cookie is piped as a single line.
- **Always brace a `$VAR` that touches a non-ASCII character** — `${PORTAL}…`,
  never `$PORTAL…`. macOS ships bash 3.2, which in a UTF-8 locale folds the
  lead byte of the ellipsis into the identifier and looks up `PORTAL\xe2`;
  `set -u` then aborts the moment that line runs. It parses clean, so
  `bash -n` will not warn you, and it only fires when `LANG` is a UTF-8 locale
  — so it can sit unnoticed for months and then appear to be a VPN problem.
  This file is full of `…` and `—`; `install.sh` refuses to install a `gpn`
  that has one, because it has been written twice already.
