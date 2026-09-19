<p align="center"><img src="docs/img/app-icon.png" width="128" alt="E-Ink Mode icon"></p>

<h1 align="center">E-Ink Mode</h1>

<p align="center"><b>A calmer, grayscale Mac for deep work: focus sessions, color breaks, and a daily streak. Always reversible.</b><br>
A tiny menu bar app for macOS 13 Ventura or newer. Currently in <b>beta</b>.</p>

---

E-Ink Mode turns your screen grayscale, like an e-reader. Color is what makes notifications, badges, and feeds grab your attention; without it, your screen feels quieter and it's easier to stay on one thing. When you need color, take it back for five minutes. To study, run **focus sessions**: grayscale while you work, color on your breaks, with a daily tracker that keeps your streak going. When you turn E-Ink Mode off, **your display returns exactly as it was.**

- [Install](#install)
- [First launch](#first-launch)
- [Everyday use](#everyday-use)
- [Focus sessions and daily stats](#focus-sessions-and-daily-stats)
- [Color for 5 minutes](#color-for-5-minutes)
- [Evening schedule](#evening-schedule)
- [Customize appearance](#customize-appearance)
- [Settings](#settings)
- [Your display always comes back](#your-display-always-comes-back)
- [Updating and uninstalling](#updating-and-uninstalling)
- [Privacy](#privacy) · [Limitations](#known-limitations) · [FAQ](#faq) · [For developers](#for-developers)

## Install

**Easiest:** open **Terminal** (press ⌘-Space, type *Terminal*, press Return), paste this line, and press Return:

```sh
curl -fsSL https://github.com/marcveihl/eink-mode/releases/latest/download/install.sh | bash
```

The script downloads the latest version, checks it, quits any older copy (restoring your display first), moves the app into **Applications**, and opens it. Look for **◐** in the menu bar at the top-right of your screen.

<details>
<summary><b>Prefer to download the zip yourself?</b></summary>

1. Download `E-Ink-Mode-<version>.zip` from the [latest release](https://github.com/marcveihl/eink-mode/releases) and double-click it to unzip.
2. Drag **E-Ink Mode** into your **Applications** folder.
3. Double-click it. Because this beta isn't notarized by Apple yet, macOS will say it *can't verify* the app. Click **Done** (or **OK** on older macOS), not *Move to Trash*.
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to *"E-Ink Mode" was blocked*. Confirm with your password.

You only do this once. Later updates install from inside the app.
</details>

If you open the app from Downloads, it offers to **move itself into Applications**. Say yes: launch-at-login and updates work reliably only from there. If you open the app while it's already running, the running copy shows you where it lives instead of starting a second one. If the two copies are different versions, you choose which one to keep.

## First launch

A short welcome guide explains what will change **before** anything changes.

<p align="center"><img src="docs/img/welcome.png" width="536" alt="Welcome window with four steps: what it does, try it first, optional extras, where to find it"></p>

1. **What it does:** grayscale only. Your apps, files, and settings stay the same.
2. **Try it first:** *Preview Grayscale for 10 Seconds* shows the effect and switches back on its own.
3. **Optional extras:** dimming the screen and auto-hiding the Dock are **off** unless you tick them. Your current brightness and Dock setting are saved and put back.
4. **Where to find it:** the ◐ icon in the menu bar. You can also choose to switch modes with a single click on the icon.

Choose **Turn On E-Ink Mode**, or **Not Now** to decide later. You can reopen the guide any time from **Settings → General → Show Welcome Guide**.

## Everyday use

Click **◐** in the menu bar. The mode and the main switch come first, and everything else sits below.

<p align="center"><img src="docs/img/menu-on.png" width="375" alt="Menu: E-Ink Mode · On, Turn Off, Color for 5 Minutes, Start Focus, Focus Stats…, today's progress, Schedule · Until 7:00 AM, Customize Appearance…, Settings…, Quit and Restore Display"></p>

| Menu item | What it does |
|---|---|
| **E-Ink Mode · On / Off** | The current state at a glance. |
| **Turn On / Turn Off** | The main switch. **⌘⇧E** does the same from any app. |
| **Color for 5 Minutes** | Brings color back briefly, then returns to grayscale by itself. |
| **Start Focus · 4 × 25 min** | Starts a round of focus sessions with color breaks ([below](#focus-sessions-and-daily-stats)). |
| **Focus Stats…** | Your daily tracker. The line below it shows today's count and your streak. |
| **Schedule · …** | What the schedule will do next, such as *Until 7:00 AM* or *Turns on tonight at 9:00 PM*. |
| **Customize Appearance…** | Grayscale, dimming, Dock, motion, and transparency. |
| **Settings…** | Click behavior, keyboard shortcut, login, and updates. |
| **Quit and Restore Display** | Puts everything back and closes the app. |

The icon shows the state: **◐** off, **●** on, **◌** temporarily in color, a **timer** with a countdown while focusing, a **cup** on a break, and **!** when something needs your attention.

**Prefer one click?** Turn on *Click the icon to switch* (in the welcome guide or **Settings → General**). A quick click then toggles E-Ink Mode, and **right-click**, **Control-click**, or **press and hold** opens the menu. A reminder appears at the bottom of the menu.

## Focus sessions and daily stats

Built for studying. Choose **Start Focus** and E-Ink Mode runs a round of focus sessions for you:

1. **Focus (25 min, grayscale).** The screen goes quiet so you can get into the work.
2. **Break (5 min, color).** Color comes back on its own. Check messages, stretch, look at something colorful.
3. **Repeat** for the number of sessions in your round (4 by default). After the last one, your display goes back to how it was.

<p align="center">
  <img src="docs/img/menu-focus.png" width="375" alt="Menu while focusing: Focus 1 of 4 · 18:30 left, Stop Focus Session">
  <img src="docs/img/menu-break.png" width="375" alt="Menu on a break: Break · 4:30 left, then focus 3 of 4, Skip Break, Stop Focus Session">
</p>

- **Always know where you are.** The menu bar shows a live countdown (⏱ 18:30), and the menu says *Focus 1 of 4 · 18:30 left* or *Break · 4:30 left, then focus 3 of 4*.
- **Gentle cues.** A soft sound and a short note under the icon mark each switch between focus and break. You can turn both off.
- **Everything stays within reach.** Your other options still work mid-focus: **Color for 5 Minutes** gives you a quick color peek, and the focus timer keeps running while you look. Schedule, Customize Appearance, and Settings are all still in the menu.

  <img src="docs/img/menu-focus-color.png" width="380" alt="Menu mid-focus with a color peek: Focus 1 of 4 · 18:29 left, Resume grayscale · 4:32 remaining">
- **Flexible.** **Skip Break** starts the next session right away. **Stop Focus Session** ends the round, and minutes you already focused still count.
- **Reliable.** If your Mac sleeps mid-round, the round catches up when it wakes. If the app restarts, the round continues. The schedule waits until the round is over.

### Your daily tracker

**Focus Stats…** shows how your studying adds up.

<p align="center"><img src="docs/img/focus-stats.png" width="576" alt="Focus Stats: today 3 of 4 sessions with progress bar and daily goal control, 7-day streak, 36 this week, 91 all time, best day 9, and a 7-day bar chart with a goal line"></p>

- **Today:** completed sessions against your **daily goal**, plus minutes focused. The goal is 4 sessions a day by default. Set it (1–24) right under the progress bar, or in **Settings → Focus**.
- **Streak:** days in a row with at least one completed session, and your best streak. Nothing yet today? Yesterday still counts, so the streak stays alive until midnight.
- **This week, all time, and best day**, plus how many days you've met your goal.
- **Last 7 days:** a bar per day, with your goal as a dashed line.
- **A nudge that fits the moment:** *5 more sessions to reach today's goal*, *Keep your 4-day streak alive*, *New personal best!*

### Make it yours

Choose lengths and goals in **Settings → Focus**: focus 5–90 minutes, breaks 1–30 minutes, 1–12 sessions per round, and a daily goal of 1–24 sessions (default 4). Changes apply to your next round; a round in progress keeps its timing.

<p align="center"><img src="docs/img/settings-focus.png" width="516" alt="Focus settings: focus length, break length, sessions per round, daily goal, sound and menu bar countdown toggles"></p>

Your focus history stays on your Mac (`focus-history.json`) and never leaves it.

## Color for 5 minutes

Checking a photo, a chart, or a color-coded calendar? Choose **Color for 5 Minutes**. Only grayscale is lifted; dimming, the Dock, and your other choices stay as they are. The menu counts down, and you can go back early with one click.

<p align="center"><img src="docs/img/menu-color.png" width="375" alt="Menu while temporarily in color: Resume grayscale · 4:32 remaining"></p>

When time is up, grayscale returns automatically, even if your Mac was asleep in the meantime. Your saved settings are never changed by temporary color.

## Evening schedule

Let E-Ink Mode turn on in the evening and off in the morning. Pick **Schedule → Evening · 9:00 PM – 7:00 AM** from the menu, or choose your own times in **Settings → Schedule**.

<p align="center"><img src="docs/img/settings-schedule.png" width="516" alt="Schedule settings with Never, Evening, and Custom options and a 'What happens next' explanation"></p>

- **You can always predict it.** The menu and settings say what happens next in plain words: *Turns on tonight at 9:00 PM*, *Until 7:00 AM*.
- **Switching by hand always wins.** If you turn it off during the evening, the schedule leaves it off until its next change, and the menu says so: *Off by hand · resumes 7:00 AM*.

  <img src="docs/img/menu-off.png" width="382" alt="Menu showing Schedule · Off by hand · resumes 7:00 AM">
- **It catches up** after your Mac wakes from sleep. After a restart or logout, it picks up the current period again when the app reopens.
- The schedule runs while the app is open. Turn on **Open E-Ink Mode at login** so it works every day. Opening the app never turns E-Ink Mode on by itself.

## Customize appearance

Everything beyond grayscale is optional and **off by default**. Changes apply immediately while E-Ink Mode is on, and each one goes back to its original value when you turn E-Ink Mode off.

<p align="center"><img src="docs/img/settings-appearance.png" width="516" alt="Appearance settings: Grayscale, Dim the screen with slider, Auto-hide the Dock, Reduce motion, Reduce transparency"></p>

| Option | Notes |
|---|---|
| **Grayscale** | The core effect. |
| **Dim the screen** | Sets your chosen brightness while on. Works on built-in and Apple displays. Other external monitors keep their own controls. |
| **Auto-hide the Dock** | Hides the Dock until you move the pointer to it. |
| **Reduce motion / transparency** | macOS accessibility options. Greyed out if your Mac doesn't support them. |

*What this Mac supports* lists anything your Mac can't control.

## Settings

<p align="center"><img src="docs/img/settings-general.png" width="516" alt="General settings: click behavior, keyboard shortcut, open at login, version and updates, help"></p>

- **Menu bar icon:** choose whether a click opens the menu or switches the mode.
- **Keyboard shortcut:** ⌘⇧E by default. Choose ⌃⌥⌘E, ⌃⌥E, ⌃⌥⌘G, or none. If another app already uses the shortcut, the app says so right there, so you can pick a different one.
- **Open E-Ink Mode at login:** needed for schedules. macOS may ask you to approve it in *System Settings → General → Login Items*.
- **Updates:** shows your **version** and checks for new versions automatically. When an update is available, it also appears in the menu. **Install and Relaunch** restores your display, installs the update, and reopens the app, back on if it was on.
- **Help:** reopen the welcome guide, or **Restore Display Now**.

## Your display always comes back

Changing someone's screen needs to be trustworthy. E-Ink Mode records your original settings on disk **before** it changes anything, and it only uses settings it can read back and restore.

| When you… | What happens |
|---|---|
| Turn it off, press the shortcut, or choose **Quit and Restore Display** | Every setting it changed goes back to its exact original value, one display at a time. |
| Log out, restart, or shut down | Your display is restored first. |
| Update the app | Your display is restored before the update is installed. |
| The app crashes or is force-quit | Next time it opens, it asks: **Restore Display** or **Continue Session**. |
| Something can't be restored (for example, a monitor was unplugged) | The app stays open and tells you why. Reconnect the monitor and choose **Restore Display** or **Try Again**. It won't quit and forget your originals. |
| Grayscale was already on before you started | It stays on. E-Ink Mode never turns off settings it didn't turn on. |

**Emergency switch:** in Terminal, run `"/Applications/E-Ink Mode.app/Contents/MacOS/eink" off`. You can also turn grayscale off yourself in *System Settings → Accessibility → Display → Color Filters*.

## Updating and uninstalling

**Update:** use **Settings → General → Check Now** (or the *Update Available* menu item), or re-run the install command.

**Uninstall:**
1. Choose **Quit and Restore Display** from the menu.
2. Drag **E-Ink Mode** from Applications to the Trash.
3. Optional, to remove saved preferences, run in Terminal:
   ```sh
   rm -rf ~/Library/Application\ Support/E-Ink\ Mode && defaults delete local.eink.mode
   ```

## Privacy

E-Ink Mode has no accounts, analytics, or tracking. The only network request is the update check, which reads the public release list from GitHub. You can turn it off in Settings. Your settings stay on your Mac in `~/Library/Application Support/E-Ink Mode/`.

## Known limitations

- **Beta signing:** this beta isn't notarized by Apple yet, so a manual download needs the one-time *Open Anyway* step. The install command avoids this.
- **Warm colors:** use Night Shift or f.lux. E-Ink Mode leaves warmth to them.
- **Notifications:** E-Ink Mode doesn't change Focus or Do Not Disturb, because macOS gives apps no reliable way to restore them.
- **Brightness** works only on displays that let macOS control it.
- **Schedules** need the app to be running (turn on *Open at login*).

## FAQ

**Is this the same as the grayscale color filter in Accessibility settings?** It uses the same macOS grayscale, plus one-click switching, temporary color, schedules, optional extras, and guaranteed restoration.

**Will it fight with my own accessibility settings?** No. It records what you had and puts that back, including settings that were already on.

**I don't see the icon.** Your menu bar may be full. Hide a few other icons, or use the shortcut **⌘⇧E**. Opening the app again from Applications also points to it.

**Does it slow down my Mac?** No. It changes a few system settings, then waits. It doesn't process your screen.

## For developers

Requires Xcode command-line tools (Swift 5.9+) and Python 3 for the CLI tests. No third-party dependencies.

```sh
./scripts/test.sh     # 66 core tests + process-level CLI tests against a simulated system
./scripts/build.sh    # universal app + dist/E-Ink-Mode-<VERSION>.zip + install.sh
```

The version comes from [`VERSION`](VERSION). Set `EINK_SIGN_IDENTITY` (Developer ID Application) and `EINK_NOTARY_PROFILE` (a `notarytool` keychain profile) to produce a signed, notarized build. See [docs/RELEASING.md](docs/RELEASING.md).

The app bundles a CLI with the same controls, sharing the same saved settings and recovery record:

```sh
eink status | on | off | toggle | version
eink color [minutes]      # temporary color (default 5), then back to grayscale
eink grayscale            # end temporary color now
eink focus [sessions]     # start a round of focus sessions; eink focus stop | skip
eink stats                # today's progress, streak, and totals
eink set focus-minutes|break-minutes|focus-sessions|daily-goal N
eink set grayscale|dock|motion|transparency on|off
eink set brightness 5..100|unchanged
eink set schedule evening|on|off
eink set schedule-on|schedule-off HH:MM
```

`EINK_HOME` selects an isolated state directory, and `EINK_SIMULATED=1` changes a simulated system instead of your display. `EinkBar --qa-snapshots <dir>` (simulated only) renders the screenshots in this README.

More: [beta testing guide](docs/BETA-TESTING.md) · [QA checklist](docs/QA.md) · [changelog](CHANGELOG.md) · [original PRD](docs/PRD.md) · [implementation scope](docs/IMPLEMENTATION.md). The first prototype is preserved in `prototype0/`.
