# Agent guide

This file is for an AI coding agent (Claude Code, Cursor, Codex, Copilot,
Aider, whatever you use). Point your agent at this repo and it can do the whole
setup for you.

**Ask your agent:** *"Read AGENTS.md and set up gpconnect for my VPN."*

The hard part of this tool is not running it — it is **discovery**: finding the
portal hostname, the exact username format, whether a client certificate is
involved, and how the portal wants your 2FA code. All of that is sitting on the
machine already if the official GlobalProtect client works there. This guide is
the procedure for digging it out.

---

## Rules

Follow these. They matter more than finishing quickly.

1. **Never print a password or a one-time code.** Not to the terminal, not into
   a file, not into your own reasoning output. When verifying a secret is
   readable, print its length or a success/failure, never its value.
2. **Never write a secret into the config file.** The config stores a
   *reference* to the password manager, never the secret itself.
3. **Never commit a `.conf` file.** Real profiles live in
   `~/.config/gpconnect/`, outside the repo. `.gitignore` already blocks
   `*.conf`; do not weaken it.
4. **Do not retry failed authentication in a loop.** Institutional portals lock
   accounts. If auth fails twice, stop and report what you saw.
5. **TOTP codes are single-use and roll every 30s.** Between auth attempts,
   wait for a new code. Reusing one causes a *rejection*, which is easy to
   misread as "wrong config".
6. **Redact cookies** from anything you show the user. `authcookie`,
   `prelogin-cookie`, and `*userauthcookie` values are live credentials.
7. **Ask before destructive steps** — removing the official client, editing
   sudoers by hand, deleting configuration profiles.

---

## Step 1 — Dependencies

```bash
command -v openconnect op || brew install openconnect 1password-cli
```

`op` is only needed if the user keeps credentials in 1Password. Other backends
are listed in `config.example`.

If 1Password is used, its CLI integration must be on:
**1Password → Settings → Developer → Integrate with 1Password CLI.** Verify:

```bash
op account list
```

## Step 2 — Read the settings out of the official client

If GlobalProtect is installed on this Mac, it already knows everything.

```bash
plutil -convert xml1 -o - /Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist
plutil -convert xml1 -o - ~/Library/Preferences/com.paloaltonetworks.GlobalProtect.client.plist
```

Extract:

| You want | Look for |
| --- | --- |
| `PORTAL` | `PanSetup` → `Portal` |
| `GP_VERSION` | `PanSetup` → `CurrentVersion` |
| `VPN_USER` | client plist → `User`, or `PanPortalList` for the portal |

If the client is not installed, ask the user for the portal hostname and
username, and skip to Step 3.

Worth also checking, for context:

```bash
ls -la ~/Library/Application\ Support/PaloAltoNetworks/GlobalProtect/
tail -50 /Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log
```

The log holds gateway names and assigned IPs from past sessions — but only if
the client actually connected recently. A log full of startup lines and nothing
else means the client has been disabled, and it will tell you nothing useful.

## Step 3 — Ask the portal how it authenticates

This endpoint needs no credentials and is the single most informative check:

```bash
curl -s "https://PORTAL/global-protect/prelogin.esp?clientVer=4100&clientos=Mac"
```

Read the response:

