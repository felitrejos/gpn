# gpn

Raycast commands for connecting to a Palo Alto GlobalProtect VPN, without the
official client.

You get **Connect**, **Disconnect**, **Toggle**, and an inline **Status**.
Underneath it uses [openconnect](https://www.infradead.org/openconnect/)
instead of the GlobalProtect app, which is what makes it fast.

For portals that authenticate through an identity provider — Microsoft Entra
ID, Okta, Shibboleth. One line tells you whether yours does:

```bash
curl -s "https://YOUR-PORTAL/global-protect/prelogin.esp?clientVer=4100&clientos=Mac" | grep -o saml-request
```

Anything printed means yes.

## Requirements

- macOS with Raycast
- `brew install openconnect`
- Xcode command line tools (`xcode-select --install`), to build the sign-in
  window

## Setup

Most of the effort is working out what your portal expects: which endpoint to
authenticate against, which client version it will accept, whether a client
certificate is involved. All of it is discoverable, but tedious by hand.

[AGENTS.md](AGENTS.md) is a runbook for exactly that. Point your agent at it —
Claude Code, Codex, Cursor, whichever you use:

> Read AGENTS.md and set up gpn for my VPN.

It reads the settings out of the installed client, asks the portal how it
authenticates, writes the config, and verifies the sign-in before installing
anything.

If you would rather do it yourself, AGENTS.md reads fine as human instructions.
The short version:

```bash
git clone https://github.com/felitrejos/gpn.git
cd gpn && ./install.sh -t "Work VPN"
$EDITOR ~/.config/gpn/default.conf
gpn test-auth
```

Then add `~/.config/gpn/raycast` under **Raycast → Settings → Extensions
→ Script Commands → Add Directory**, and give Toggle a hotkey.

## Configuration

One file per VPN in `~/.config/gpn/`. The minimum is the hostname:

```bash
PORTAL="vpn.example.edu"
```

Your username is not configured — the identity provider decides it, and the
sign-in reports which name the gateway expects. Everything else has a working
default; see [config.example](config.example) for the full list.

A second VPN is a second profile, with its own config and its own Raycast
commands:

```bash
./install.sh -p work -t "Work VPN"
```

## How the sign-in works

A GlobalProtect portal does not end authentication with a tidy redirect. It
returns your username and a short-lived cookie in one of three ways, and which
one depends on how the portal is configured:

1. HTTP response headers on the final page.
2. The same fields as an XML fragment inside an HTML comment in that page's
   body — the page that renders as a bare "authentication successful".
3. A redirect to `globalprotectcallback:`, wrapping the same fields.

Only the third can escape a browser, and most portals do not use it. So the
sign-in runs in `GPNSamlLogin.app` — a window `install.sh` builds from about
170 lines of Swift in [saml-handler/](saml-handler/) — which can read its own
responses. It accepts all three, hands the result to `gpn` through a FIFO, and
closes itself. The cookie then goes to openconnect on stdin.

The window keeps its own cookie jar, so your identity-provider session carries
across connects. After the first sign-in most connects need no typing at all:
the window opens, the provider recognises the session, and it closes again.

## Troubleshooting

`gpn test-auth` runs the whole sign-in and hands the cookie to the gateway,
without root and without creating a tunnel, then prints what happened with the
cookies redacted. Start there.

| Symptom | Fix |
| --- | --- |
| Sign-in works, gateway refuses the cookie | try `GATEWAY_MODE="0"` |
| Refused whichever way round | your provider may require a managed device, which blocks every client but the official one |
| Window opens blank or never loads | check the portal hostname, and that you are not already on a network that blocks it |
| "use the latest version" nag | set `GP_VERSION` to match the real client |
| Portal offers several gateways | `GATEWAY_MODE="0"` to let it choose |
| Fails after the sign-in succeeds | `gpn logs 60` |

Portals often print their own banner mid-login, sometimes an alarming one,
sometimes in another language. If `test-auth` ends with a `userauthcookie`, it
worked — ignore the banner.

## Security

- The cookie is a live credential and is treated as one: it goes from the
  sign-in window to `gpn` through a FIFO, which holds it in kernel memory
  rather than on disk, and it is never logged or passed as an argument where
  `ps` would show it. `test-auth` redacts cookies from the trace it prints.
- Config files hold no secrets, and `*.conf` is gitignored.
- openconnect needs root to create the tunnel and set routes, so `install.sh`
  adds a passwordless sudo rule for that one binary. Worth knowing: openconnect
  can run a script as root (`--script`), so anything already able to run
  commands as you could use that rule to become root. `./install.sh
  --no-sudoers` skips it, at the cost of a password prompt on every connect.
