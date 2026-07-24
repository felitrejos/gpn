# Agent guide

Setup runbook for an AI agent. The user will say something like *"read
AGENTS.md and set up gpn for my VPN."*

The work is mostly discovery: the portal hostname, the exact username format,
whether a client certificate is involved, and how the portal wants the 2FA
code. If the official GlobalProtect client works on this machine, all of it is
already on disk.

## Rules

1. **Never print a password or one-time code** — not to the terminal, not to a
   file. To check a secret is readable, print its length, not its value.
2. **Never put a secret in the config.** The config references the password
   manager; it does not store secrets.
3. **Never commit a `.conf`.** Real profiles live in `~/.config/gpn/`.
   `.gitignore` blocks `*.conf` — leave that alone.
4. **Do not retry failed logins in a loop.** Institutional portals lock
   accounts. Two failures, then stop and report.
5. **One-time codes are single-use and roll every 30s.** Wait for a fresh one
   between attempts — a replayed code is rejected, which looks exactly like a
   wrong setting.
6. **Redact cookies** in anything you show. `authcookie`, `prelogin-cookie`
   and `*userauthcookie` values are live credentials.
7. **Ask first** before removing the official client, hand-editing sudoers, or
   deleting configuration profiles.

## 1. Dependencies

```bash
command -v openconnect op || brew install openconnect 1password-cli
op account list        # confirms 1Password CLI integration is enabled
```

Other credential backends are in `config.example` if the user does not use
1Password.

## 2. Read the official client's settings

```bash
plutil -convert xml1 -o - /Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist
plutil -convert xml1 -o - ~/Library/Preferences/com.paloaltonetworks.GlobalProtect.client.plist
```

| Config key | Comes from |
| --- | --- |
| `PORTAL` | `PanSetup` → `Portal` |
| `GP_VERSION` | `PanSetup` → `CurrentVersion` |
| `VPN_USER` | client plist → `User` |

If the client is not installed, ask the user for the portal and username.

`/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log` holds gateway names
and past assigned IPs, but only if the client connected recently. A log of
nothing but startup lines means it has been disabled and will tell you nothing.

## 3. Ask the portal how it authenticates

No credentials needed, and the most informative single check:

```bash
curl -s "https://PORTAL/global-protect/prelogin.esp?clientVer=4100&clientos=Mac"
```

- **`<saml-request>` present** → SAML. **Stop.** This tool does not handle it;
  point the user at [gp-saml-gui](https://github.com/dlenski/gp-saml-gui).
- **Absent** → plain username + password. Continue.
- **`<username-label>`** usually states the expected username format,
  sometimes in the local language.

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

## 5. Find the credentials

```bash
op item list --format=json | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    t = i.get('title','')
    if any(k in t.lower() for k in ['vpn','university','uni','work','portal']):
        print(i['id'], '|', t)
"
```

Confirm the right item with the user, then verify it has what is needed —
**lengths only, never values**:

```bash
P=$(op item get ITEM_ID --fields label=password --reveal 2>&1)
[ -n "$P" ] && echo "password: OK (${#P} chars)" || echo "password: FAILED"
O=$(op item get ITEM_ID --otp 2>&1)
[ -n "$O" ] && echo "otp: OK (${#O} digits)" || echo "otp: FAILED"
```

No OTP field may mean the portal has no second factor — set `OTP_MODE="none"`
and confirm with the user.

## 6. Write the config

```bash
mkdir -p ~/.config/gpn && chmod 700 ~/.config/gpn
cp config.example ~/.config/gpn/default.conf
chmod 600 ~/.config/gpn/default.conf
```

Fill in `PORTAL`, `VPN_USER`, `CREDENTIALS`, `OP_ITEM`, `GP_VERSION`. Leave
`OTP_MODE="challenge"` and `GATEWAY_MODE="1"`; step 7 confirms them.

The config is sourced by bash, so never drop unescaped user-pasted content
into it.

## 7. Verify the login

```bash
gpn test-auth
```

Runs the full login with `--cookieonly`: no root, no tunnel, cookies redacted.
Use it for every diagnostic step — never debug by raising a real tunnel.

| In the trace | Meaning | Action |
| --- | --- | --- |
| ends with `userauthcookie` | success | go to step 8 |
| `Challenge:` then a code prompt | code is its own prompt | `OTP_MODE="challenge"` ✓ |
| asked for password or code **twice** | portal and gateway both authenticate | `GATEWAY_MODE="1"` |
| rejected, credentials known good | code may need appending | `OTP_MODE="append"` |
| no code prompt | no second factor | `OTP_MODE="none"` |
| `fgets (stdin)` error | it wanted an answer we did not supply | usually `GATEWAY_MODE="1"` |

Portals print their own banners mid-login, sometimes alarming, sometimes in
another language. They are not errors — if the trace ends with a
`userauthcookie`, it worked. Change one setting at a time.

## 8. Install

```bash
./install.sh -t "Work VPN"
```

Explain the tradeoff before running it and let the user decide: openconnect
needs root for the tunnel, so the installer adds a passwordless sudo rule for
that one binary. Since openconnect can run a script as root (`--script`), that
rule is effectively root for anything already running as this user.
`--no-sudoers` skips it, but then every connect prompts for a password and the
Raycast commands will not work.

Then confirm it works:

```bash
gpn connect && gpn status
gpn disconnect
```

A good connect reports an IP. If not, `gpn logs 60`.

## 9. Raycast

`install.sh` writes the commands to `~/.config/gpn/raycast/`. Tell the
user to add that directory under **Raycast → Settings → Extensions → Script
Commands → Add Directory**, then give Toggle a hotkey.

## Repo map

| Path | What it is |
| --- | --- |
| `gpn` | the whole tool, one bash script |
| `config.example` | every config key, documented |
| `install.sh` | symlink, config skeleton, sudoers rule, Raycast generation; `--uninstall` reverses it |
| `raycast-templates/` | rendered per profile by `install.sh` |

Runtime state, none of it in the repo: `~/.config/gpn/<profile>.conf`,
`~/.config/gpn/raycast/`, `~/.local/state/gpn/` (pidfile, cached
IP), `~/Library/Logs/gpn-<profile>.log`.

## Easy things to get wrong

From building this against a live portal:

- **Portal vs gateway.** `/global-protect/` is the portal, `/ssl-vpn/` the
  gateway. Many deployments authenticate at both, asking for the password and
  a fresh code twice — and the second attempt fails, because a code cannot be
  replayed. `GATEWAY_MODE="1"` skips the portal, which is why it is the
  default.
- **The tunnel-up message differs by tunnel type.** A GlobalProtect ESP tunnel
  logs `Configured as <ip>`; a plain SSL one logs `Connected as <ip>`. Parse
  both.
- **Do not detect the tunnel by IP range.** Assigned ranges vary per
  institution. Read the address back from openconnect's own output.
- **openconnect reads each prompt with `fgets(stdin)`** when stdin is not a
  tty. That is why credentials are piped one line per prompt, and why an
  unexpected extra prompt surfaces as a `fgets (stdin)` error rather than a
  clear auth failure.
