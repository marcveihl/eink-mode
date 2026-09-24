# E-Ink Mode — Windows

A tray app that flips your display to grayscale (and back) with one click or
a keyboard shortcut — the Windows port of the macOS menu-bar E-Ink Mode item,
built on top of Windows' own Color Filters rather than fighting them.

## Install

1. Download `EInkMode-Setup-0.1.0.exe` and run it. No administrator rights
   are needed — it installs for your user only, into
   `%LOCALAPPDATA%\Programs\E-Ink Mode`.
2. **Windows SmartScreen will warn you** ("Windows protected your PC") because
   this build isn't code-signed yet. Click **More info**, then **Run anyway**.
3. **If you already have the old v0 tray running** (the one launched from
   `eink.vbs`/`eink.ps1` in this repo), quit it first — it holds the same
   single-instance lock as the new tray, so only one of them can run at a
   time. The installer detects this and asks you to close it before it will
   install or uninstall over it.
4. Finish the wizard. It offers a Start Menu shortcut ("E-Ink Mode"), an
   optional desktop shortcut (unchecked by default), and launches the app for
   you at the end (checked by default). First run shows a short Welcome guide.

Uninstalling (Settings → Apps, or the Start Menu entry) restores your display
before removing anything, closes the tray, and removes the "Open at login"
registry entry — nothing is left running or grayscale afterward.

## What's in the app

- **On / Off** — the tray icon toggle, a menu item, the CLI, and a global
  keyboard shortcut (default **Ctrl+Shift+E**, configurable in Settings —
  Ctrl+Alt+Shift+E, Ctrl+Alt+E, Ctrl+Alt+Shift+G, or none) all drive the same
  switch.
- **Color for 5 minutes** — a temporary reprieve back to color that returns to
  grayscale on its own; the menu shows a live countdown while it's active.
- **Schedule** — off (switch it yourself), a one-click "Evening" preset
  (9 PM–7 AM), or custom on/off times. Switching by hand always wins until the
  schedule's next change.
- **Appearance extras** (Customize Appearance…) — dim the screen to a chosen
  brightness, auto-hide the taskbar, reduce motion, and reduce transparency,
  all applied together with grayscale and restored together when it turns
  off.
- **Welcome guide** — a short first-run walkthrough (Settings → "Show Welcome
  Guide" to see it again) that previews the switch live as you adjust it.
- **Crash recovery** — if the tray didn't exit cleanly with a session still
  open, the next launch offers "Restore Display" or "Continue Session"
  instead of silently picking one for you.
- **Open E-Ink Mode at login** — an HKCU `Run` entry, toggled from Settings.

Out of scope on Windows: Focus/Pomodoro sessions and the auto-updater (see
`PARITY-SPEC.md`).

## The tray

| Icon | Meaning |
|---|---|
| ● filled disc | grayscale on |
| ◐ half disc | on, temporarily showing color |
| ○ ring | grayscale off |

The ink colour follows the taskbar theme. Left-click toggles (or opens the
menu, if "click to switch" is off); the menu adds Color for 5 Minutes,
Schedule, Customize Appearance…, Settings…, and Quit and Restore Display.

The icon follows the actual OS filter rather than owning it: press
Win+Ctrl+C yourself, or change it in Settings → Accessibility → Color
filters, and the tray catches up within about a second.

## The `eink` CLI

Installed as `eink.exe` next to `EInkMode.exe` — the same state machine, no
tray required, and the emergency switch if the tray or hotkey are ever stuck:

```
eink status                         JSON: configuration, session, live system values
eink on | off | toggle | version
eink color [minutes]                temporary color, default 5 minutes
eink grayscale                      end temporary color now
eink config                         show configuration
eink set grayscale|dock|motion|transparency on|off
eink set brightness 5..100|unchanged
eink set schedule evening|on|off
eink set schedule-on|schedule-off HH:MM
```

Exit code 0 on success; on error, exit 1 with a one-line message on stderr.

## How the switch works, and why it is not the registry

Measured on build 26200:

- Writing `HKCU\Software\Microsoft\ColorFiltering\Active` **persists the
  value but does not change the screen**, with or without a
  `WM_SETTINGCHANGE` broadcast.
- The **Win+Ctrl+C** hotkey reads `Active`, inverts it, applies that to the
  screen, and writes it back. So after any single press the registry and the
  screen agree.

Hence: never write `Active`; press the hotkey and read `Active` back to
confirm. `FilterType` is written only while the filter is off, because that
write does not apply live either.

There is deliberately **no screenshot check** anywhere in this codebase. On
this build `CopyFromScreen` captures before the filter is composited, so a
screenshot of a grey screen comes back in colour — which is exactly how the
earlier `eink.ps1` talked itself into a stuck state.

Before its first change per session, the switch captures the exact filter
state (`Active` + `FilterType`) and restores that exact state when the
session ends — so if you already run the Inverted filter, turning E-Ink Mode
on and off again leaves you back on Inverted, not plain off. **Screen doesn't
match? Resync** (`eink --resync` / the tray menu when something's wrong)
presses the hotkey twice: the registry ends where it started and the screen
is forced to agree with it.

## Escape hatches

If E-Ink Mode itself is ever unresponsive:

- **Win+Ctrl+C** — the OS's own toggle, works whether or not the tray is
  running.
- Settings → Accessibility → Color filters → off.
- `eink.exe off` (see the CLI above) — the same path the uninstaller uses to
  restore your display.
- Quit and Restore Display in the tray menu restores color by default before
  exiting.

## Developers

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python.exe eink_tray.py          # run the tray from source
.venv\Scripts\python.exe eink_ui.py settings   # run Settings from source
.venv\Scripts\python.exe eink_cli.py status    # run the CLI from source
```

Tests (201 tests; never touch the real display, registry, or taskbar —
`EINK_SIMULATED=1` and `eink_sim.FakeSystem`/`SimulatedSystem` stand in):

```powershell
.venv\Scripts\python.exe -W error -m unittest discover -p "test_*.py"
```

### Building the installer

```powershell
.venv\Scripts\pip install -r requirements-build.txt   # PyInstaller
.\build.ps1
```

`build.ps1` installs the build requirements, runs PyInstaller against
`eink.spec` (produces `dist\EInkMode\EInkMode.exe` — windowed, the tray and
`ui settings|welcome` — and `dist\EInkMode\eink.exe`, the console CLI, in one
`--onedir` folder), then locates or installs Inno Setup (`ISCC.exe`, via
`winget install --id JRSoftware.InnoSetup`) and compiles
`installer\eink.iss` into `dist\EInkMode-Setup-0.1.0.exe`. `eink_app.py` is
the single frozen entry point (`EInkMode.exe` with no args → tray, `ui ...` →
Settings/Welcome, `cli ...` → the CLI); `eink_paths.py` is the one place that
knows whether it's running frozen or from source when it builds a command
line to relaunch itself (spawning the Settings/Welcome window, or the
"Open at login" registry value).

See `PARITY-SPEC.md` for the full architecture and macOS parity contract.
