"""eink_ui.py -- tkinter Settings window + Welcome guide for E-Ink Mode (Windows).

Launched by the tray as a **separate process** (PARITY-SPEC.md, "Phase 2
contract -- tray <-> UI"):

    pythonw eink_ui.py settings [--tab general|appearance|schedule]
    pythonw eink_ui.py welcome

Every change this UI makes goes through `eink_core.Controller.edit`/`set_mode`
or the `eink_core` preferences helpers -- never straight at the registry or
WMI -- so it applies live while E-Ink Mode is on and the tray picks it up on
its next tick by re-reading `config.json`/`state.json`/`preferences.json`.
`EINK_SIMULATED=1` swaps in `eink_sim.SimulatedSystem`; otherwise
`eink_win.WindowsSystem` is used.

The module is split into two halves so the logic stays testable without a
display (see `test_eink_ui.py`):

  * Pure functions / small dataclasses (view-models) that never touch Tk,
    the registry, or the clock unless it is injected. These are listed first.
  * Tk classes (`SettingsWindow`, `WelcomeWindow`) that wire those pure
    functions to widgets. Importing this module never creates a Tk window --
    only calling `main()` (or constructing `tk.Tk()` yourself) does.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import math
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from eink_core import (
    Configuration,
    Controller,
    EinkError,
    RuntimeState,
    Schedule,
    ScheduleStatus,
    Store,
    SHORTCUT_CHOICES,
    home_dir,
    load_preferences,
    local_zone,
    save_preference,
)
from eink_cli import VERSION as CLI_VERSION
from eink_paths import is_frozen, pythonw_executable, run_key_command, ui_argv

ROOT_DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# Palette (make_icon.py, PRD 9.4) and window titles/mutex names.
# ---------------------------------------------------------------------------

PAPER = "#F4F1E8"
INK = "#181817"
MUTED_LIGHT = "#6B6B66"
MUTED_DARK = "#A6A69E"
PAPER_HOVER = "#E4DFD0"   # one step deeper paper: where the pointer is
INK_HOVER = "#2C2C2A"
FONT_FAMILY = "Segoe UI"
FONT_SIZE = 10

SETTINGS_TITLE = "E-Ink Mode Settings"
WELCOME_TITLE = "Welcome to E-Ink Mode"
SETTINGS_MUTEX = "Local\\EinkMode.UI.Settings.v1"
WELCOME_MUTEX = "Local\\EinkMode.UI.Welcome.v1"

SETTINGS_TABS = ("general", "appearance", "schedule")

FALLBACK_HOTKEY_MESSAGE = "The tray isn't running, so the shortcut isn't active."

WILDCAT_DISCLAIMER = (
    "The wildcat is original artwork in the spirit of the Northwestern "
    "Wildcats. It isn't the official Willie the Wildcat mascot."
)


# ===========================================================================
# Pure view-model helpers -- no Tk, no registry, no real clock unless passed.
# ===========================================================================

# -- Keyboard shortcut presets (PARITY-SPEC "Shortcut ids -> keys") ---------

SHORTCUT_ORDER = list(SHORTCUT_CHOICES)
SHORTCUT_LABELS = {
    "ctrl-shift-e": "Ctrl+Shift+E",
    "ctrl-alt-shift-e": "Ctrl+Alt+Shift+E",
    "ctrl-alt-e": "Ctrl+Alt+E",
    "ctrl-alt-shift-g": "Ctrl+Alt+Shift+G",
    "none": "None",
}


def shortcut_label(shortcut_id: str) -> str:
    return SHORTCUT_LABELS.get(shortcut_id, shortcut_id)


def shortcut_choices() -> list[tuple[str, str]]:
    """[(id, label), ...] in the order the picker should list them."""
    return [(sid, shortcut_label(sid)) for sid in SHORTCUT_ORDER]


def shortcut_id_for_label(label: str) -> str | None:
    for sid, text in shortcut_choices():
        if text == label:
            return sid
    return None


# -- Schedule choice <-> Configuration (SettingsView.swift ScheduleChoice) --

SCHEDULE_OFF = "off"
SCHEDULE_EVENING = "evening"
SCHEDULE_CUSTOM = "custom"


def schedule_choice(schedule: Schedule) -> str:
    if not schedule.enabled:
        return SCHEDULE_OFF
    return SCHEDULE_EVENING if schedule.is_evening else SCHEDULE_CUSTOM


def apply_schedule_choice(config: Configuration, choice: str) -> None:
    """Mutates `config.schedule` for a radio pick. Picking "custom" only
    turns the schedule on -- the caller still has to save specific times
    (mac's ScheduleSettings.select(.custom) just calls `sync()`, no save)."""
    if choice == SCHEDULE_OFF:
        config.schedule.enabled = False
    elif choice == SCHEDULE_EVENING:
        config.schedule = Schedule.evening()
        config.schedule.enabled = True
    elif choice == SCHEDULE_CUSTOM:
        config.schedule.enabled = True
    else:
        raise ValueError(f"unknown schedule choice: {choice!r}")


def custom_schedule_dirty(schedule: Schedule, on_minutes: int, off_minutes: int) -> bool:
    """True when the on-screen custom times differ from the saved schedule
    (mac's ScheduleSettings.dirty) -- gates the Save button."""
    return not schedule.enabled or on_minutes != schedule.on or off_minutes != schedule.off


# -- Time-field validation (wraps Schedule.parse/validate) ------------------

@dataclass
class TimeValidation:
    minutes: int | None
    error: str | None

    @property
    def ok(self) -> bool:
        return self.error is None


def validate_time_field(hour: int, minute: int) -> TimeValidation:
    try:
        minutes = Schedule.parse(f"{hour}:{minute}")
    except EinkError as error:
        return TimeValidation(None, str(error))
    return TimeValidation(minutes, None)


def validate_schedule_times(on_minutes: int, off_minutes: int) -> str | None:
    """None if `on_minutes`/`off_minutes` make a valid schedule, else the
    one-line message to show inline."""
    try:
        Schedule(enabled=True, on=on_minutes, off=off_minutes).validate()
    except EinkError as error:
        return str(error)
    return None


# -- Preview state machine (AppModel.startPreview/endPreview parity) -------

class PreviewState:
    """Drives "Preview Grayscale for 10 Seconds". Takes an injectable clock
    (a zero-arg callable returning monotonically increasing seconds) so
    tests never sleep for real."""

    def __init__(self, duration: float = 10.0, clock=None):
        self.duration = duration
        self._clock = clock or time.monotonic
        self._deadline: float | None = None

    @property
    def running(self) -> bool:
        return self._deadline is not None

    def start(self, active: bool) -> bool:
        """Starts the preview; returns False (refuses) if E-Ink Mode is
        already on or a preview is already running."""
        if active or self.running:
            return False
        self._deadline = self._clock() + self.duration
        return True

    def remaining(self) -> int:
        """Whole seconds left, never negative."""
        if self._deadline is None:
            return 0
        return max(0, math.ceil(self._deadline - self._clock()))

    def expired(self) -> bool:
        return self.running and self._clock() >= self._deadline

    def end(self) -> None:
        self._deadline = None


# -- Welcome-guide config changes (OnboardingView.save parity) --------------

def welcome_config_change(dim: bool, brightness_percent: float, hide_taskbar: bool):
    """Returns a `Controller.edit`-shaped `change(config)` callable."""

    def change(config: Configuration) -> None:
        config.grayscale = True
        config.brightness = (brightness_percent / 100) if dim else None
        config.hideDock = hide_taskbar

    return change


# -- Login-at-login (HKCU Run key) ------------------------------------------

RUN_KEY_PATH = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME = "EInkMode"


def build_run_command(pythonw_path: str, tray_script: str) -> str:
    return f'"{pythonw_path}" "{tray_script}"'


def default_run_command(root_dir: Path | None = None) -> str:
    """The Run-key command for this install. Frozen, this is `EInkMode.exe`'s
    own path (no `root_dir` involved -- the exe finds its own tray); unfrozen,
    it's pythonw + `eink_tray.py` next to `root_dir` (or this repo)."""
    if is_frozen():
        return run_key_command()
    root_dir = Path(root_dir) if root_dir is not None else ROOT_DIR
    return build_run_command(pythonw_executable(), str(root_dir / "eink_tray.py"))


def login_enabled(run_value: str | None) -> bool:
    """The checkbox reflects the actual Run value (PARITY-SPEC), not just a
    preference: any non-empty value under `EInkMode` counts as "on", even if
    it points at a different install than this one."""
    return bool(run_value)


class RunKeyAdapter:
    """Wraps HKCU ...\\Run so `SettingsWindow` never calls `winreg` directly
    and tests can substitute a fake without touching the real registry."""

    def get(self) -> str | None:
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH) as key:
                value, kind = winreg.QueryValueEx(key, RUN_VALUE_NAME)
        except OSError:
            return None
        return value if kind == winreg.REG_SZ else None

    def set(self, command: str) -> None:
        import winreg

        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH) as key:
            winreg.SetValueEx(key, RUN_VALUE_NAME, 0, winreg.REG_SZ, command)

    def delete(self) -> None:
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, winreg.KEY_SET_VALUE) as key:
                winreg.DeleteValue(key, RUN_VALUE_NAME)
        except OSError:
            pass


