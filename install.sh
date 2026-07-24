#!/usr/bin/env bash
#
# gpn installer.
#
#   ./install.sh                 install for the "default" profile
#   ./install.sh -p work         install and generate Raycast commands for "work"
#   ./install.sh --no-sudoers    skip the passwordless-sudo rule
#   ./install.sh --uninstall     remove everything this script installed
#
# Installs: a symlink on your PATH, a config skeleton, a scoped sudoers rule,
# and per-profile Raycast script commands.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gpn"
RAYCAST_DIR="$CONFIG_DIR/raycast"
SUDOERS="/etc/sudoers.d/gpn"
USER_NAME="$(id -un)"

PROFILE="default"
TITLE=""
WANT_SUDOERS=1
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile) PROFILE="${2:?}"; shift 2 ;;
        -t|--title)   TITLE="${2:?}";   shift 2 ;;
        --no-sudoers) WANT_SUDOERS=0;   shift ;;
        --uninstall)  UNINSTALL=1;      shift ;;
        -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- pick a bin directory on PATH -------------------------------------------
pick_bindir() {
    local d
    for d in "$(brew --prefix 2>/dev/null)/bin" /usr/local/bin "$HOME/.local/bin"; do
        [[ "$d" == "/bin" ]] && continue
        [[ -d "$d" && -w "$d" ]] && { printf '%s' "$d"; return 0; }
    done
    mkdir -p "$HOME/.local/bin" && printf '%s' "$HOME/.local/bin"
}
BINDIR="$(pick_bindir)"

# --- uninstall ---------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
    say "Uninstalling gpn"
    rm -f "$BINDIR/gpn" && echo "  removed $BINDIR/gpn"
    rm -rf "$RAYCAST_DIR"     && echo "  removed $RAYCAST_DIR"
    if [[ -e "$SUDOERS" ]]; then
        sudo rm -f "$SUDOERS" && echo "  removed $SUDOERS"
    fi
    echo "  left $CONFIG_DIR alone (your profiles live there)"
    exit 0
fi

# --- dependencies ------------------------------------------------------------
command -v openconnect >/dev/null || {
    echo "openconnect not found. Install it first:" >&2
    echo "  brew install openconnect      # macOS" >&2
    echo "  apt install openconnect       # Debian/Ubuntu" >&2
    exit 1
}
OPENCONNECT="$(command -v openconnect)"
REAL_OC="$(readlink -f "$OPENCONNECT" 2>/dev/null || printf '%s' "$OPENCONNECT")"

chmod +x "$REPO/gpn"

# --- link --------------------------------------------------------------------
say "Linking $BINDIR/gpn -> $REPO/gpn"
ln -sf "$REPO/gpn" "$BINDIR/gpn"
case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) echo "  note: $BINDIR is not on your PATH — add it to your shell profile." ;;
esac

# --- config ------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/$PROFILE.conf"
if [[ -e "$CONFIG_FILE" ]]; then
    say "Config already exists: $CONFIG_FILE (left untouched)"
else
    cp "$REPO/config.example" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    say "Created $CONFIG_FILE — edit it before connecting."
fi

# --- sudoers -----------------------------------------------------------------
# openconnect needs root to create the tunnel device and change routes. Without
# this rule every connect prompts for a password, which a launcher cannot do.
if [[ $WANT_SUDOERS -eq 1 ]]; then
    say "Installing sudoers rule at $SUDOERS"
    echo "  Grants passwordless sudo for these only:"
    echo "    $OPENCONNECT"
    echo "    /bin/kill"
    echo "  Heads up: openconnect can run a script as root (--script), so this"
    echo "  is effectively root for anything that can already run commands as"
    echo "  you. Re-run with --no-sudoers to skip it."
    echo

    tmp="$(mktemp)"
    {
        echo "# gpn — start/stop the VPN without a password prompt."
        echo "$USER_NAME ALL=(root) NOPASSWD: $OPENCONNECT"
        [[ "$REAL_OC" != "$OPENCONNECT" ]] && echo "$USER_NAME ALL=(root) NOPASSWD: $REAL_OC"
        echo "$USER_NAME ALL=(root) NOPASSWD: /bin/kill"
        echo "$USER_NAME ALL=(root) NOPASSWD: /bin/rm -f /var/run/gpn-*.pid"
    } >"$tmp"

    # Never install a sudoers file that does not parse.
    if ! visudo -cqf "$tmp"; then
        echo "Generated sudoers file failed validation, aborting." >&2
        rm -f "$tmp"; exit 1
    fi
    sudo install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"
    rm -f "$tmp"
    sudo visudo -cqf "$SUDOERS" && echo "  installed and validated."
fi

# --- raycast -----------------------------------------------------------------
if [[ -d /Applications/Raycast.app ]]; then
    [[ -n "$TITLE" ]] || TITLE="VPN"
    mkdir -p "$RAYCAST_DIR"
    say "Generating Raycast commands in $RAYCAST_DIR"
    for t in "$REPO"/raycast-templates/*.tmpl; do
        base="${t##*/}"; base="${base%.tmpl}"
        out="$RAYCAST_DIR/gpn-$PROFILE-$base"
        sed -e "s|__TITLE__|$TITLE|g" \
            -e "s|__PROFILE__|$PROFILE|g" \
            -e "s|__BIN__|$BINDIR/gpn|g" \
            -e "s|__PATH__|$BINDIR:/usr/bin:/bin:/usr/sbin:/sbin|g" \
            "$t" >"$out"
        chmod +x "$out"
        echo "  $out"
    done
    echo
    echo "  Add it in Raycast: Settings -> Extensions -> Script Commands"
    echo "                     -> Add Directory -> $RAYCAST_DIR"
fi

say "Done."
cat <<EOF
Next:
  1. Edit  $CONFIG_FILE
  2. Check the auth flow (no root, no tunnel):
       gpn -p $PROFILE test-auth
  3. Connect:
       gpn -p $PROFILE connect
EOF
