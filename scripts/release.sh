#!/bin/bash
# Builds and publishes a GitHub release for the version in VERSION. See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
REPO="${EINK_REPO:-marcveihl/eink-mode}"
TAG="v$VERSION"
[ -n "${EINK_SIGN_IDENTITY:-}" ] && [ -n "${EINK_TEAM_ID:-}" ] && [ -n "${EINK_NOTARY_PROFILE:-}" ] || {
  echo "Release requires EINK_SIGN_IDENTITY, EINK_TEAM_ID, and EINK_NOTARY_PROFILE." >&2; exit 1;
}
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit your changes first." >&2; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "$TAG already exists. Bump VERSION." >&2; exit 1; }
./scripts/test.sh
EINK_DISTRIBUTION=1 ./scripts/build.sh
NOTES="$(mktemp)"; trap 'rm -f "$NOTES"' EXIT
awk -v v="## $VERSION" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<EOF

**Install or update:** \`curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash\`
EOF
git tag -a "$TAG" -m "E-Ink Mode $VERSION"
git push origin "$TAG"
gh release create "$TAG" --repo "$REPO" --title "E-Ink Mode $VERSION" --notes-file "$NOTES" \
  "dist/E-Ink-Mode-$VERSION.zip" "dist/E-Ink-Mode-$VERSION.zip.sha256" dist/install.sh
echo "Published https://github.com/$REPO/releases/tag/$TAG"
