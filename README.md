# gpconnect

Connect to a **Palo Alto GlobalProtect** VPN with [openconnect](https://www.infradead.org/openconnect/)
instead of the official client, with the password and 2FA code pulled from your
password manager — so connecting is one keystroke from Raycast rather than a
GUI, a typed password, and a copy-pasted code.

```bash
gpconnect connect      # or toggle / disconnect / status
```

Built because the GlobalProtect app is slow to start, slow to connect, and
insists on being clicked.

## Why this exists

openconnect has spoken the GlobalProtect protocol for years, but getting a
2FA-protected portal working from the command line is fiddly in ways that are
not obvious:

- The portal (`/global-protect/`) and the gateway (`/ssl-vpn/`) often
  authenticate **separately**. Connect through the portal and you get asked for
  your password and a one-time code *twice* — and a TOTP code cannot be
  replayed, so the second attempt fails. `gpconnect` talks to the gateway
  directly by default.
- The one-time code may be a **separate challenge prompt** or **appended to the
  password**, depending on deployment. openconnect reads each prompt with
  `fgets(stdin)`, so `gpconnect` feeds it one line per prompt.
- Some portals reject or nag at old-looking client versions, so the reported
  version string is configurable.

`gpconnect test-auth` exercises the whole handshake without root and without
creating a tunnel, so you can find the right combination in seconds instead of
guessing.

## Requirements

- `openconnect` (`brew install openconnect`)
- macOS for the Raycast integration; the CLI itself is portable
- A password manager with a CLI — 1Password, `pass`, macOS keychain, `ykman`,
  `oathtool`, or anything that prints a secret to stdout

## Install

```bash
git clone https://github.com/YOUR_USERNAME/gpconnect.git
cd gpconnect && ./install.sh
```

The installer symlinks `gpconnect` onto your PATH, writes a config skeleton to
`~/.config/gpconnect/default.conf`, installs a `visudo`-validated sudoers rule
so the tunnel can start without a password prompt, and generates Raycast script
commands. `./install.sh --uninstall` reverses all of it.

Then edit your config and check it:

```bash
$EDITOR ~/.config/gpconnect/default.conf
gpconnect test-auth
```

## Configuration

One file per profile, in `~/.config/gpconnect/`. The minimum:

```bash
PORTAL="vpn.example.edu"
VPN_USER="jdoe"
CREDENTIALS="op"
OP_ITEM="your-1password-item-id"
```

Everything else has a working default. See [config.example](config.example) for
the full list.

### Credential backends

| `CREDENTIALS` | Password from | Code from |
| --- | --- | --- |
| `op` | 1Password CLI | 1Password CLI (`--otp`) |
| `keychain` | macOS keychain | `OTP_CMD` |
| `cmd` | `PASSWORD_CMD` | `OTP_CMD` |
| `prompt` | you, interactively | you, interactively |

`cmd` covers everything else:

```bash
CREDENTIALS="cmd"
PASSWORD_CMD='pass show vpn/work'
OTP_CMD='pass otp vpn/work'
# or: OTP_CMD='ykman oath accounts code -s vpn'
# or: OTP_CMD='oathtool --totp -b "$(pass show vpn/totp-secret)"'
```

No secret is ever written to disk by `gpconnect`, stored in the repo, or passed
on a command line where it would show up in `ps`. Credentials go to openconnect
over a pipe and the variable is unset immediately after.

### Multiple VPNs

```bash
./install.sh -p work -t "Work VPN"
gpconnect -p work connect
gpconnect profiles
```

Each profile gets its own config, log, pidfile, and Raycast commands.

## Finding your own settings

If the official client is already working on this machine, it has everything
you need on disk.

**Portal and username (macOS):**

```bash
plutil -convert xml1 -o - /Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist | grep -A2 -E "Portal|CurrentVersion"
plutil -convert xml1 -o - ~/Library/Preferences/com.paloaltonetworks.GlobalProtect.client.plist | grep -A2 User
```

That gives you `PORTAL`, `VPN_USER`, and the client version to put in
`GP_VERSION`.

**How the portal wants to authenticate** — this endpoint needs no credentials:

```bash
curl -s "https://YOUR_PORTAL/global-protect/prelogin.esp?clientVer=4100&clientos=Mac"
```

In the response, a `<saml-request>` element means the portal uses SAML — this
tool will not help you, use [gp-saml-gui](https://github.com/dlenski/gp-saml-gui)
instead. No such element means plain username + password, which is what
`gpconnect` handles. The `<username-label>` often tells you the expected
username format.

**Do you need a client certificate?** Usually not. Check:

```bash
security find-identity -v
```

If the only identities listed are unrelated (Apple Development certs and the
like), there is no VPN client certificate and you need no extra flags.

Note that GlobalProtect caches a file called `ServerCert.pan` under
`~/Library/Application Support/PaloAltoNetworks/GlobalProtect/`. It is easy to
mistake for a client certificate, but it is the *portal's own server
certificate*, kept for pinning. Decode it and see:

```bash
openssl x509 -inform DER -noout -subject -issuer \
  -in ~/Library/Application\ Support/PaloAltoNetworks/GlobalProtect/ServerCert.pan
```

If its issuer chains to a publicly trusted CA, macOS already trusts it and you
need no `--cafile` or `--servercert` pin. Confirm with:

```bash
echo | openssl s_client -connect YOUR_PORTAL:443 -servername YOUR_PORTAL 2>&1 | grep "Verify return code"
```

The `Pan*.dat` files in that directory are encrypted caches of the portal
config and a saved auth cookie. You do not need them — openconnect fetches the
same config at login.

## Troubleshooting

Start with `gpconnect test-auth`; it prints openconnect's auth trace with
cookies redacted, and tells you which knob to turn.

| Symptom | Fix |
| --- | --- |
| Asked for password or code twice | `GATEWAY_MODE="1"` (the default) |
| Auth rejected, code looks right | Try `OTP_MODE="append"` |
| Portal has no 2FA | `OTP_MODE="none"` |
| "use the latest version" nag | Set `GP_VERSION` to match the real client |
| Portal fronts several gateways | `GATEWAY_MODE="0"` to let it choose |
| Connect fails after auth | `gpconnect logs 60` |

Portals often print their own banner text mid-handshake, sometimes an alarming
one in the local language. If `test-auth` ends with a `userauthcookie`, the
handshake worked regardless of what was printed along the way.

## How it works

```
gpconnect connect
  └─ read password + OTP from your password manager
  └─ pipe them, one line per prompt, to:
       sudo openconnect --protocol=gp --usergroup=gateway \
            --user=USER --passwd-on-stdin --background \
            --pid-file=/var/run/gpconnect-PROFILE.pid PORTAL
  └─ parse the assigned IP from openconnect's output
```

Disconnect sends `SIGINT`, so openconnect runs `vpnc-script` with
`reason=disconnect` and restores your original DNS and routes rather than
leaving them mangled.

## Security notes

- The sudoers rule grants passwordless `sudo` for the `openconnect` binary.
  Because openconnect can run an arbitrary script as root (`--script`), that is
  effectively root access for anything already able to run commands as you.
  This is the cost of a one-keystroke toggle. Install with `--no-sudoers` and
  run from a terminal if you would rather type your password each time.
- Config files are created `0600` in a `0700` directory, but the right place
  for secrets is your password manager — reference it, do not inline it.
- `test-auth` redacts auth cookies from its output.

## License

MIT
