# Changelog

## Unreleased (Focus controls and held color)

- **Hold to show color:** enable a dedicated hold shortcut in Settings → General. Choose Fn/Globe alone or a modifier combination; releasing returns to the current display state without replacing a timed color peek. Fn/Globe keeps its existing macOS action.
- **Pause/Resume Focus Round:** pause either focus or break time without losing the round or crediting the paused gap. Menu, Focus Stats, and CLI controls share the same persisted state. Automatic sleep/lock pausing is still planned.
- **Historical goals:** recorded days preserve their goal, older unknown goals remain explicitly unknown, and charts use saved daily targets. Totals describe up to 800 retained recorded days rather than claiming all-time coverage.
- **Trusted distribution:** release builds require Developer ID signing and accepted notarization. Installers and updates check the expected publisher and preserve quarantine. Credential setup and clean-Mac signed-release validation remain pending.
- Verified with 89 Swift tests, CLI integration, and offline release guard checks. Fn/Globe hold/release was also confirmed on the local Mac.

## 0.10.0-beta.3 (Keep display awake)

- **Keep Display Awake** in the menu (and **Settings → General → Display sleep**): while it's checked, the display won't sleep and the screen saver won't start, whether or not E-Ink Mode is on. Useful for reading a long page without touching the keyboard.
- It lasts until you switch it off and is remembered for the next launch. macOS ties the hold to the running app, so quitting, logging out, or a crash releases it — nothing is left behind. Closing the lid still sleeps the Mac.

- **Click-to-flip is harder to miss:** the icon now has to be held for about a second before the menu takes over, so a slow, deliberate click still switches the mode. Right-click and Control-click open the menu immediately, as before. A tap that slides a few points off the icon still counts, so trackpad taps land more often.

## 0.10.0-beta.2 (Icon parity)

- **One rule for the menu bar icon:** unshaded while your screen is in color (off), shaded while it's grayscale (on or focusing), and half-shaded during temporary color (a color peek or a focus break). The standard dot is now ○ / ● / ◐, and Wildcat mode matches it. Focus sessions no longer swap in timer or cup symbols; the countdown beside the icon shows a round is running.
- Welcome guide, installer, and settings text point to ○ (filled ● when on).
- README is more descriptive; step-by-step detail lives in the [user guide](docs/USER-GUIDE.md).

## 0.10.0-beta.1 (Focus sessions)

Turns E-Ink Mode into a study focus system.

- **Focus sessions (Pomodoro):** focus in grayscale, get color back for a short break, and repeat for a round of sessions. Defaults are 4 × 25 min with 5-minute breaks. Grayscale and color switch automatically.
- **Live countdown** in the menu bar and menu, with **Skip Break** and **Stop Focus Session**. A sound and a short hint mark each phase change.
- **Daily tracker and stats:** today's progress toward a daily goal (default 4, settable in Focus Stats or Settings), current and best streak, this week, all-time totals, best day, a 7-day chart, and an encouraging message based on where you are.
- **Settings → Focus:** focus length, break length, sessions per round, daily goal, sound, and the menu bar countdown.
- **Other options stay available mid-focus:** Color for 5 Minutes gives you a quick color peek, and the round's timer keeps running while you look.
- **Wildcat mode** (Settings → General): swaps ◐ for an original wildcat-head icon, outlined when off, shaded in when on, and half-shaded while showing color. Go 'Cats!
- **Robust by design:** rounds catch up after sleep; minutes from stopped sessions still count; a round started with E-Ink Mode off puts your display back when it ends; a round survives an app restart.
- CLI: `eink focus [sessions]`, `eink focus stop|skip`, `eink stats`, `eink set focus-minutes|break-minutes|focus-sessions|daily-goal N`.

## 0.9.0-beta.1 (first classmate beta)

Focus: install easily, understand the change before it happens, and trust that everything comes back.

**Installation and updates**
- One-line installer; a universal (Apple silicon + Intel) app; version shown in Settings and `eink version`.
- Automatic update checks against GitHub Releases, plus **Install and Relaunch** that verifies the download and rolls back if the swap fails.
- Opening a second copy reveals the running one. If the versions differ, you choose which copy to keep.
- Offers to move itself into Applications.
- Signing and notarization are wired into the build (`EINK_SIGN_IDENTITY`, `EINK_NOTARY_PROFILE`).

**Restoration**
- Concurrent menu and CLI edits no longer overwrite each other. Restore works even if the settings file is damaged. The daylight-saving repeated hour is handled.
- Logout, restart, `kill`, and updates restore the display first. After a logout, the schedule resumes on the next launch.
- Crash recovery asks **Restore Display** or **Continue Session**. Errors always offer **Restore Display**.

**First run**
- Welcome guide with a 10-second grayscale preview.
- **Gentler defaults: grayscale only.** Dimming and Dock hiding are opt-in. Existing settings are kept.

**Everyday use**
- New menu: status and the main switch first, then *Color for 5 Minutes*, *Schedule · …*, *Customize Appearance…*, *Settings…*, and *Quit and Restore Display*.
- **Color for 5 minutes**, with a live countdown, early **Resume grayscale**, and automatic return. The saved profile stays untouched.
- **Evening schedule** preset, a friendly time picker, and plain-language status (*Turns on tonight at 9:00 PM*, *Off by hand · resumes 7:00 AM*).
- Choosable keyboard shortcut with a conflict explanation. A hint appears when click-to-flip is enabled.
- CLI: `eink color [minutes]`, `eink grayscale`, `eink set schedule evening`, `eink version`.

**Deferred** until beta feedback: app exceptions (automatic color for chosen apps), a free-form shortcut recorder, Windows, themes, statistics, and sync.
