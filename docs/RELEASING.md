# Releasing

1. Bump [`VERSION`](../VERSION) (for example `0.9.0-beta.2`) and add a [CHANGELOG](../CHANGELOG.md) entry.
2. `./scripts/test.sh`, then run the real-Mac checks in [QA.md](QA.md).
3. `./scripts/release.sh`. It builds, then creates a GitHub release `v<VERSION>` with the zip, checksum, and `install.sh`, using the changelog section as notes.

## Requirements for classmates

- **The repository (or at least its releases) must be public.** The installer and in-app update check read `api.github.com/repos/<repo>/releases` without signing in, and a private repo returns 404. Alternatively, set `EINK_REPO=<owner>/<public-repo>` when building and releasing to publish from a separate public repo.
- **Publish as a normal release, not a pre-release.** `releases/latest/download/install.sh` only follows the latest non-pre-release. The version string already says *beta*, and the in-app updater compares versions properly.

## Windows releases

Windows has its own, earlier-stage beta track, kept deliberately invisible to the Mac app's own update check: `Updates.swift` picks a release's `archive` by the first asset ending in `.zip` and parses its version from `tag_name` via `AppVersion`, so a differently-shaped tag with a non-`.zip` asset simply never matches.

1. Bump the version in [`windows/eink.iss`](../windows/installer/eink.iss) (`MyAppVersion`) and add a [`windows/CHANGELOG.md`](../windows/CHANGELOG.md) entry.
2. Build with `windows/build.ps1` (produces `windows/dist/EInkMode-Setup-<version>.exe`).
3. Tag `windows-v<version>` (for example `windows-v0.1.0-beta.1`) and publish the release with `gh release create windows-v<version> --latest=false --title ... --notes ...`. **Always `--latest=false`** — `releases/latest` must keep pointing at the Mac release.
4. The only asset is the Setup `.exe` — never a `.zip`. That, plus the `windows-v...` tag shape, is what keeps this release invisible to the Mac in-app updater.

## Signing and notarization

Local `./scripts/build.sh` builds may use an ad hoc signature for development. `./scripts/release.sh` refuses to publish without a Developer ID identity, its 10-character Team ID, and a notarytool keychain profile. The installer and updater only accept the pinned publisher. Neither removes quarantine.

For Gatekeeper-clean builds, you need an Apple Developer Program membership:

```sh
xcrun notarytool store-credentials eink-notary --apple-id <id> --team-id <team>   # once; keep credentials in Keychain
EINK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" EINK_TEAM_ID=TEAMID1234 EINK_NOTARY_PROFILE=eink-notary ./scripts/release.sh
```

Use your actual Apple Team ID in `EINK_TEAM_ID`; never commit credentials. The build checks that the signature contains this Team ID, signs with hardened runtime and a timestamp, requires an accepted notarization result, staples and validates the app ticket, and re-zips the stapled app. A failed check stops the release before tagging or uploading. Keep the same identity for every release: macOS ties login-item approval to it.

Before publishing, run the clean-Mac installation and update checks in [QA.md](QA.md), including display restoration during the upgrade. These checks require real credentials and hardware; an ad hoc development build cannot stand in for them.
