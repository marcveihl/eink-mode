# Changelog

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