- **`<saml-request>` present** → the portal uses SAML. **Stop.** gpconnect does
  not handle SAML. Tell the user to use
  [gp-saml-gui](https://github.com/dlenski/gp-saml-gui) instead.
- **No `<saml-request>`** → plain username + password. Proceed.
- **`<username-label>`** often states the expected format, sometimes in the
  local language. If it says something like "without @domain", the username is
  bare — match what the client plist stored.

## Step 4 — Is a client certificate involved?

Usually not, but check rather than assume:

```bash
security find-identity -v
```

An identity is a certificate *with a private key*. If everything listed is
unrelated (Apple Development certs and the like), there is no VPN client
certificate and no extra openconnect flags are needed.

**The common trap:** GlobalProtect caches a file called `ServerCert.pan`:

```bash
openssl x509 -inform DER -noout -subject -issuer -dates \
  -in ~/Library/Application\ Support/PaloAltoNetworks/GlobalProtect/ServerCert.pan
```

If the subject `CN` is the portal's own hostname, this is the **portal's server
certificate** kept for pinning — not a client identity. It is not something to
replicate. Confirm the system already trusts that chain:

```bash
echo | openssl s_client -connect PORTAL:443 -servername PORTAL 2>&1 | grep "Verify return code"
```

`0 (ok)` means no `--cafile` and no `--servercert` pin are needed.

The sibling `Pan*.dat` files are encrypted caches of the portal config and a
saved auth cookie. Ignore them — openconnect fetches the same config at login.

## Step 5 — Locate the credentials

For 1Password, find the item without revealing anything:

```bash
op item list --format=json | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    t = i.get('title','')
    if any(k in t.lower() for k in ['vpn','university','uni','work','portal']):
        print(i['id'], '|', t)
"
```

Ask the user to confirm which item is right. Then verify it has what is needed
— **printing only lengths, never values**:

```bash
P=$(op item get ITEM_ID --fields label=password --reveal 2>&1)
[ -n "$P" ] && echo "password: OK (${#P} chars)" || echo "password: FAILED"
O=$(op item get ITEM_ID --otp 2>&1)
[ -n "$O" ] && echo "otp: OK (${#O} digits)" || echo "otp: FAILED"
```

If the item has no OTP field, the portal may have no second factor — set
`OTP_MODE="none"` and confirm with the user.

## Step 6 — Write the config

```bash
mkdir -p ~/.config/gpconnect && chmod 700 ~/.config/gpconnect
cp config.example ~/.config/gpconnect/default.conf
chmod 600 ~/.config/gpconnect/default.conf
```

Fill in `PORTAL`, `VPN_USER`, `CREDENTIALS`, `OP_ITEM`, `GP_VERSION`. Leave
`OTP_MODE="challenge"` and `GATEWAY_MODE="1"` — Step 7 confirms or corrects
them.

Note the config is *sourced by bash*. Never place untrusted or user-pasted
content in it unescaped.

## Step 7 — Verify the handshake

```bash
gpconnect test-auth
```

This runs the full authentication with `--cookieonly`: **no root, no tunnel**,
and cookies redacted. It is the safe way to iterate.

Read the trace it prints:

| What you see | What it means | Do |
| --- | --- | --- |
| `...userauthcookie=<redacted>` at the end | Success | Go to Step 8 |
| `Challenge:` followed by a TOTP prompt | Code is a separate prompt | `OTP_MODE="challenge"` ✓ |
| Asked for password or a code **twice** | Portal and gateway auth separately | `GATEWAY_MODE="1"` |
| Auth rejected, credentials known good | Code may need gluing on | try `OTP_MODE="append"` |
| No OTP prompt at all | No second factor | `OTP_MODE="none"` |
| `fgets (stdin)` error | openconnect wanted another answer than we supplied | usually `GATEWAY_MODE="1"` |

**Portals print their own banner text mid-handshake**, sometimes an alarming
one, sometimes in the local language ("connection timed out", "check your
network"). These are canned messages, **not errors**. If the trace ends with a
`userauthcookie`, the handshake succeeded regardless of what was printed along
the way. Do not chase these messages.

Change one variable at a time, and wait for a fresh TOTP window between runs.

## Step 8 — Install

```bash
./install.sh -t "My VPN"
```

Explain the sudoers tradeoff to the user before running it, and let them
decide: openconnect needs root for the tunnel device and routes, so the
installer adds a passwordless-sudo rule for that one binary. Because
openconnect can run a script as root (`--script`), that rule is effectively
root for anything that can already run commands as this user. `--no-sudoers`
skips it, at the cost of a password prompt on every connect — which means the
Raycast commands will not work.

Then:

```bash
gpconnect connect && gpconnect status
gpconnect disconnect
```

A good connect reports an IP. `gpconnect logs 60` shows openconnect's full
output if it does not.

## Step 9 — Raycast

`install.sh` generates the script commands into `~/.config/gpconnect/raycast/`.
Tell the user to add that directory in
**Raycast → Settings → Extensions → Script Commands → Add Directory**, then
assign a hotkey or alias to *Toggle*.

---

## Repo map

| Path | What it is |
| --- | --- |
| `gpconnect` | The CLI. Single bash script, no dependencies beyond openconnect. |
| `config.example` | Every supported config key, documented. |
| `install.sh` | Symlink, config skeleton, sudoers rule, Raycast generation. `--uninstall` reverses it. |
| `raycast-templates/` | Templates rendered per profile by `install.sh`. |

State at runtime, none of it in the repo:

- `~/.config/gpconnect/<profile>.conf` — profiles
- `~/.config/gpconnect/raycast/` — generated Raycast commands
- `~/.local/state/gpconnect/` — pidfile, cached assigned IP
- `~/Library/Logs/gpconnect-<profile>.log` — openconnect output

## Things that are easy to get wrong

Collected from actually building this against a live portal:

- **Portal vs gateway.** `/global-protect/` is the portal, `/ssl-vpn/` is the
  gateway. Many deployments authenticate at *both*, which asks for the password
  and a fresh TOTP code twice — and the second one fails, because a code cannot
  be replayed. `GATEWAY_MODE="1"` (`--usergroup=gateway`) skips the portal.
  This is the default for a reason.
- **openconnect's tunnel-up message differs by tunnel type.** A GlobalProtect
  ESP tunnel logs `Configured as <ip>`; a plain SSL one logs `Connected as
  <ip>`. Parse both.
- **Do not detect the tunnel by IP range.** Assigned ranges vary per
  institution. Read the address back from openconnect's own output.
- **openconnect reads each auth prompt with `fgets(stdin)`** when stdin is not
  a tty. That is why credentials are piped one line per prompt, and why an
  unexpected extra prompt produces a `fgets (stdin)` error rather than a clear
  auth failure.
- **`--cookieonly` needs no root.** Use it for every diagnostic step. Never
  debug an auth problem by repeatedly bringing up a real tunnel.