# -- tray-status.json (written by the tray, read here) ----------------------

def load_tray_status(home: Path) -> dict | None:
    path = Path(home) / "tray-status.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def hotkey_message_from_status(data: dict | None, now: datetime, max_age: float = 5.0) -> str:
    """`hotkeyMessage` from a `tray-status.json` payload, or the fallback
    sentence when the tray is missing, unreadable, or its `updated`
    timestamp is stale (older, or -- clock skew aside -- newer, than
    `max_age` seconds)."""
    if not data:
        return FALLBACK_HOTKEY_MESSAGE
    updated = data.get("updated")
    if not updated:
        return FALLBACK_HOTKEY_MESSAGE
    try:
        updated_dt = datetime.fromisoformat(updated)
    except ValueError:
        return FALLBACK_HOTKEY_MESSAGE
    if updated_dt.tzinfo is None:
        updated_dt = updated_dt.replace(tzinfo=timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    age = (now - updated_dt).total_seconds()
    if abs(age) > max_age:
        return FALLBACK_HOTKEY_MESSAGE
    message = data.get("hotkeyMessage")
    return message if message else FALLBACK_HOTKEY_MESSAGE


# -- System-adapter selection (mirrors eink_cli._make_adapter) --------------

def make_adapter(home: Path):
    if os.environ.get("EINK_SIMULATED") == "1":
        from eink_sim import SimulatedSystem

        return SimulatedSystem(home / "simulated-system.json")
    from eink_win import WindowsSystem  # windows builder's module; lazy so

    return WindowsSystem()


# -- Cheap store reads (no adapter.snapshot(), so no WMI) -------------------

def read_config_state(store: Store) -> tuple[Configuration, RuntimeState]:
    """Configuration + RuntimeState without touching the system adapter --
    safe to call often (General/Schedule tabs poll this)."""
    with store.locked():
        config = Configuration.from_dict(store.read_json("config.json"))
        config.validate()
        state = RuntimeState.from_dict(store.read_json("state.json"))
    return config, state


def mode_active(store: Store) -> bool:
    with store.locked():
        return RuntimeState.from_dict(store.read_json("state.json")).session is not None


def has_brightness(values: dict) -> bool:
    return any(key.startswith("brightness:") for key in values)


# -- Windows light/dark app theme (cheap; injectable reader for tests) -----

def _read_light_theme_from_registry() -> bool:
    import winreg

    key_path = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path) as key:
        value, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
    return bool(value)


def detect_light_theme(reader=_read_light_theme_from_registry, default: bool = True) -> bool:
    try:
        return bool(reader())
    except Exception:
        return default


# ===========================================================================
# Process plumbing: DPI awareness, single instance, spawning sibling windows.
# ===========================================================================

def set_dpi_awareness() -> None:
    """Call before creating the Tk root. Best-effort: an older Windows or a
    denied call is not fatal, just blurrier on a scaled display."""
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)  # PROCESS_SYSTEM_DPI_AWARE
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


_ERROR_ALREADY_EXISTS = 183
_mutex_handles: list[tuple[ctypes.WinDLL, int]] = []  # kept alive for the process


def acquire_singleton(mutex_name: str) -> bool:
    """True if this process holds `mutex_name` (i.e. should proceed);
    False if another process already holds it."""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    handle = kernel32.CreateMutexW(None, False, mutex_name)
    if not handle:
        return True  # fail open -- better to show a window than to block the user
    if ctypes.get_last_error() == _ERROR_ALREADY_EXISTS:
        kernel32.CloseHandle(handle)
        return False
    _mutex_handles.append((kernel32, handle))
    return True


def bring_window_forward(title: str) -> None:
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    hwnd = user32.FindWindowW(None, title)
    if hwnd:
        SW_RESTORE = 9
        user32.ShowWindow(hwnd, SW_RESTORE)
        user32.SetForegroundWindow(hwnd)


