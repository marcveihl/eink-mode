#!/bin/bash
# Installs or updates E-Ink Mode.
#   curl -fsSL https://github.com/marcveihl/eink-mode/releases/latest/download/install.sh | bash
#   bash install.sh path/to/E-Ink-Mode-x.y.z.zip      (install a zip you already downloaded)
set -euo pipefail
REPO="${EINK_REPO:-marcveihl/eink-mode}"
APP_NAME="E-Ink Mode.app"
EXPECTED_TEAM_ID="__EINK_TEAM_ID__"
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "E-Ink Mode runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || fail "E-Ink Mode needs macOS 13 Ventura or newer."
[ "${#EXPECTED_TEAM_ID}" -eq 10 ] && [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "This installer has no pinned publisher identity. Download a signed release installer."

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
if [ $# -ge 1 ] && [ -f "$1" ]; then
  zip="$1"
else
  say "Finding the latest release…"
  curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases?per_page=20" -o "$work/releases.json" \
    || fail "Couldn't reach GitHub. Check your internet connection and try again."
  url=""
  for r in $(seq 0 19); do
    plutil -extract "$r" raw -o - "$work/releases.json" >/dev/null 2>&1 || break
    [ "$(plutil -extract "$r.draft" raw -o - "$work/releases.json")" = "false" ] || continue
    for a in $(seq 0 19); do
      name="$(plutil -extract "$r.assets.$a.name" raw -o - "$work/releases.json" 2>/dev/null)" || break
      case "$name" in *.zip) url="$(plutil -extract "$r.assets.$a.browser_download_url" raw -o - "$work/releases.json")"; break 2;; esac
    done
  done
  [ -n "$url" ] || fail "No downloadable release found."
  say "Downloading $(basename "$url")…"
  zip="$work/app.zip"
  curl -fL --progress-bar "$url" -o "$zip" || fail "Download failed."
fi

ditto -x -k "$zip" "$work/unpacked" || fail "The download is damaged. Try again."
[ -d "$work/unpacked/$APP_NAME" ] || fail "The archive doesn't contain $APP_NAME."
candidate="$work/unpacked/$APP_NAME"
identifier="$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null)" || fail "The app has no bundle identity."
[ "$identifier" = local.eink.mode ] || fail "The archive contains a different app."
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\" and identifier \"local.eink.mode\""
codesign --verify --deep --strict "$candidate" || fail "The app's signature is invalid; not installing."
codesign --verify --strict -R="$requirement" "$candidate" || fail "The app is not signed by the expected publisher; not installing."
spctl --assess --type execute "$candidate" || fail "macOS did not accept the app for opening; not installing."
version="$(plutil -extract CFBundleShortVersionString raw -o - "$candidate/Contents/Info.plist" 2>/dev/null)" || fail "The app has no version."
[ -n "$version" ] || fail "The app has no version."

# Quit a running copy. It restores the display before exiting. (EINK_NO_LAUNCH=1 is for tests.)
pids=""; [ "${EINK_NO_LAUNCH:-}" = 1 ] || pids="$(pgrep -f "/$APP_NAME/Contents/MacOS/EinkBar" || true)"
if [ -n "$pids" ]; then
  say "Quitting the running copy (your display will be restored)…"
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -f "/$APP_NAME/Contents/MacOS/EinkBar" >/dev/null || break; sleep 0.2; done
  pgrep -f "/$APP_NAME/Contents/MacOS/EinkBar" >/dev/null && fail "E-Ink Mode is still running. Choose Quit and Restore Display from its menu, then run this again."
fi

dest="${EINK_INSTALL_DIR:-/Applications}"
if [ ! -w "$dest" ]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
current_info="$dest/$APP_NAME/Contents/Info.plist"
if [ -f "$current_info" ]; then
  current_build="$(plutil -extract CFBundleVersion raw -o - "$current_info" 2>/dev/null || true)"
  candidate_build="$(plutil -extract CFBundleVersion raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$current_build" =~ ^[0-9]+$ && "$candidate_build" =~ ^[0-9]+$ ]] && [ "$candidate_build" -le "$current_build" ]; then
    fail "The downloaded app is not newer than the installed copy."
  fi
fi
say "Installing E-Ink Mode $version into ${dest}…"
backup="$dest/.E-Ink Mode.previous.$$"
if [ -e "$dest/$APP_NAME" ]; then mv "$dest/$APP_NAME" "$backup" || fail "Could not move the old app aside."; fi
if ! mv "$candidate" "$dest/$APP_NAME"; then
  [ ! -e "$backup" ] || mv "$backup" "$dest/$APP_NAME"
  fail "Could not install the app; the previous copy was restored."
fi
if [ -e "$backup" ]; then rm -rf "$backup"; fi
[ "${EINK_NO_LAUNCH:-}" = 1 ] || open "$dest/$APP_NAME"
say "Done. Look for the ○ icon in your menu bar (top-right of the screen)."
