# Releasing

1. Bump [`VERSION`](../VERSION) (for example `0.9.0-beta.2`) and add a [CHANGELOG](../CHANGELOG.md) entry.
2. `./scripts/test.sh`, then run the real-Mac checks in [QA.md](QA.md).
3. `./scripts/release.sh`. It builds, then creates a GitHub release `v<VERSION>` with the zip, checksum, and `install.sh`, using the changelog section as notes.

## Requirements for classmates

- **The repository (or at least its releases) must be public.** The installer and in-app update check read `api.github.com/repos/<repo>/releases` without signing in, and a private repo returns 404. Alternatively, set `EINK_REPO=<owner>/<public-repo>` when building and releasing to publish from a separate public repo.
- **Publish as a normal release, not a pre-release.** `releases/latest/download/install.sh` only follows the latest non-pre-release. The version string already says *beta*, and the in-app updater compares versions properly.

## Signing and notarization

Without a Developer ID the app is ad-hoc signed. The installer clears quarantine, so it opens normally. A browser download needs *Open Anyway* once (see the README).

For Gatekeeper-clean builds, you need an Apple Developer Program membership:

```sh
xcrun notarytool store-credentials eink-notary --apple-id <id> --team-id <team>   # once
EINK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" EINK_NOTARY_PROFILE=eink-notary ./scripts/release.sh
```

The build then signs with the hardened runtime and a timestamp, submits to notarization, staples the ticket, and re-zips. Keep the same identity for every release: macOS ties login-item approval to it.
