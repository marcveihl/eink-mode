# E-Ink Mode

A native macOS menu bar utility for a calmer monochrome workspace. The original experiment remains untouched in `prototype0/`.

## Build and test

Requires macOS 13+, Xcode command-line tools with Swift 5.9 or newer, and Python 3 for CLI integration tests. No third-party dependencies.

```sh
./scripts/test.sh
./scripts/build.sh
open 'dist/E-Ink Mode.app'
```

The app is locally ad-hoc signed. This is a personal QA build, not a notarized public distribution.

## Use

Click the ◐ menu icon to open inline settings. Enable **Click to flip** to toggle E-Ink Mode with a quick click instead; long press (half a second), right-click, or Control-click the icon to open settings. This preference persists across app launches. **Enable E-Ink Mode** is the first action. **⌘⇧E** toggles globally; if another app owns the shortcut, the menu explains the conflict.

- Grayscale can be switched independently while active, without losing the original capture.
- Brightness applies only to displays whose current brightness can be captured. Each display restores its own value. External displays without native brightness support remain unchanged.
- Dock hiding and reduced transparency are optional. Reduced motion is offered only when its native getter/setter are available.
- Settings take effect immediately while active and persist for the CLI and next activation. Turning a profile option off restores its captured value. Grayscale off explicitly returns to color until full restoration.
- The optional nightly schedule defaults to **21:00–07:00 daily**, using local wall-clock time. It catches up on wake and app launch. Manual mode changes hold until the next scheduled boundary. Editing the schedule resets the override and reconciles immediately.
- Scheduling requires the app to be running. Enable **Launch at login** for daily use. Merely launching the app does not enable an unscheduled profile.
- Quit restores the original display. If restoration fails, the app stays open with a retry action. On restart, an unfinished session offers **Restore display** or **Resume** before scheduling proceeds.

Warmth remains managed by f.lux or Night Shift. Notification suppression is unavailable because this implementation cannot reliably capture and restore macOS Focus state. Smart/Classic Invert is deliberately unmanaged; prototype0 cannot capture it reliably.

## CLI

The app bundles a CLI at `dist/E-Ink Mode.app/Contents/MacOS/eink` (or `.build/release/eink`).

```sh
.build/release/eink status
.build/release/eink on
.build/release/eink set grayscale off
.build/release/eink set brightness 35
.build/release/eink set dock on
.build/release/eink set transparency on
.build/release/eink set schedule-on 21:00
.build/release/eink set schedule-off 07:00
.build/release/eink set schedule on
.build/release/eink off
```

App and CLI share atomic JSON configuration and a restoration journal in `~/Library/Application Support/E-Ink Mode/`. A process lock serializes operations. `EINK_HOME` selects an isolated directory. `EINK_SIMULATED=1` changes only a simulated system file and never your display; combine both for testing.

Existing prototype configuration is imported once as plain data from `~/.config/eink/config`. Shell expressions are never executed. Restore and quit prototype0 before enabling the new app; an existing legacy saved-state file blocks mutations to avoid losing the original capture. Do not run both versions at once.

## Recovery

Run `.build/release/eink off` to restore captured settings. If a captured display is disconnected, reconnect it and retry. Failed restores retain `state.json`; do not delete it. An `off` command without a capture changes nothing, protecting pre-existing accessibility settings. Malformed config/state files cause an explicit error rather than guessing what to restore.

See [QA checklist](docs/QA.md) and [implementation scope](docs/IMPLEMENTATION.md).
