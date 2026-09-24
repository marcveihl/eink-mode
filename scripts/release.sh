#!/bin/bash
# Builds and publishes a GitHub release for the version in VERSION. See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
REPO="${EINK_REPO:-marcveihl/eink-mode}"
TAG="v$VERSION"
if [ "${EINK_UNSIGNED_BETA:-0}" = 1 ]; then
  case "$VERSION" in *-beta.*) ;; *) echo "Unsigned distribution is limited to beta versions." >&2; exit 1;; esac
  [ -z "${EINK_SIGN_IDENTITY:-}${EINK_TEAM_ID:-}${EINK_NOTARY_PROFILE:-}" ] || {
    echo "Do not combine EINK_UNSIGNED_BETA with signing credentials." >&2; exit 1;
  }
else
  [ -n "${EINK_SIGN_IDENTITY:-}" ] && [ -n "${EINK_TEAM_ID:-}" ] && [ -n "${EINK_NOTARY_PROFILE:-}" ] || {
    echo "Release requires EINK_SIGN_IDENTITY, EINK_TEAM_ID, and EINK_NOTARY_PROFILE (or explicit EINK_UNSIGNED_BETA=1)." >&2; exit 1;
  }
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit your changes first." >&2; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "$TAG already exists. Bump VERSION." >&2; exit 1; }
./scripts/test.sh
EINK_DISTRIBUTION=1 ./scripts/build.sh
NOTES="$(mktemp)"; trap 'rm -f "$NOTES"' EXIT
awk -v v="## $VERSION" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md > "$NOTES"
if [ "${EINK_UNSIGNED_BETA:-0}" = 1 ]; then
  cat >> "$NOTES" <<'EOF'

**Unsigned beta:** this build has an ad hoc signature, not a Developer ID signature, and is not notarized. A browser download may require **System Settings → Privacy & Security → Open Anyway** after trying to launch it. The installer checks the exact archive SHA-256 and the app's signature integrity; this does not authenticate an Apple-verified publisher. Quarantine is preserved. Install future versions manually while signing is deferred; this beta's in-app installer requires a configured publisher identity.
EOF
fi
cat >> "$NOTES" <<EOF

**Install or update:** \`curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash\`
EOF
git tag -a "$TAG" -m "E-Ink Mode $VERSION"
git push origin "$TAG"
gh release create "$TAG" --repo "$REPO" --latest --title "E-Ink Mode $VERSION" --notes-file "$NOTES" \
  "dist/E-Ink-Mode-$VERSION.zip" "dist/E-Ink-Mode-$VERSION.zip.sha256" dist/install.sh
echo "Published https://github.com/$REPO/releases/tag/$TAG"
