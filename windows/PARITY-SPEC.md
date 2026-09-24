# Windows ↔ macOS parity — build contract

Written 2026-09-23. Target: macOS `0.10.0-beta.2` (the reference is the repo
root this `windows/` directory lives in — read `../docs/USER-GUIDE.md` and
`../Sources/EinkCore/*.swift` first).

**Out of scope on this machine:** everything Focus/Pomodoro (focus sessions,
daily goal, streaks, stats, the countdown next to the icon during focus) and
the auto-updater (tier 4, deferred). Skip `FocusSession`, `FocusHistory`,
`advanceFocus`, `startFocus` etc. entirely — do not stub them.

**The one thing not to re-break** before touching grayscale: never write
`ColorFiltering\Active`; press Win+Ctrl+C and read `Active` back. Tests must
never touch the real display, registry, or taskbar.

Runtime: `.venv\Scripts\python.exe` (Python 3.14, tkinter available). Test
command: `.venv\Scripts\python.exe -W error -m unittest discover -p "test_*.py"`.

## Modules (each owned by one builder)

| File | Owner | What |
|---|---|---|
| `eink_core.py` | core | Port of EinkCore minus Focus: `Schedule`, `Configuration`, `RuntimeState`, `Session`, `Store`, `Controller`, `ScheduleStatus`, `countdown()`, `Preferences`. Pure Python, stdlib only, no `winreg`/`ctypes` at import. |
| `eink_sim.py` | core | `SimulatedSystem` adapter persisted to `<home>/simulated-system.json` (for `EINK_SIMULATED=1` and process-level tests) + in-memory `FakeSystem` for unit tests. |
| `eink_cli.py` | core | `eink` CLI with the macOS surface (below). |
| `eink_win.py` | windows | `WindowsSystem` adapter: grayscale, brightness, taskbar, transparency, motion. |
| `eink_tray.py` | tray | Rewrite of the tray on top of the core. |
| `eink_ui.py` | ui | tkinter Settings window + Welcome guide, launched as a **separate process** by the tray. |

## Shared contract

### Paths
- Home dir: `%LOCALAPPDATA%\eink\` unless `EINK_HOME` is set.
- `config.json` (Configuration), `state.json` (RuntimeState), `preferences.json` (Preferences), `lock` (file lock), `eink.log` (rotating log).
- `Store.locked()` must be a real cross-process exclusive lock (`msvcrt.locking` on the `lock` file, blocking with retry). Writes are atomic (temp file + `os.replace`). Unreadable JSON raises `EinkError` ("Preserve this file for recovery"), same as macOS.

### Setting values (adapter ⇄ core)
`SystemAdapter` protocol:
```python
def snapshot(self) -> Snapshot            # Snapshot(values: dict[str, Value], warnings: list[str])
def set(self, key: str, value: Value) -> None   # raises on failure
```
`Value` is JSON-serialisable: `bool` (flags), `float` (levels 0.0–1.0), or `dict` (opaque exact-restore token).

Keys (a key missing from `snapshot().values` means "this machine cannot control it"; the core skips it, like macOS):
- `"grayscale"` — snapshot returns a **dict** `{"active": bool, "filterType": int}` (the exact OS filter state, so P1 restores e.g. an Inverted filter). `set` accepts `True` (FilterType 0 + on), `False` (filter off), or that dict (exact restore). The core only ever *sends* bools or the captured original.
- `"brightness:<id>"` — float 0.0–1.0, one key per WMI-controllable display. Config brightness is a fraction 0.05–1.0 like macOS; the adapter converts to percent.
- `"dock"` — bool, taskbar auto-hide (name kept identical to macOS so the core ports line for line).
- `"transparency"` — bool, True = *reduce* transparency (i.e. `EnableTransparency=0`).
- `"motion"` — bool, True = *reduce* motion (animations off).

`Controller.desired()` compares the grayscale target as a bool; when checking "is grayscale on" from a snapshot use `v["active"] and v["filterType"] == 0` via a helper `grayscale_on(value)` exported from `eink_core`.

### Configuration (config.json) — same keys as macOS minus `focus`
`grayscale=True, brightness=None, hideDock=False, reduceMotion=False, reduceTransparency=False, schedule={enabled:False,on:1260,off:420}`. Missing keys take defaults. `validate()` as macOS.

### RuntimeState (state.json)
`session{started, original, managed, phase}`, `manualUntilBoundary`, `lastBoundary`, `colorUntil`. Datetimes as ISO-8601 with UTC offset. No `focus`.

### Controller API (P8 — every surface calls only these)
`status()`, `set_mode(active, manual=True, profile=None, now=None)`, `toggle(now=None)`, `shutdown(resume_schedule_on_launch, now=None)`, `update(config)`, `edit(fn)`, `tick(now=None)`, `resume(now=None)`, `start_temporary_color(seconds=300, now=None)`, `end_temporary_color(now=None)`. Semantics identical to `Controller.swift` with focus branches removed. Accept an injectable clock/timezone so DST tests port.

### Preferences (preferences.json) — UI-only, not part of Configuration (macOS keeps these in UserDefaults)
```json
{"clickToSwitch": false, "shortcut": "ctrl-shift-e", "welcomeShown": false,
 "launchAtLogin": false, "wildcat": false}
