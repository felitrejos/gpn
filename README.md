# gpconnect

Raycast commands for connecting to a Palo Alto GlobalProtect VPN, with
1Password filling in the password and the 2FA code.

You get **Connect**, **Disconnect**, **Toggle**, and an inline **Status**.
Underneath it uses [openconnect](https://www.infradead.org/openconnect/)
instead of the official GlobalProtect client, which is what makes it fast.

1Password is the default. Any password manager with a CLI works too — `pass`,
the macOS keychain, `ykman`, `oathtool`.

## Requirements

- macOS with Raycast
- `brew install openconnect`
- `brew install 1password-cli`, with **1Password → Settings → Developer →
  Integrate with 1Password CLI** enabled

## Setup

Most of the effort is working out what your portal expects: the username
format, whether a client certificate is involved, and how it wants your
one-time code. All of it is discoverable from the official client if you have
it installed, but it is tedious to dig out by hand.

[AGENTS.md](AGENTS.md) is a runbook for exactly that. Point your agent at it —
Claude Code, Codex, Cursor, whichever you use:

> Read AGENTS.md and set up gpconnect for my VPN.

It reads the settings out of the installed client, checks your portal is
compatible, finds your 1Password entry, writes the config, and verifies the
login before installing anything.

If you would rather do it yourself, AGENTS.md reads fine as human
instructions. The short version:

```bash
git clone https://github.com/YOUR_USERNAME/gpconnect.git
cd gpconnect && ./install.sh -t "Work VPN"
$EDITOR ~/.config/gpconnect/default.conf
gpconnect test-auth
```

Then add `~/.config/gpconnect/raycast` under **Raycast → Settings → Extensions
→ Script Commands → Add Directory**, and give Toggle a hotkey.

## Configuration

One file per VPN in `~/.config/gpconnect/`. The minimum:

```bash
PORTAL="vpn.example.edu"
VPN_USER="jdoe"
CREDENTIALS="op"
OP_ITEM="your-1password-item-id"
```

Everything else has a working default — see [config.example](config.example)
for the full list.

A second VPN is a second profile, with its own config and its own Raycast
commands:

```bash
./install.sh -p work -t "Work VPN"
```

## Troubleshooting

`gpconnect test-auth` runs the login without root and without creating a
tunnel, then prints what happened with the cookies redacted. Start there.

| Symptom | Fix |
| --- | --- |
| Asked for the password or code twice | `GATEWAY_MODE="1"` (the default) |
| Login rejected, credentials are right | try `OTP_MODE="append"` |
| No code prompt at all | `OTP_MODE="none"` |
| "use the latest version" nag | set `GP_VERSION` to match the real client |
| Portal offers several gateways | `GATEWAY_MODE="0"` to let it choose |
| Fails after login succeeds | `gpconnect logs 60` |

Portals often print their own banner mid-login, sometimes an alarming one,
sometimes in another language. If `test-auth` ends with a `userauthcookie`, the
login worked — ignore the banner.

Note that one-time codes are single-use and roll every 30 seconds, so give it a
fresh window between attempts. A replayed code fails in a way that looks a lot
like a wrong setting.

## Security

- Secrets stay in your password manager. Nothing is written to disk, and
  nothing is passed as a command-line argument where `ps` would show it.
- Config files reference a password manager entry rather than holding a
  secret, and `*.conf` is gitignored.
- openconnect needs root to create the tunnel and set routes, so `install.sh`
  adds a passwordless sudo rule for that one binary. Worth knowing: openconnect
  can run a script as root (`--script`), so anything already able to run
  commands as you could use that rule to become root. `./install.sh
  --no-sudoers` skips it, at the cost of a password prompt on every connect.