def spawn_window(kind: str, tab: str | None = None) -> None:
    """Launches a sibling `eink_ui.py` window as its own process, the way
    the tray does -- used by Settings' "Show Welcome Guide" button.
    Frozen-aware via `eink_paths.ui_argv`. Inherits the current environment
    so EINK_HOME/EINK_SIMULATED (test isolation) carry through."""
    args = [kind] + (["--tab", tab] if tab else [])
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    subprocess.Popen(ui_argv(*args), env=os.environ.copy(), creationflags=creationflags)


# ===========================================================================
# Tk plumbing shared by both windows.
# ===========================================================================

class AsyncRunner:
    """Runs a blocking call (a Controller operation, which may touch the
    registry or WMI) off the Tk main thread, then delivers the result back
    on the main thread via a queue polled by `Tk.after` -- widgets are only
    ever touched from the main thread."""

    def __init__(self, widget: tk.Misc, interval_ms: int = 50):
        self._widget = widget
        self._interval_ms = interval_ms
        self._queue: "queue.Queue" = queue.Queue()
        self._poll()

    def run(self, fn, on_done=None, on_error=None) -> None:
        def worker():
            try:
                result = fn()
            except Exception as exc:  # noqa: BLE001 - surfaced to on_error
                self._queue.put(("error", exc, on_error))
            else:
                self._queue.put(("done", result, on_done))

        threading.Thread(target=worker, daemon=True).start()

    def _poll(self) -> None:
        try:
            while True:
                _kind, payload, callback = self._queue.get_nowait()
                if callback is not None:
                    callback(payload)
        except queue.Empty:
            pass
        try:
            self._widget.after(self._interval_ms, self._poll)
        except tk.TclError:
            pass  # widget destroyed -- stop polling


def apply_theme(root: tk.Tk, light: bool | None = None) -> dict:
    """Configures ttk styles for the paper/ink palette. Returns the resolved
    {bg, fg, muted} colors for widgets built outside ttk's style system.

    E-ink styled: ink on paper whatever the Windows app theme, flat 1px ink
    rules, no bevels. Every interactive state is spelled out, because `clam`'s
    own hover and pressed colours are light grey, which left pale text on a
    pale background the moment the pointer landed on an option. Hover
    deepens the paper one step for options and inverts buttons to paper on
    ink, the way an e-reader highlights a selection."""
    if light is None:
        light = True
    bg, fg = (PAPER, INK) if light else (INK, PAPER)
    muted = MUTED_LIGHT if light else MUTED_DARK
    hover = PAPER_HOVER if light else INK_HOVER
    root.configure(bg=bg)
    root.option_add("*Font", f"{{{FONT_FAMILY}}} {FONT_SIZE}")
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    base_font = (FONT_FAMILY, FONT_SIZE)
    style.configure(".", background=bg, foreground=fg, font=base_font)
    for name in ("TFrame", "TLabelframe", "TNotebook", "TCheckbutton", "TRadiobutton", "TLabel"):
        style.configure(name, background=bg, foreground=fg)
    style.configure("TLabelframe.Label", background=bg, foreground=fg, font=(FONT_FAMILY, FONT_SIZE, "bold"))
    style.configure("TNotebook.Tab", background=bg, foreground=fg, padding=(12, 6))
    style.map("TNotebook.Tab", background=[("selected", bg)], foreground=[("selected", fg)])
    style.configure("Hint.TLabel", background=bg, foreground=muted, font=(FONT_FAMILY, 9))
    style.configure("Error.TLabel", background=bg, foreground=fg, font=(FONT_FAMILY, 9, "bold"))
    style.configure("Heading.TLabel", background=bg, foreground=fg, font=(FONT_FAMILY, 13, "bold"))
    style.configure("Step.TLabel", background=bg, foreground=fg, font=(FONT_FAMILY, 10, "bold"))
    # Flat ink rules instead of clam's bevels, everywhere.
    style.configure(".", bordercolor=fg, lightcolor=bg, darkcolor=bg, focuscolor=fg,
                    troughcolor=hover, selectbackground=fg, selectforeground=bg)
    style.configure("TLabelframe", bordercolor=fg)
    style.configure("TNotebook", bordercolor=fg)
    style.map("TNotebook.Tab", background=[("selected", bg), ("active", hover)],
              foreground=[("selected", fg), ("active", fg)])

    style.configure("TButton", background=bg, foreground=fg, bordercolor=fg, padding=(10, 4))
    style.map("TButton",
              background=[("disabled", bg), ("pressed", fg), ("active", fg)],
              foreground=[("disabled", muted), ("pressed", bg), ("active", bg)],
              bordercolor=[("disabled", muted)])

    for name in ("TCheckbutton", "TRadiobutton"):
        style.configure(name, background=bg, foreground=fg,
                        indicatorbackground=bg, indicatorforeground=fg,
                        upperbordercolor=fg, lowerbordercolor=fg)
        style.map(name,
                  background=[("disabled", bg), ("active", hover)],
                  foreground=[("disabled", muted), ("active", fg)],
                  indicatorbackground=[("disabled", bg), ("pressed", hover), ("active", hover)],
                  indicatorforeground=[("disabled", muted)])

    for name in ("TCombobox", "TSpinbox"):
        style.configure(name, fieldbackground=bg, background=bg, foreground=fg, arrowcolor=fg,
                        bordercolor=fg, selectbackground=bg, selectforeground=fg)
        style.map(name,
                  fieldbackground=[("readonly", bg), ("disabled", bg)],
                  background=[("disabled", bg), ("pressed", hover), ("active", hover)],
                  foreground=[("disabled", muted), ("readonly", fg)],
                  arrowcolor=[("disabled", muted)])
    style.configure("TEntry", fieldbackground=bg, foreground=fg, insertcolor=fg, bordercolor=fg)
    style.configure("Horizontal.TScale", background=bg, troughcolor=hover, bordercolor=fg)
    style.map("Horizontal.TScale", background=[("active", hover)])
    root.option_add("*TCombobox*Listbox.background", bg)
    root.option_add("*TCombobox*Listbox.foreground", fg)
    root.option_add("*TCombobox*Listbox.selectBackground", fg)
    root.option_add("*TCombobox*Listbox.selectForeground", bg)
    return {"bg": bg, "fg": fg, "muted": muted}


def hint_label(parent, text: str, **kw) -> ttk.Label:
    return ttk.Label(parent, text=text, style="Hint.TLabel", wraplength=440, justify="left", **kw)


# ===========================================================================
# Settings window
# ===========================================================================

