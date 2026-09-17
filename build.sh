#!/usr/bin/env bash
# Builds the einkctl helper and, unless --cli-only, the EinkBar.app menu bar app.
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O einkctl.swift -o einkctl
chmod +x eink einkctl
echo "built: $(pwd)/einkctl"

[ "${1:-}" = "--cli-only" ] && exit 0

APP="EinkBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O EinkBar.swift -o "$APP/Contents/MacOS/EinkBar"

# The script and helper ride inside the bundle so the app is self-contained and
# can be moved to /Applications without breaking its path to them.
cp eink einkctl "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/eink" "$APP/Contents/Resources/einkctl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>EinkBar</string>
  <key>CFBundleDisplayName</key>     <string>E-Ink Mode</string>
  <key>CFBundleIdentifier</key>      <string>local.eink.einkbar</string>
  <key>CFBundleVersion</key>         <string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>EinkBar</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: without it macOS may refuse to keep the status item alive.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc codesign skipped"

echo "built: $(pwd)/$APP"
