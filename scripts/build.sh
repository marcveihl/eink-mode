#!/bin/bash
# Builds dist/E-Ink Mode.app and a shareable zip.
#   EINK_SIGN_IDENTITY="Developer ID Application: …"  sign for distribution (hardened runtime)
#   EINK_NOTARY_PROFILE=<notarytool keychain profile>  also notarize and staple
#   EINK_ARCHS="arm64"                                  build a single architecture (default: universal)
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
REPO="${EINK_REPO:-marcveihl/eink-mode}"
ARCHS="${EINK_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=(); for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build --disable-sandbox -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="$PWD/dist/E-Ink Mode.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/EinkBar" "$APP/Contents/MacOS/EinkBar"
cp "$BIN/eink" "$APP/Contents/MacOS/eink"
ICONSET="$PWD/.build/AppIcon.iconset"
rm -rf "$ICONSET"; swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>E-Ink Mode</string>
<key>CFBundleDisplayName</key><string>E-Ink Mode</string>
<key>CFBundleIdentifier</key><string>local.eink.mode</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleExecutable</key><string>EinkBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Beta build. MIT License.</string>
<key>EinkReleasesURL</key><string>https://api.github.com/repos/$REPO/releases?per_page=20</string>
</dict></plist>
PLIST

if [ -n "${EINK_SIGN_IDENTITY:-}" ]; then
  SIGN=(--force --options runtime --timestamp --sign "$EINK_SIGN_IDENTITY")
else
  SIGN=(--force --sign -)
  echo "note: ad-hoc signed. Set EINK_SIGN_IDENTITY to a Developer ID for Gatekeeper-friendly builds."
fi
codesign "${SIGN[@]}" "$APP/Contents/MacOS/eink"
codesign "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

ZIP="$PWD/dist/E-Ink-Mode-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${EINK_NOTARY_PROFILE:-}" ] && [ -n "${EINK_SIGN_IDENTITY:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$EINK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
fi
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cp scripts/install.sh dist/install.sh
echo "Built: $APP ($VERSION, build $BUILD, $(lipo -archs "$APP/Contents/MacOS/EinkBar"))"
echo "Archive: $ZIP"
