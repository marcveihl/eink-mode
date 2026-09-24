# Windows Changelog

## 0.1.0-beta.1 · 2026-09-24

First Windows beta.

- **On / Off with exact capture and restore.** The tray icon, the menu, the CLI, and Ctrl+Shift+E all drive the same switch. Before its first change per session, E-Ink Mode captures the exact display state and puts it back exactly when the session ends — including an already-active Inverted filter, not just plain off.
- **Color for 5 Minutes** — a temporary reprieve back to color that returns to grayscale on its own, with a live countdown in the menu.
- **Evening schedule** with plain-language status ("Turns on tonight at 9:00 PM") and a hand override: switching by hand always wins until the schedule's next change.
- **Optional extras** — dim the screen, auto-hide the taskbar, reduce motion, and reduce transparency, all applied together with grayscale and restored together when it turns off.
- **Ctrl+Shift+E** global shortcut, with presets (Ctrl+Alt+Shift+E, Ctrl+Alt+E, Ctrl+Alt+Shift+G, or none).
- **Welcome guide** with a 10-second live preview, shown on first run (Settings → "Show Welcome Guide" to see it again).
- **Settings window** — General, Appearance, and Schedule tabs.
- **Click-to-switch** — an option to make a left click toggle E-Ink Mode directly instead of opening the menu.
- **Wildcat icon** — an original wildcat-head icon that follows the same ○ / ● / ◐ rule as the dot.
- **Open E-Ink Mode at login**, for schedules that need to run every day.
- **Crash recovery** — an unfinished session is never silently resolved; the next launch offers Restore Display or Continue Session. The display is also restored on logoff and shutdown.
- **`eink.exe` CLI** — the same state machine, no tray required, and the emergency switch if the tray or hotkey are ever stuck (`eink status|on|off|toggle|color|grayscale|config|set|version`).

**Not yet on Windows:** focus sessions and stats, auto-update, code signing.