class SettingsWindow:
    def __init__(self, root: tk.Tk, home: Path, tab: str = "general"):
        self.root = root
        self.home = Path(home)
        self.store = Store(self.home)
        self.controller = Controller(self.store, make_adapter(self.home))
        self.runner = AsyncRunner(root)
        self.run_key = RunKeyAdapter()
        self.colors = apply_theme(root)

        root.title(SETTINGS_TITLE)
        root.minsize(520, 420)
        root.protocol("WM_DELETE_WINDOW", root.destroy)
        root.bind("<Escape>", lambda _e: root.destroy())

        self.status_var = tk.StringVar(value="")
        self.notebook = ttk.Notebook(root)
        self.notebook.pack(fill="both", expand=True, padx=12, pady=(12, 4))
        ttk.Label(root, textvariable=self.status_var, style="Hint.TLabel").pack(
            fill="x", padx=16, pady=(0, 10)
        )

        self._tabs = {}
        self._build_general_tab()
        self._build_appearance_tab()
        self._build_schedule_tab()
        for name in SETTINGS_TABS:
            self.notebook.add(self._tabs[name]["frame"], text=name.capitalize())
        self.select_tab(tab)

        self._load_appearance_snapshot()
        self._schedule_general_poll()
        self._refresh_schedule()

    def select_tab(self, tab: str) -> None:
        if tab in self._tabs:
            self.notebook.select(self._tabs[tab]["frame"])

    def _set_status(self, message: str) -> None:
        self.status_var.set(message)

    # -- General ------------------------------------------------------------

    def _build_general_tab(self) -> None:
        frame = ttk.Frame(self.root, padding=16)
        self._tabs["general"] = {"frame": frame}

        icon_box = ttk.Labelframe(frame, text="Tray icon", padding=10)
        icon_box.pack(fill="x", pady=(0, 12))
        self.click_var = tk.BooleanVar(value=False)
        ttk.Radiobutton(icon_box, text="Click opens the menu", variable=self.click_var,
                        value=False, command=self._on_click_changed).pack(anchor="w")
        ttk.Radiobutton(icon_box, text="Click switches E-Ink Mode", variable=self.click_var,
                        value=True, command=self._on_click_changed).pack(anchor="w")
        self.wildcat_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(icon_box, text="Wildcat mode", variable=self.wildcat_var,
                        command=self._on_wildcat_changed).pack(anchor="w", pady=(8, 0))
        hint_label(icon_box, WILDCAT_DISCLAIMER).pack(anchor="w", pady=(2, 0))

        shortcut_box = ttk.Labelframe(frame, text="Keyboard shortcut", padding=10)
        shortcut_box.pack(fill="x", pady=(0, 12))
        row = ttk.Frame(shortcut_box)
        row.pack(fill="x")
        ttk.Label(row, text="Switch on and off").pack(side="left")
        self.shortcut_var = tk.StringVar()
        self.shortcut_combo = ttk.Combobox(row, textvariable=self.shortcut_var, state="readonly",
                                           values=[label for _sid, label in shortcut_choices()], width=20)
        self.shortcut_combo.pack(side="right")
        self.shortcut_combo.bind("<<ComboboxSelected>>", self._on_shortcut_changed)
        self.hotkey_message_var = tk.StringVar(value="")
        hint_label(shortcut_box, "").pack(anchor="w", pady=(6, 0))
        shortcut_box.winfo_children()[-1].configure(textvariable=self.hotkey_message_var)

        startup_box = ttk.Labelframe(frame, text="Startup", padding=10)
        startup_box.pack(fill="x", pady=(0, 12))
        self.login_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(startup_box, text="Open E-Ink Mode at login", variable=self.login_var,
                        command=self._on_login_changed).pack(anchor="w")
        hint_label(startup_box, "Needed for schedules. Opening the app never turns E-Ink Mode on by itself.").pack(
            anchor="w", pady=(2, 0)
        )

        about_box = ttk.Labelframe(frame, text="About", padding=10)
        about_box.pack(fill="x", pady=(0, 12))
        ttk.Label(about_box, text=f"Version {CLI_VERSION}").pack(anchor="w")

        help_box = ttk.Labelframe(frame, text="Help", padding=10)
        help_box.pack(fill="x")
        buttons = ttk.Frame(help_box)
        buttons.pack(fill="x")
        ttk.Button(buttons, text="Show Welcome Guide", command=self._on_show_welcome).pack(side="left")
        self.restore_button = ttk.Button(buttons, text="Restore Display Now", command=self._on_restore_display)
        self.restore_button.pack(side="left", padx=(8, 0))

    def _refresh_general(self) -> None:
        prefs = load_preferences(home=self.home)
        self.click_var.set(prefs.clickToSwitch)
        self.wildcat_var.set(prefs.wildcat)
        self.shortcut_var.set(shortcut_label(prefs.shortcut))
        self.login_var.set(login_enabled(self.run_key.get()))
        self._refresh_hotkey_message()
        self.restore_button.configure(state=("normal" if mode_active(self.store) else "disabled"))

    def _refresh_hotkey_message(self) -> None:
        status = load_tray_status(self.home)
        now = datetime.now(timezone.utc)
        self.hotkey_message_var.set(hotkey_message_from_status(status, now))

    def _schedule_general_poll(self) -> None:
        self._refresh_general()
        self.root.after(2000, self._schedule_general_poll)

    def _on_click_changed(self) -> None:
        try:
            save_preference("clickToSwitch", self.click_var.get(), home=self.home)
        except EinkError as error:
            self._set_status(str(error))

    def _on_wildcat_changed(self) -> None:
        try:
            save_preference("wildcat", self.wildcat_var.get(), home=self.home)
        except EinkError as error:
            self._set_status(str(error))

    def _on_shortcut_changed(self, _event=None) -> None:
        shortcut_id = shortcut_id_for_label(self.shortcut_var.get())
        if shortcut_id is None:
            return
        try:
            save_preference("shortcut", shortcut_id, home=self.home)
        except EinkError as error:
            self._set_status(str(error))
        self.root.after(1000, self._refresh_hotkey_message)

    def _on_login_changed(self) -> None:
        try:
            if self.login_var.get():
                self.run_key.set(default_run_command())
            else:
                self.run_key.delete()
            save_preference("launchAtLogin", self.login_var.get(), home=self.home)
        except (OSError, EinkError) as error:
            self._set_status(str(error))
            self.login_var.set(login_enabled(self.run_key.get()))

    def _on_show_welcome(self) -> None:
        spawn_window("welcome")

    def _on_restore_display(self) -> None:
        self.restore_button.configure(state="disabled")

        def work():
            self.controller.set_mode(False)

        self.runner.run(work, on_done=lambda _r: self._refresh_general(),
                        on_error=lambda exc: self._set_status(str(exc)))

    # -- Appearance -----------------------------------------------------------

    def _build_appearance_tab(self) -> None:
        frame = ttk.Frame(self.root, padding=16)
        self._tabs["appearance"] = {"frame": frame}
        self.appearance_loading = ttk.Label(frame, text="Reading what this PC supports…")
        self.appearance_loading.pack(anchor="w")
        self.appearance_body = None  # built once the snapshot arrives

    def _load_appearance_snapshot(self) -> None:
        self.runner.run(self.controller.status, on_done=self._on_appearance_status,
                        on_error=self._on_appearance_error)

    def _on_appearance_error(self, exc: Exception) -> None:
        self.appearance_loading.configure(text=f"Couldn't read the system: {exc}")

    def _on_appearance_status(self, status) -> None:
        self.appearance_loading.pack_forget()
        frame = self._tabs["appearance"]["frame"]
        if self.appearance_body is not None:
            self.appearance_body.destroy()
        body = ttk.Frame(frame)
        body.pack(fill="both", expand=True)
        self.appearance_body = body
        self._appearance_values = dict(status.system.values)
        config = status.configuration

        core_box = ttk.Labelframe(body, text="Grayscale", padding=10)
        core_box.pack(fill="x", pady=(0, 12))
        self.grayscale_var = tk.BooleanVar(value=config.grayscale)
        grayscale_available = "grayscale" in self._appearance_values
        ttk.Checkbutton(core_box, text="Grayscale", variable=self.grayscale_var,
                        state=("normal" if grayscale_available else "disabled"),
                        command=self._on_grayscale_changed).pack(anchor="w")
        hint_label(core_box, "The core of E-Ink Mode. Use “Color for 5 Minutes” in the "
                             "tray menu for a quick look at color.").pack(anchor="w", pady=(2, 0))

        opt_box = ttk.Labelframe(body, text="Optional — off unless you turn them on", padding=10)
        opt_box.pack(fill="x", pady=(0, 12))

        self.dim_var = tk.BooleanVar(value=config.brightness is not None)
        self.brightness_var = tk.DoubleVar(value=(config.brightness or 0.5) * 100)
        has_bright = has_brightness(self._appearance_values)
        dim_row = ttk.Frame(opt_box)
        dim_row.pack(fill="x")
        ttk.Checkbutton(dim_row, text="Dim the screen", variable=self.dim_var,
                        state=("normal" if has_bright else "disabled"),
                        command=self._on_dim_toggled).pack(side="left")
        self.brightness_pct_label = ttk.Label(dim_row, text=f"{int(self.brightness_var.get())}%")
        self.brightness_pct_label.pack(side="right")
        self.brightness_scale = ttk.Scale(opt_box, from_=5, to=100, orient="horizontal",
                                          variable=self.brightness_var, command=self._on_brightness_move)
        self.brightness_scale.pack(fill="x", pady=(4, 0))
        self.brightness_scale.bind("<ButtonRelease-1>", self._on_brightness_release)
        self._brightness_after_id = None
        hint_label(opt_box, "Your current brightness is saved and put back when E-Ink Mode "
                            "turns off." if has_bright else
                            "This display doesn't let Windows control its brightness. Use the "
                            "monitor's own buttons.").pack(anchor="w", pady=(2, 8))
        self._update_brightness_state()

        self.taskbar_var = tk.BooleanVar(value=config.hideDock)
        taskbar_ok = "dock" in self._appearance_values
        ttk.Checkbutton(opt_box, text="Auto-hide the taskbar", variable=self.taskbar_var,
                        state=("normal" if taskbar_ok else "disabled"),
                        command=self._on_taskbar_changed).pack(anchor="w")

        self.motion_var = tk.BooleanVar(value=config.reduceMotion)
        motion_ok = "motion" in self._appearance_values
        ttk.Checkbutton(opt_box, text="Reduce motion", variable=self.motion_var,
                        state=("normal" if motion_ok else "disabled"),
                        command=self._on_motion_changed).pack(anchor="w", pady=(6, 0))

        self.transparency_var = tk.BooleanVar(value=config.reduceTransparency)
        transparency_ok = "transparency" in self._appearance_values
        ttk.Checkbutton(opt_box, text="Reduce transparency", variable=self.transparency_var,
                        state=("normal" if transparency_ok else "disabled"),
                        command=self._on_transparency_changed).pack(anchor="w", pady=(6, 0))

        hint_label(opt_box, "Changes apply immediately while E-Ink Mode is on. Everything "
                            "returns to how it was when you turn it off.").pack(anchor="w", pady=(8, 0))

        if status.system.warnings:
            warn_box = ttk.Labelframe(body, text="What this PC supports", padding=10)
            warn_box.pack(fill="x")
            for warning in status.system.warnings:
                hint_label(warn_box, warning).pack(anchor="w", pady=(0, 4))

    def _update_brightness_state(self) -> None:
        state = "normal" if (self.dim_var.get() and has_brightness(self._appearance_values)) else "disabled"
        self.brightness_scale.configure(state=state)

    def _edit(self, change, on_done=None) -> None:
        def work():
            self.controller.edit(change)

        self.runner.run(work, on_done=on_done, on_error=lambda exc: self._set_status(str(exc)))

    def _on_grayscale_changed(self) -> None:
        value = self.grayscale_var.get()
        self._edit(lambda config: setattr(config, "grayscale", value))

    def _on_dim_toggled(self) -> None:
        self._update_brightness_state()
        dim = self.dim_var.get()
        percent = self.brightness_var.get()
        self._edit(lambda config: setattr(config, "brightness", (percent / 100) if dim else None))

    def _on_brightness_move(self, _value) -> None:
        self.brightness_pct_label.configure(text=f"{int(round(self.brightness_var.get()))}%")
        if self._brightness_after_id is not None:
            self.root.after_cancel(self._brightness_after_id)
        self._brightness_after_id = self.root.after(300, self._commit_brightness)

    def _on_brightness_release(self, _event) -> None:
        if self._brightness_after_id is not None:
            self.root.after_cancel(self._brightness_after_id)
            self._brightness_after_id = None
        self._commit_brightness()

    def _commit_brightness(self) -> None:
        self._brightness_after_id = None
        if not self.dim_var.get():
            return
        percent = self.brightness_var.get()
        self._edit(lambda config: setattr(config, "brightness", percent / 100))

    def _on_taskbar_changed(self) -> None:
        value = self.taskbar_var.get()
        self._edit(lambda config: setattr(config, "hideDock", value))

    def _on_motion_changed(self) -> None:
        value = self.motion_var.get()
        self._edit(lambda config: setattr(config, "reduceMotion", value))

    def _on_transparency_changed(self) -> None:
        value = self.transparency_var.get()
        self._edit(lambda config: setattr(config, "reduceTransparency", value))

    # -- Schedule -------------------------------------------------------------

    def _build_schedule_tab(self) -> None:
        frame = ttk.Frame(self.root, padding=16)
        self._tabs["schedule"] = {"frame": frame}

        auto_box = ttk.Labelframe(frame, text="Automatically", padding=10)
        auto_box.pack(fill="x", pady=(0, 12))
        self.schedule_choice_var = tk.StringVar(value=SCHEDULE_OFF)
        ttk.Radiobutton(auto_box, text="Never — I'll switch it myself", variable=self.schedule_choice_var,
                        value=SCHEDULE_OFF, command=self._on_schedule_choice).pack(anchor="w")
        ttk.Radiobutton(auto_box, text="Evening · 9:00 PM to 7:00 AM", variable=self.schedule_choice_var,
                        value=SCHEDULE_EVENING, command=self._on_schedule_choice).pack(anchor="w")
        ttk.Radiobutton(auto_box, text="Custom times", variable=self.schedule_choice_var,
                        value=SCHEDULE_CUSTOM, command=self._on_schedule_choice).pack(anchor="w")

        self.custom_frame = ttk.Frame(auto_box)
        self.custom_frame.pack(fill="x", pady=(8, 0))
        hours = [f"{h:02d}" for h in range(24)]
        minutes = [f"{m:02d}" for m in range(60)]

        def time_row(label_text, hour_var, minute_var):
            row = ttk.Frame(self.custom_frame)
            row.pack(fill="x", pady=2)
            ttk.Label(row, text=label_text).pack(side="left")
            # Packed into their own left-to-right sub-frame (rather than
            # `side="right"` on the row directly) so hour/colon/minute land
            # in reading order -- same-side packing stacks in *reverse* of
            # call order, which is the bug that swapped them originally.
            picker = ttk.Frame(row)
            picker.pack(side="right")
            ttk.Spinbox(picker, values=hours, textvariable=hour_var, width=3, state="readonly",
                       wrap=True, command=self._on_time_field_changed).pack(side="left")
            ttk.Label(picker, text=":").pack(side="left", padx=2)
            ttk.Spinbox(picker, values=minutes, textvariable=minute_var, width=3, state="readonly",
                       wrap=True, command=self._on_time_field_changed).pack(side="left")

        self.on_hour_var = tk.StringVar(value="21")
        self.on_minute_var = tk.StringVar(value="00")
        time_row("Turn on at", self.on_hour_var, self.on_minute_var)

        self.off_hour_var = tk.StringVar(value="07")
        self.off_minute_var = tk.StringVar(value="00")
        time_row("Turn off at", self.off_hour_var, self.off_minute_var)

        self.schedule_error_var = tk.StringVar(value="")
        ttk.Label(self.custom_frame, textvariable=self.schedule_error_var, style="Error.TLabel",
                 wraplength=440, justify="left").pack(anchor="w", pady=(4, 0))

        button_row = ttk.Frame(self.custom_frame)
        button_row.pack(fill="x", pady=(4, 0))
        self.schedule_save_button = ttk.Button(button_row, text="Use These Times",
                                               command=self._on_schedule_save)
        self.schedule_save_button.pack(side="left")
        ttk.Button(button_row, text="Revert", command=self._sync_schedule_fields).pack(side="left", padx=(8, 0))
        for var in (self.on_hour_var, self.on_minute_var, self.off_hour_var, self.off_minute_var):
            var.trace_add("write", lambda *_a: self._on_time_field_changed())

        next_box = ttk.Labelframe(frame, text="What happens next", padding=10)
        next_box.pack(fill="x", pady=(0, 12))
        self.schedule_short_var = tk.StringVar(value="")
        ttk.Label(next_box, textvariable=self.schedule_short_var, font=(FONT_FAMILY, FONT_SIZE, "bold")).pack(
            anchor="w"
        )
        self.schedule_detail_var = tk.StringVar(value="")
        hint_label(next_box, "").pack(anchor="w", pady=(4, 0))
        next_box.winfo_children()[-1].configure(textvariable=self.schedule_detail_var)

        good_box = ttk.Labelframe(frame, text="Good to know", padding=10)
        good_box.pack(fill="x")
        hint_label(good_box, "Switching by hand always wins: the schedule waits until its "
                             "next change before taking over again.").pack(anchor="w")
        hint_label(good_box, "The schedule runs while the tray is open. Turn on “Open "
                             "E-Ink Mode at login” so it works every day.").pack(anchor="w", pady=(4, 0))

    def _current_config_state(self) -> tuple[Configuration, RuntimeState]:
        return read_config_state(self.store)

    def _refresh_schedule(self) -> None:
        config, state = self._current_config_state()
        choice = schedule_choice(config.schedule)
        # Don't clobber an in-progress custom edit.
        if not self._schedule_dirty():
            self.schedule_choice_var.set(choice)
        self._update_custom_visibility()
        if choice == SCHEDULE_CUSTOM and not self._schedule_dirty():
            self._sync_schedule_fields(config.schedule)
        self._render_schedule_status(config, state)
        self._schedule_status_after_id = self.root.after(30000, self._refresh_schedule)

    def _render_schedule_status(self, config: Configuration, state: RuntimeState) -> None:
        now = datetime.now(local_zone())
        status = ScheduleStatus(config, state, now=now, tz=local_zone())
        self.schedule_short_var.set(status.short if status.enabled else "Schedule is off")
        self.schedule_detail_var.set(status.detail)

    def _schedule_dirty(self) -> bool:
        if self.schedule_choice_var.get() != SCHEDULE_CUSTOM:
            return False
        try:
            on_minutes = int(self.on_hour_var.get()) * 60 + int(self.on_minute_var.get())
            off_minutes = int(self.off_hour_var.get()) * 60 + int(self.off_minute_var.get())
        except ValueError:
            return True
        config, _state = self._current_config_state()
        return custom_schedule_dirty(config.schedule, on_minutes, off_minutes)

    def _update_custom_visibility(self) -> None:
        if self.schedule_choice_var.get() == SCHEDULE_CUSTOM:
            self.custom_frame.pack(fill="x", pady=(8, 0))
        else:
            self.custom_frame.pack_forget()

    def _sync_schedule_fields(self, schedule: Schedule | None = None) -> None:
        if schedule is None:
            config, _state = self._current_config_state()
            schedule = config.schedule
        self.on_hour_var.set(f"{schedule.on // 60:02d}")
        self.on_minute_var.set(f"{schedule.on % 60:02d}")
        self.off_hour_var.set(f"{schedule.off // 60:02d}")
        self.off_minute_var.set(f"{schedule.off % 60:02d}")
        self.schedule_error_var.set("")

    def _on_schedule_choice(self) -> None:
        choice = self.schedule_choice_var.get()
        self._update_custom_visibility()
        if choice == SCHEDULE_CUSTOM:
            self._sync_schedule_fields()
            return
        self._edit(lambda config: apply_schedule_choice(config, choice), on_done=lambda _r: self._refresh_schedule())

    def _on_time_field_changed(self) -> None:
        try:
            on_minutes = int(self.on_hour_var.get()) * 60 + int(self.on_minute_var.get())
            off_minutes = int(self.off_hour_var.get()) * 60 + int(self.off_minute_var.get())
        except ValueError:
            self.schedule_error_var.set("Use a 24-hour time such as 21:00.")
            self.schedule_save_button.configure(state="disabled")
            return
        error = validate_schedule_times(on_minutes, off_minutes)
        self.schedule_error_var.set(error or "")
        self.schedule_save_button.configure(state=("disabled" if error else "normal"))

    def _on_schedule_save(self) -> None:
        on_minutes = int(self.on_hour_var.get()) * 60 + int(self.on_minute_var.get())
        off_minutes = int(self.off_hour_var.get()) * 60 + int(self.off_minute_var.get())
        error = validate_schedule_times(on_minutes, off_minutes)
        if error:
            self.schedule_error_var.set(error)
            return

        def change(config: Configuration) -> None:
            config.schedule.on = on_minutes
            config.schedule.off = off_minutes
            config.schedule.enabled = True

        self._edit(change, on_done=lambda _r: self._refresh_schedule())


