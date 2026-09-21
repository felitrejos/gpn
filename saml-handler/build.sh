#!/usr/bin/env bash
#
# Assemble GPNSamlLogin.app — the window that performs the SAML login and
# reads the result out of the portal's response. Needs the Xcode command line
# tools for swiftc; nothing else.
#
# Usage: build.sh [DESTINATION_DIR]   (default: ~/Applications)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/Applications}"
APP="$DEST/GPNSamlLogin.app"
BUNDLE_ID="io.github.gpn.samllogin"

command -v swiftc >/dev/null 2>&1 || {
    echo "swiftc not found — install the Xcode command line tools: xcode-select --install" >&2
    exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/GPNSamlLogin" "$SRC_DIR/GPNSamlLogin.swift"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>VPN sign-in</string>
  <key>CFBundleExecutable</key><string>GPNSamlLogin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature. A stable identity keeps the WebKit data store — and so the
# saved identity-provider session — attached to this app across rebuilds.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