```
`shortcut` ∈ `ctrl-shift-e` (default, PRD §7), `ctrl-alt-shift-e`, `ctrl-alt-e`, `ctrl-alt-shift-g`, `none`. Helpers `load_preferences()` / `save_preference(key, value)` in `eink_core` (validated, atomic, under the store lock).

### CLI (`eink_cli.py`) — mirrors macOS `eink`
```
status | on | off | toggle | version
color [minutes]        # temporary color (default 5)
grayscale              # end temporary color now
set grayscale|dock|motion|transparency on|off
set brightness 5..100|unchanged
set schedule evening|on|off
set schedule-on|schedule-off HH:MM
```
Exit 0 on success, 1 with a one-line stderr message on error. `status` prints JSON. `EINK_SIMULATED=1` swaps in `SimulatedSystem`.

### Legacy migration
The v0 tray kept a capture at `%LOCALAPPDATA%\eink\tray-grayscale.json` and prefs in a `config.json` beside the old `eink.ps1` script (`click_action`, `exit_action`) — `ROOT / "config.json"` in `eink_tray.py`, where `ROOT` is always wherever the script/exe actually runs from. On tray start: if `tray-grayscale.json` exists and there is no session, restore that filter capture (same algorithm as v0 `Controller.off`) and delete it; map `click_action == "toggle"` → `clickToSwitch: true` once. `eink.ps1` itself is v0 legacy and is not part of this repo.

## Phase 2 contract — tray ⇄ UI

Phase 1 is done and reviewed: `eink_core.py`, `eink_sim.py`, `eink_cli.py`,
`eink_win.py` exist with tests. Read their public API; do not edit them (report
anything you need changed instead).

### Process model
- `eink_tray.py` is the resident process (pystray). It owns: the icon, the
  menu, the 1-second tick, the global hotkey, session-end restore, crash
  recovery, legacy migration. Keep the v0 mutex name `Local\EinkMode.Grayscale.v1`
  so the old v0 tray and the new one can never run together.
- `eink_ui.py` is launched by the tray as a **separate process**:
  `pythonw eink_ui.py settings [--tab general|appearance|schedule]` and
  `pythonw eink_ui.py welcome`. One window of each kind at a time (its own named
  mutex; a second launch brings the existing window forward or just exits).
  It talks to the system only through `eink_core.Controller` / preferences
  helpers, under the shared store lock. It never presses keys itself except via
  the Controller (e.g. the welcome preview).
- The tray notices every change the UI makes by re-reading `config.json`,
  `state.json`, `preferences.json` on its tick. **The tray must not call
  `Controller.status()` every second** (that snapshots WMI/registry); read
  `state.json`/`config.json` via the Store for the icon, and call
  `Controller.tick()` (which only touches the system on a transition).

### `tray-status.json` (written by the tray, read by the UI)
`{"pid": int, "hotkey": "<shortcut id>", "hotkeyMessage": "<sentence>", "updated": iso}` —
`hotkeyMessage` mirrors macOS wording: "Ctrl+Shift+E switches E-Ink Mode from
any app." or "Ctrl+Shift+E is already taken by another app. Choose a different
shortcut." or "No keyboard shortcut. Use the tray icon." The UI shows it under
the shortcut picker and refreshes it ~1 s after a change.

### Shortcut ids → keys
`ctrl-shift-e` Ctrl+Shift+E · `ctrl-alt-shift-e` Ctrl+Alt+Shift+E ·
`ctrl-alt-e` Ctrl+Alt+E · `ctrl-alt-shift-g` Ctrl+Alt+Shift+G · `none`.

### Launch at login
Owned by `eink_ui.py`: HKCU `Software\Microsoft\Windows\CurrentVersion\Run`
value `EInkMode` = `"<venv pythonw.exe>" "<abs path>\eink_tray.py"`. The
checkbox reflects the Run value, not just the preference.