# ===========================================================================
# Welcome guide
# ===========================================================================

class WelcomeWindow:
    def __init__(self, root: tk.Tk, home: Path):
        self.root = root
        self.home = Path(home)
        self.store = Store(self.home)
        self.controller = Controller(self.store, make_adapter(self.home))
        self.runner = AsyncRunner(root)
        self.colors = apply_theme(root)
        self.preview = PreviewState(duration=10.0)
        self._preview_after_id = None

        root.title(WELCOME_TITLE)
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self._on_window_close)
        root.bind("<Escape>", lambda _e: self._on_window_close())

        config, _state = read_config_state(self.store)
        try:
            status = self.controller.status()
            self.has_brightness = has_brightness(status.system.values)
        except EinkError:
            self.has_brightness = False

        outer = ttk.Frame(root, padding=26)
        outer.pack(fill="both", expand=True)

        header = ttk.Frame(outer)
        header.pack(fill="x", pady=(0, 14))
        ttk.Label(header, text="Welcome to E-Ink Mode", style="Heading.TLabel").pack(anchor="w")
        ttk.Label(header, text=f"Version {CLI_VERSION}", style="Hint.TLabel").pack(anchor="w")

        self._step(outer, 1, "What it does", [
            "E-Ink Mode turns your screen grayscale, like an e-reader, so it "
            "feels calmer and less distracting. Your apps, files, and settings "
            "are not changed.",
            "Turning it off — or quitting the tray — puts your display "
            "back exactly as it was.",
        ])

        step2 = self._step_frame(outer, 2, "Try it first")
        preview_row = ttk.Frame(step2)
        preview_row.pack(fill="x")
        self.preview_button = ttk.Button(preview_row, text="Preview Grayscale for 10 Seconds",
                                         command=self._start_preview)
        self.preview_button.pack(side="left")
        self.preview_label = ttk.Label(preview_row, text="", style="Hint.TLabel")
        self.preview_label.pack(side="left", padx=(10, 0))
        hint_label(step2, "The preview changes only grayscale and ends on its own.").pack(
            anchor="w", pady=(4, 0)
        )
        if mode_active(self.store):
            self.preview_button.configure(state="disabled")

        step3 = self._step_frame(outer, 3, "Optional extras — off unless you choose them")
        self.dim_var = tk.BooleanVar(value=False)
        self.brightness_var = tk.DoubleVar(value=50.0)
        dim_row = ttk.Frame(step3)
        dim_row.pack(fill="x")
        ttk.Checkbutton(dim_row, text="Also dim the screen to", variable=self.dim_var,
                        state=("normal" if self.has_brightness else "disabled"),
                        command=self._update_brightness_state).pack(side="left")
        self.welcome_brightness_scale = ttk.Scale(dim_row, from_=5, to=100, orient="horizontal",
                                                  variable=self.brightness_var, length=110,
                                                  command=self._on_brightness_move)
        self.welcome_brightness_scale.pack(side="left", padx=(8, 8))
        self.brightness_pct_label = ttk.Label(dim_row, text="50%")
        self.brightness_pct_label.pack(side="left")
        if not self.has_brightness:
            hint_label(step3, "This display doesn't support brightness control.").pack(anchor="w", pady=(2, 0))
        self.hide_taskbar_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(step3, text="Also auto-hide the taskbar", variable=self.hide_taskbar_var).pack(
            anchor="w", pady=(6, 0)
        )
        hint_label(step3, "Your current brightness and taskbar setting are saved and put "
                          "back when you turn it off. You can change these any time in "
                          "Settings → Appearance.").pack(anchor="w", pady=(6, 0))
        self._update_brightness_state()

        step4 = self._step_frame(outer, 4, "Where to find it")
        ttk.Label(step4, text="Look for ○ by the clock, in the system tray. It fills in "
                              "(●) while your screen is grayscale. Click it for the menu.",
                 wraplength=440, justify="left").pack(anchor="w")
        self.click_to_switch_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(step4, text="Click the icon to switch on and off instead (right-click "
                                    "for the menu)", variable=self.click_to_switch_var).pack(
            anchor="w", pady=(4, 0)
        )
        shortcut_id = load_preferences(home=self.home).shortcut
        if shortcut_id != "none":
            hint_label(step4, f"Or press {shortcut_label(shortcut_id)} from any app.").pack(
                anchor="w", pady=(2, 0)
            )
        hint_label(step4, "Win+Ctrl+C always switches Windows' colour filter yourself, even "
                          "if E-Ink Mode isn't running.").pack(anchor="w", pady=(2, 0))

        self.status_var = tk.StringVar(value="")
        ttk.Label(outer, textvariable=self.status_var, style="Error.TLabel", wraplength=440,
                 justify="left").pack(anchor="w", pady=(10, 0))

        button_row = ttk.Frame(outer)
        button_row.pack(fill="x", pady=(14, 0))
        self.not_now_button = ttk.Button(button_row, text="Not Now", command=self._on_not_now)
        self.not_now_button.pack(side="left")
        self.turn_on_button = ttk.Button(button_row, text="Turn On E-Ink Mode", command=self._on_turn_on)
        self.turn_on_button.pack(side="right")
        root.bind("<Return>", lambda _e: self._on_turn_on())

    # -- layout helpers -------------------------------------------------------

    def _step_frame(self, parent, number: int, title: str) -> ttk.Frame:
        row = ttk.Frame(parent)
        row.pack(fill="x", pady=(0, 16))
        ttk.Label(row, text=str(number), style="Step.TLabel", width=2, anchor="center").pack(
            side="left", anchor="n", padx=(0, 10)
        )
        body = ttk.Frame(row)
        body.pack(side="left", fill="x", expand=True)
        ttk.Label(body, text=title, style="Step.TLabel").pack(anchor="w")
        content = ttk.Frame(body)
        content.pack(fill="x", pady=(4, 0))
        return content

    def _step(self, parent, number: int, title: str, lines: list[str]) -> None:
        content = self._step_frame(parent, number, title)
        for i, line in enumerate(lines):
            style = "TLabel" if i == 0 else "Hint.TLabel"
            ttk.Label(content, text=line, style=style, wraplength=440, justify="left").pack(
                anchor="w", pady=(0 if i == 0 else 4, 0)
            )

    # -- preview --------------------------------------------------------------

    def _start_preview(self) -> None:
        if not self.preview.start(active=mode_active(self.store)):
            return
        self.preview_button.configure(text="End Preview", command=self._end_preview)
        self.turn_on_button.configure(state="disabled")
        self.not_now_button.configure(state="disabled")
        self._tick_preview()
        profile = Configuration()  # grayscale-only, never saved

        def work():
            self.controller.set_mode(True, manual=False, profile=profile)

        self.runner.run(work, on_error=self._on_preview_error)

    def _tick_preview(self) -> None:
        if not self.preview.running:
            return
        remaining = self.preview.remaining()
        self.preview_label.configure(text=f"Back to color in {remaining}s…")
        if self.preview.expired():
            self._end_preview()
            return
        self._preview_after_id = self.root.after(200, self._tick_preview)

    def _end_preview(self) -> None:
        if not self.preview.running:
            return
        self.preview.end()
        self._cancel_preview_timer()
        self.preview_button.configure(text="Preview Grayscale for 10 Seconds", command=self._start_preview)
        self.preview_label.configure(text="")
        self.turn_on_button.configure(state="normal")
        self.not_now_button.configure(state="normal")

        def work():
            self.controller.set_mode(False, manual=False)

        self.runner.run(work, on_error=self._on_preview_error)

    def _end_preview_for_shutdown(self) -> None:
        """Synchronous variant used when the window is closing: the preview
        must end *before* the window (and this process) goes away."""
        if not self.preview.running:
            return
        self.preview.end()
        self._cancel_preview_timer()
        try:
            self.controller.set_mode(False, manual=False)
        except EinkError:
            pass

    def _cancel_preview_timer(self) -> None:
        if self._preview_after_id is not None:
            try:
                self.root.after_cancel(self._preview_after_id)
            except Exception:
                pass
            self._preview_after_id = None

    def _on_preview_error(self, exc: Exception) -> None:
        self.preview.end()
        self._cancel_preview_timer()
        self.status_var.set(str(exc))
        self.preview_button.configure(text="Preview Grayscale for 10 Seconds", command=self._start_preview)
        self.preview_label.configure(text="")
        self.turn_on_button.configure(state="normal")
        self.not_now_button.configure(state="normal")

    # -- brightness slider ------------------------------------------------------

    def _update_brightness_state(self) -> None:
        state = "normal" if (self.dim_var.get() and self.has_brightness) else "disabled"
        self.welcome_brightness_scale.configure(state=state)

    def _on_brightness_move(self, _value) -> None:
        step = 5 * round(self.brightness_var.get() / 5)
        self.brightness_pct_label.configure(text=f"{int(step)}%")

    # -- finishing --------------------------------------------------------------

    def _save_extras(self) -> None:
        dim = self.dim_var.get() and self.has_brightness
        percent = 5 * round(self.brightness_var.get() / 5)
        hide_taskbar = self.hide_taskbar_var.get()
        try:
            save_preference("clickToSwitch", self.click_to_switch_var.get(), home=self.home)
        except EinkError:
            pass
        self.controller.edit(welcome_config_change(dim, percent, hide_taskbar))

    def _on_not_now(self) -> None:
        self._end_preview_for_shutdown()
        try:
            self._save_extras()
        except EinkError as exc:
            self.status_var.set(str(exc))
            return
        self._close()

    def _on_turn_on(self) -> None:
        self._end_preview_for_shutdown()
        try:
            self._save_extras()
            self.controller.set_mode(True)
        except EinkError as exc:
            self.status_var.set(str(exc))
            return
        self._close()

    def _on_window_close(self) -> None:
        self._end_preview_for_shutdown()
        self._close()

    def _close(self) -> None:
        try:
            save_preference("welcomeShown", True, home=self.home)
        except EinkError:
            pass
        self.root.destroy()


