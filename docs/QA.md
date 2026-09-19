# Release QA

## Automated

`./scripts/test.sh` runs 66 core tests and process-level CLI tests against an isolated simulated system (`EINK_SIMULATED=1`). Coverage:

- **Restoration:** exact per-display capture and restore, pre-existing accessibility settings, idempotent activation, partial failures and rollback, retry after restart, corrupt journal and config, restore with a damaged config, and never clearing settings the app didn't set.
- **Temporary color:** lifts grayscale only, leaves the saved profile untouched, cancels early, expires on tick, catches up after sleep, clears when turned off, honors expiry across a crash and resume, and edits during color.
- **First-run preview:** the one-off profile is never saved and restores exactly.
- **Defaults:** a fresh install changes grayscale only.
- **Schedule:** boundaries, DST skipped and repeated hours, catch-up, manual overrides across restarts, quit pausing versus logout resuming, and plain-language status (*tonight*, *this morning*, *tomorrow*, manual override).
- **Focus sessions:** grayscale focus and color breaks, the rest of the profile kept, round completion and ownership of the mode, catch-up across several phases after sleep, stopping early with credited minutes, turning off mid-round, skipping breaks, color peeks mid-focus that keep the timer running (and are refused on breaks), a daily goal that defaults to 4 and can be changed, the schedule deferring to a round, settings edits not disrupting a round, surviving a restart, validation, and old config files without focus settings.
- **Stats:** streaks from today or yesterday, gaps, best streak, week labels, totals, best day, days the goal was met, and each motivational message.
- **Updates:** semantic version and pre-release ordering, release feed selection (drafts, missing archives, invalid tags), and bundle swap with rollback when the replacement is missing.
- **CLI:** settings, validation, concurrency (48 mode commands and concurrent edits), temporary color, the evening preset, `version`, and recovery.

`./scripts/build.sh` builds a universal (arm64 + x86_64) app, verifies its signature, and writes the zip, checksum, and `install.sh`. Test the installer offline without touching a running copy:

```sh
EINK_NO_LAUNCH=1 EINK_INSTALL_DIR=/tmp/apps LC_ALL=C bash dist/install.sh dist/E-Ink-Mode-*.zip
```

`EINK_SIMULATED=1 EINK_HOME=/tmp/qa ".../EinkBar" --qa-snapshots /tmp/shots` renders the welcome, settings, and menu screenshots for visual review.

## On a real Mac (before each release)

Grayscale must be checked **with your eyes**. API readback doesn't prove pixels changed. Record your macOS version and displays.

### Install and updates
1. Fresh account or cleaned Mac: run the one-line installer. The app lands in Applications, opens, and the welcome guide appears.
2. Unzip manually into Downloads and open it. *Open Anyway* is needed once. Accept **Move to Applications**. The app relaunches from Applications.
3. Open the app again while it's running. No second icon appears; a hint points at the existing icon.
4. Run an older build from another folder while the new one is running. The version-choice alert names both versions. **Use Version …** quits the other copy and restores the display.
5. Publish a test release with a higher version. **Check Now** finds it, the menu shows *Update Available*, and **Install and Relaunch** restores, swaps, reopens, and turns back on if it was on. **Settings → Version** shows the new number.

### First run
6. The welcome window explains what will change. The preview runs 10 s, shows grayscale only, and returns to color. Closing the window mid-preview also returns to color.
7. Leaving extras off changes grayscale only. Dock and brightness are untouched.

### Everyday controls and temporary color
8. The menu order matches the design: status, switch, color, schedule, customize, settings, then quit.
9. **Color for 5 Minutes**: the countdown ticks live in the open menu, dimming and Dock stay, **Resume grayscale** works early, and expiry returns grayscale within about a second. Sleep past the expiry and wake: it's grayscale.
10. Click-to-flip: a quick click toggles; long press, right-click, and Control-click open the menu; dragging off does nothing. The hint appears when you enable it.
11. The shortcut switches from other apps. Choose each preset, then **None**. A conflicting shortcut shows the *already taken* message.

### Schedule
12. **Evening** preset: before 9 PM the menu shows *Turns on tonight at 9:00 PM*. Custom times a few minutes ahead: it turns on and off at the boundaries.
13. A manual change during a scheduled period shows *Off/On by hand · resumes …*. Polling doesn't undo it.
14. Sleep across a boundary and wake: it catches up. Log out and back in during the evening period (with **Open at login**): it's on again.

### Focus sessions
15a. Settings → Focus to 5/1/2. Start Focus: the menu bar shows a timer and countdown and the display turns grayscale. At 5:00 a sound plays, color returns, and the menu shows *Break · … then focus 2 of 2*. After the break, grayscale returns. After session 2, the display is restored and the *Round complete* hint shows today's count.
15b. **Skip Break** starts the next session immediately. **Stop Focus Session** mid-focus restores the display, and Focus Stats credits the minutes.
15c. Start a round while E-Ink Mode is already on: afterwards it stays on in grayscale.
15d. Sleep mid-focus past the break and wake: the round catches up to the right phase.
15f. Mid-focus **Color for 5 Minutes**: color appears, the focus countdown keeps running, and grayscale returns after the peek or on **Resume grayscale**. The item is hidden during breaks.
15g. Change the daily goal with the Focus Stats stepper: the progress bar, message, and chart goal line update.
15h. Icon parity: the dot is ○ when off, ● when on or focusing, and ◐ during color peeks and focus breaks. **Wildcat mode** follows the same rule: outlined, filled, half-shaded. Check both sets in light and dark menu bars; the focus countdown shows beside either. The warning icon replaces both when something needs attention.
15e. Focus Stats updates after each completed session; the 7-day chart and streak look right; hovering a bar shows its values.

### Restoration
15. With brightness, Dock, and transparency enabled: **Quit and Restore Display** puts every value back.
16. `kill <pid>` of EinkBar: the display is restored. `kill -9`, then relaunch: the recovery alert offers **Restore Display** / **Continue Session**.
17. Grayscale already on before activation: still on after restore.
18. External monitor: unplug while on, then turn off. The error names the display and the app stays open. Reconnect and **Restore Display** succeeds.
19. Change a setting from the CLI while the app runs. The menu reflects it within 5 s.
