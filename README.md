<p align="center"><img src="docs/img/app-icon.png" width="128" alt="E-Ink Mode icon"></p>

# E-Ink Mode

**A quieter Mac in one click.** Switch to grayscale, take a short color break, or run timed focus sessions from your menu bar.

For macOS 13 Ventura or newer · Apple silicon and Intel · **Beta**

[Download](https://github.com/marcveihl/eink-mode/releases/latest) · [User guide](docs/USER-GUIDE.md) · [Changelog](CHANGELOG.md) · [Roadmap](docs/ROADMAP.md)

<p align="center"><img src="docs/img/menu-on.png" width="375" alt="E-Ink Mode menu with mode toggle, temporary color, focus sessions, and schedule"></p>

## What it does

- **One-click grayscale:** toggle from the menu bar or with **⌘⇧E**.
- **Temporary color:** see color for five minutes, then return to grayscale automatically.
- **Focus sessions:** alternate grayscale work and color breaks; defaults to four 25-minute sessions with 5-minute breaks.
- **Local stats:** track completed sessions, minutes, daily goals, and streaks.
- **Evening schedule:** use the 9 PM–7 AM preset or choose your own times.
- **Optional appearance changes:** dim the screen, hide the Dock, or reduce motion and transparency where supported.

First launch includes a 10-second preview. Grayscale is the only default change; brightness and Dock changes are opt-in.

## Install

Download the ZIP from the [latest release](https://github.com/marcveihl/eink-mode/releases/latest), unzip it, and move **E-Ink Mode.app** to **Applications**.

This beta is not yet notarized. If macOS blocks the app, use **System Settings → Privacy & Security → Open Anyway** after attempting to open it.

Prefer Terminal? Review the [installer](scripts/install.sh), then run:

```sh
curl -fsSL https://github.com/marcveihl/eink-mode/releases/latest/download/install.sh | bash
```

The installer downloads and installs the app and removes its quarantine attribute. In-app updates are available under **Settings → General**.

## Use

Click **◐** in the menu bar to turn the mode on, start focus sessions, or change settings.

- Enable **Click the icon to switch** for one-click toggling. Right-click, Control-click, or hold to open the menu.
- Choose **Color for 5 Minutes** when you need color; **Resume grayscale** ends it early.
- Enable **Open at login** if you want the schedule to run each day.
- Choose **Quit and Restore Display** before uninstalling.

See the [user guide](docs/USER-GUIDE.md) for focus controls, stats, shortcuts, Wildcat icons, and troubleshooting.

## Privacy and limitations

Settings and focus history stay on your Mac. There are no accounts or analytics. Update checks and downloads contact GitHub; automatic checks can be disabled.

The app saves your original display settings for restoration. After a crash, it offers recovery on the next launch. Disconnected displays may need reconnecting before restoration can finish.

Brightness support varies by display. Night Shift, f.lux, and notification settings are managed separately. Schedules require the app to be running. Focus stats record elapsed timer sessions, including catch-up after sleep—not measured attention.

## Build

Requires Xcode command-line tools with Swift 5.9+ and Python 3. No third-party dependencies.

```sh
./scripts/test.sh
./scripts/build.sh
```

[CLI reference](docs/USER-GUIDE.md#for-developers) · [Release guide](docs/RELEASING.md) · [Beta testing](docs/BETA-TESTING.md) · [QA checklist](docs/QA.md)