# ===========================================================================
# Entry points
# ===========================================================================

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="eink_ui.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    settings_parser = sub.add_parser("settings", help="Open the Settings window")
    settings_parser.add_argument("--tab", choices=SETTINGS_TABS, default="general")
    settings_parser.add_argument("--screenshot", help=argparse.SUPPRESS)

    welcome_parser = sub.add_parser("welcome", help="Open the Welcome guide")
    welcome_parser.add_argument("--screenshot", help=argparse.SUPPRESS)

    return parser


def _capture_and_close(root: tk.Tk, path: str) -> None:
    try:
        from PIL import ImageGrab

        root.update_idletasks()
        root.update()
        x, y = root.winfo_rootx(), root.winfo_rooty()
        w, h = root.winfo_width(), root.winfo_height()
        image = ImageGrab.grab(bbox=(x, y, x + w, y + h))
        image.save(path)
    finally:
        root.after(50, root.destroy)


def _run_settings(home: Path, tab: str, screenshot: str | None) -> None:
    if not acquire_singleton(SETTINGS_MUTEX):
        bring_window_forward(SETTINGS_TITLE)
        return
    root = tk.Tk()
    SettingsWindow(root, home, tab=tab)
    if screenshot:
        root.after(1500, lambda: _capture_and_close(root, screenshot))
    root.mainloop()


def _run_welcome(home: Path, screenshot: str | None) -> None:
    if not acquire_singleton(WELCOME_MUTEX):
        bring_window_forward(WELCOME_TITLE)
        return
    root = tk.Tk()
    WelcomeWindow(root, home)
    if screenshot:
        root.after(1500, lambda: _capture_and_close(root, screenshot))
    root.mainloop()


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    args = build_arg_parser().parse_args(argv)
    set_dpi_awareness()
    home = home_dir()
    if args.command == "settings":
        _run_settings(home, args.tab, args.screenshot)
    else:
        _run_welcome(home, args.screenshot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
