# Release QA

## Automated

`./scripts/test.sh` runs 68 core tests and process-level CLI tests against an isolated simulated system (`EINK_SIMULATED=1`). Coverage:

- **Restoration:** exact per-display capture and restore, pre-existing accessibility settings, idempotent activation, partial failures and rollback, retry after restart, corrupt journal and config, restore with a damaged config, and never clearing settings the app didn't set.
- **Temporary color:** lifts grayscale only, leaves the saved profile untouched, cancels early, expires on tick, catches up after sleep, clears when turned off, honors expiry across a crash and resume, and edits during color.
- **First-run preview:** the one-off profile is never saved and restores exactly.
- **Defaults:** a fresh install changes grayscale only.
- **Schedule:** boundaries, DST skipped and repeated hours, catch-up, manual overrides across restarts, quit pausing versus logout resuming, and plain-language status (*tonight*, *this morning*, *tomorrow*, manual override).
- **Focus sessions:** grayscale focus and color breaks, the rest of the profile kept, round completion and ownership of the mode, catch-up across several phases after sleep, stopping early with credited minutes, turning off mid-round, skipping breaks, color peeks mid-focus that keep the timer running (and are refused on breaks), a daily goal that defaults to 4 and can be changed, the schedule deferring to a round, settings edits not disrupting a round, surviving a restart, validation, and old config files without focus settings.
- **Stats:** streaks from today or yesterday, gaps, best streak, week labels, retained totals, best day, saved daily goals, unknown legacy goals excluded from goal attainment, retention pruning, and each motivational message.
- **Keep display awake:** the power assertion is registered with macOS while held and gone once released; repeating a hold or a release is a no-op.
- **Updates:** semantic version and pre-release ordering, release feed selection (drafts, missing archives, invalid tags), and bundle swap with rollback when the replacement is missing.
- **CLI:** settings, validation, concurrency (48 mode commands and concurrent edits), temporary color, the evening preset, `version`, and recovery.

`./scripts/build.sh` builds a universal (arm64 + x86_64) local app, verifies its signature, and writes the zip, checksum, and `install.sh`. The local ad hoc build is not installable by the trusted installer. A distribution build requires Developer ID signing, notarization, stapling, and a pinned Team ID. With a signed distribution archive, test the installer offline without touching a running copy:

```sh
EINK_NO_LAUNCH=1 EINK_INSTALL_DIR=/tmp/apps LC_ALL=C bash dist/install.sh dist/E-Ink-Mode-*.zip
```

`EINK_SIMULATED=1 EINK_HOME=/tmp/qa ".../EinkBar" --qa-snapshots /tmp/shots` renders the welcome, settings, and menu screenshots for visual review.

## On a real Mac (before each release)

Grayscale must be checked **with your eyes**. API readback doesn't prove pixels changed. Record your macOS version and displays.

### Install and updates
1. Fresh account or clean Mac: download the release ZIP in a browser, unzip it, and open the app. It opens without **Open Anyway** or quarantine removal. Accept **Move to Applications**. The app relaunches from Applications.
2. On the same clean Mac, run the one-line installer. The signed, notarized app lands in Applications and opens. Try an archive signed by a different Team ID: the installer rejects it without replacing the installed app.
3. Open the app again while it's running. No second icon appears; a hint points at the existing icon.
4. Run an older build from another folder while the new one is running. The version-choice alert names both versions. **Use Version …** quits the other copy and restores the display.
5. Publish a signed, notarized test release with a higher version. **Check Now** finds it, the menu shows *Update Available*, and **Install and Relaunch** restores, swaps, reopens, and turns back on if it was on. **Settings → Version** shows the new number. A wrong-publisher or unnotarized archive is refused before the running copy exits or the bundle is replaced.

### First run
6. The welcome window explains what will change. The preview runs 10 s, shows grayscale only, and returns to color. Closing the window mid-preview also returns to color.
7. Leaving extras off changes grayscale only. Dock and brightness are untouched.

### Everyday controls and temporary color
8. The menu order matches the design: status, switch, color, schedule, customize, settings, then quit.
9. **Color for 5 Minutes**: the countdown ticks live in the open menu, dimming and Dock stay, **Resume grayscale** works early, and expiry returns grayscale within about a second. Sleep past the expiry and wake: it's grayscale.
10. Click-to-flip: a quick click toggles, including a slow, deliberate one — the menu only takes over after holding for about a second. Right-click and Control-click open the menu at once. A tap that slides a few points still switches; dragging well away from the icon does nothing. The hint appears when you enable it.
10a. Hold-to-peek: enable **Hold to show color** (default **⌃⌥⌘C**), press and hold the combination, and confirm color appears while held. Release it and confirm the current focus phase, timed peek, or schedule state is restored. Test a lost key-up, sleep/lock, app deactivation, and a conflicting shortcut; a missed release must expire within the short lease and never leave color stuck.
10b. Select **Fn / 🌐 Globe** and repeat the hold/release check from another app. Check that enabling or selecting Fn while already holding it waits for release and a fresh press. Switch back to a combination and confirm Fn no longer peeks. The Mac's configured Globe action remains unchanged; test with that action set to **Do Nothing** if it interferes.
11. The shortcut switches from other apps. Choose each preset, then **None**. A conflicting shortcut shows the *already taken* message.

### Keep display awake
11a. Set **System Settings → Lock Screen → Turn display off** to 1 minute. Choose **Keep Display Awake**: `pmset -g assertions` lists *PreventUserIdleDisplaySleep* named for E-Ink Mode, and the display stays on past a minute of no input. The menu shows a checkmark and the line *Your display stays on until you switch this off*.
11b. Switch it off: the assertion disappears from `pmset -g assertions` and the display sleeps on schedule again. Switch it on, quit the app, and check `pmset` again — quitting releases it.
11c. With it on, quit and reopen the app: the checkmark is back and the assertion is held again. Closing the lid still sleeps the Mac.

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
15i. Pause mid-focus: the menu and Focus Stats show **Paused**, the remaining time stays fixed, and grayscale remains on. Resume after several minutes: the same round continues and the paused gap earns no minutes. Pause during a break: color stays on and the break clock freezes. Start a color peek before pausing focus and let it expire: grayscale returns, with the round still paused. Cross a schedule boundary while paused: it waits for the round to end. Stop while paused: only active focus minutes count. Quit while paused: the original display returns. Force-quit and relaunch: choose **Continue Session** and check that the round is still paused until you explicitly resume it.
15g. Change the daily goal with the Focus Stats stepper: today's progress, message, and chart marker update. Earlier days keep their saved goal markers and goal-met results; legacy days with unknown goals show no marker and are excluded from the goal-met count.
15h. Icon parity: the dot is ○ when off, ● when on or focusing, and ◐ during color peeks and focus breaks. **Wildcat mode** follows the same rule: outlined, filled, half-shaded. Check both sets in light and dark menu bars; the focus countdown shows beside either. The warning icon replaces both when something needs attention.
15e. Focus Stats updates after each completed session; the 7-day chart and streak look right; hovering a bar shows its values.

### Restoration
15. With brightness, Dock, and transparency enabled: **Quit and Restore Display** puts every value back.
16. `kill <pid>` of EinkBar: the display is restored. `kill -9`, then relaunch: the recovery alert offers **Restore Display** / **Continue Session**.
17. Grayscale already on before activation: still on after restore.
18. External monitor: unplug while on, then turn off. The error names the display and the app stays open. Reconnect and **Restore Display** succeeds.
19. Change a setting from the CLI while the app runs. The menu reflects it within 5 s.
