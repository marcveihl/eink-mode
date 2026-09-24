"""E-Ink Mode tray: the Windows port of the macOS menu-bar app, minus every
Focus/Pomodoro feature (out of scope on Windows per `PARITY-SPEC.md`).

This is the resident process (P8: every action lands in `eink_core.Controller`
-- nothing here ever calls `eink_win`/`eink_sim` directly except the handful
of adapter-selection and "cheap read" helpers called out below). It owns:
the tray icon and menu, the 1-second tick, the global hotkey, session-end
restore, crash recovery, and legacy migration from the v0 tray.

Module layout:
  * Pure / testable logic (menu model, icon shading, shortcut mapping,
    the external-change debouncer, legacy migration) -- no pystray, no
    ctypes, no window handles. `test_eink_tray.py` exercises this half with
    `FakeSystem` and a temp `EINK_HOME`; nothing here ever touches the real
    display, registry, or taskbar.
  * Windows/pystray integration (icon drawing, the hidden hotkey/session
    window, the click-aware tray icon, `EinkTray`, `main()`) -- glue code,
    deliberately kept thin so the logic above stays the thing under test.

Principles ported from `eink_core`/`eink_win`, referenced as P1..P9:
  P3  Fail-safe: every tray action runs in a background thread and reports
      failure through `self.error`/a balloon, never a crash.
  P8  One state machine: every menu item, hotkey press, and CLI flag here
      calls `Controller`, never `eink_win`/`eink_sim` setters directly.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import winreg
from dataclasses import dataclass, field
from datetime import datetime, timezone

import pystray
from PIL import Image, ImageDraw, ImageFont
import win32api
import win32con
import win32gui

from eink_core import (
    Configuration,
    Controller,
    EinkError,
    Preferences,
    RuntimeState,
    Schedule,
    ScheduleStatus,
    Snapshot,
    Status,
    Store,
    countdown,
    grayscale_on,
    home_dir,
    local_zone,
)
from eink_paths import ui_argv

ROOT = Path(__file__).resolve().parent
LOG = logging.getLogger("eink.tray")

# Keep the v0 mutex name so the old and new tray can never run together
# (PARITY-SPEC.md "Process model").
MUTEX_NAME = "Local\\EinkMode.Grayscale.v1"


# ============================================================================
# Pure / testable logic
# ============================================================================

# ----------------------------------------------------------------------
# Shortcut ids -> (RegisterHotKey modifiers, virtual-key, display symbol).
# Values match PARITY-SPEC.md "Shortcut ids -> keys". The MOD_* constants are
# the RegisterHotKey values (winuser.h) spelled out here rather than imported
# from win32con, so this mapping has no Windows-module dependency and can be
# unit-tested on its own.
# ----------------------------------------------------------------------

MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT = 0x0004


@dataclass(frozen=True)
class ShortcutSpec:
    modifiers: int
    vk: int
    symbol: str


SHORTCUT_SPECS: dict[str, ShortcutSpec] = {
    "ctrl-shift-e": ShortcutSpec(MOD_CONTROL | MOD_SHIFT, ord("E"), "Ctrl+Shift+E"),
    "ctrl-alt-shift-e": ShortcutSpec(MOD_CONTROL | MOD_ALT | MOD_SHIFT, ord("E"), "Ctrl+Alt+Shift+E"),
    "ctrl-alt-e": ShortcutSpec(MOD_CONTROL | MOD_ALT, ord("E"), "Ctrl+Alt+E"),
    "ctrl-alt-shift-g": ShortcutSpec(MOD_CONTROL | MOD_ALT | MOD_SHIFT, ord("G"), "Ctrl+Alt+Shift+G"),
}


def shortcut_symbol(shortcut_id: str) -> str:
    spec = SHORTCUT_SPECS.get(shortcut_id)
    return spec.symbol if spec else ""


def hotkey_message(shortcut_id: str, registered: bool) -> str:
    """The `tray-status.json` "hotkeyMessage" sentence (PARITY-SPEC.md)."""
    if shortcut_id == "none" or shortcut_id not in SHORTCUT_SPECS:
        return "No keyboard shortcut. Use the tray icon."
    symbol = SHORTCUT_SPECS[shortcut_id].symbol
    if registered:
        return f"{symbol} switches E-Ink Mode from any app."
    return f"{symbol} is already taken by another app. Choose a different shortcut."


# ----------------------------------------------------------------------
# Menu model: mirrors MenuBuilder.swift minus every Focus/Pomodoro branch.
# `menu_view()` returns a plain tree of `MenuNode` -- labels, enabled/checked
# flags, and opaque action ids -- with no pystray/AppKit object in sight, so
# it is fully unit-testable. `EinkTray._to_pystray()` is the only place that
# turns this into real menu widgets.
# ----------------------------------------------------------------------


@dataclass
class MenuNode:
    label: str
    action: str | None = None
    enabled: bool = True
    checked: bool | None = None
    children: "list[MenuNode] | None" = None
    tooltip: str | None = None


SEPARATOR = MenuNode("- - - -", action="_separator_")


def _header(text: str) -> MenuNode:
    return MenuNode(text, enabled=False)


def _note(text: str) -> MenuNode:
    return MenuNode(text, enabled=False)


def _item(label: str, action: str, *, enabled: bool = True, checked: bool | None = None,
          tooltip: str | None = None) -> MenuNode:
    return MenuNode(label, action=action, enabled=enabled, checked=checked, tooltip=tooltip)


def wrap(text: str, width: int = 46) -> str:
    """Menu items don't wrap on their own; break long text into lines, the
    same simple word-wrap as MenuBuilder.swift's `wrap()`."""
    lines: list[str] = []
    line = ""
    for word in text.split(" "):
        if line and len(line) + len(word) + 1 > width:
            lines.append(line)
            line = ""
        line = f"{line} {word}" if line else word
    if line:
        lines.append(line)
    return "\n".join(lines)


def _schedule_submenu(config: Configuration, status: ScheduleStatus) -> list[MenuNode]:
    schedule = config.schedule
    nodes = [
        _item("Off", "schedule_off", checked=not schedule.enabled),
        _item("Evening · 9:00 PM – 7:00 AM", "schedule_evening",
              checked=schedule.enabled and schedule.is_evening),
    ]
    if not schedule.is_evening:
        nodes.append(_item(
            f"Custom · {Schedule.format(schedule.on)} – {Schedule.format(schedule.off)}",
            "schedule_custom", checked=schedule.enabled))
    nodes.append(SEPARATOR)
    nodes.append(_note(wrap(status.detail, 46)))
    nodes.append(SEPARATOR)
    nodes.append(_item("Edit Schedule…", "edit_schedule"))
    return nodes


def menu_view(*, config: Configuration, state: RuntimeState, prefs: Preferences,
              now: datetime, tz, needs_recovery: bool = False,
              error: str | None = None) -> list[MenuNode]:
    """The whole tray menu, as data. Ported from `MenuBuilder.build` with
    every Focus/Pomodoro branch removed. Recovery/error notices are
    *prepended* to the normal menu, exactly as the Swift original -- they
    never replace it."""
    status = Status(config, state, Snapshot(values={}))
    active = status.active
    color_remaining = status.temporary_color_remaining(now)
    schedule_status = ScheduleStatus(config, state, now, tz)

    nodes: list[MenuNode] = []

    if needs_recovery:
        nodes.append(_header("Unfinished session found"))
        nodes.append(_item("Restore Display", "restore_display"))
        nodes.append(_item("Continue Session", "continue_session"))
        nodes.append(SEPARATOR)
    elif error:
        nodes.append(_header("⚠ Something needs attention"))
        truncated = error[:60] + ("…" if len(error) > 60 else "")
        nodes.append(_item(truncated, "show_error", tooltip=error))
        nodes.append(_item("Restore Display", "restore_display"))
        nodes.append(SEPARATOR)

    if active:
        state_word = "On, showing color" if color_remaining is not None else "On"
    else:
        state_word = "Off"
    nodes.append(_header(f"E-Ink Mode · {state_word}"))

    symbol = shortcut_symbol(prefs.shortcut)
    toggle_label = "Turn Off" if active else "Turn On"
    if symbol:
        toggle_label = f"{toggle_label}\t{symbol}"
    nodes.append(_item(toggle_label, "turn_off" if active else "turn_on",
                        enabled=not needs_recovery))

    if active and config.grayscale:
        if color_remaining is not None:
            nodes.append(_item(f"Resume grayscale · {countdown(color_remaining)} remaining",
                                "end_color"))
        else:
            nodes.append(_item("Color for 5 Minutes", "color_5"))

    nodes.append(SEPARATOR)

    schedule_node = MenuNode(f"Schedule · {schedule_status.short}",
                              children=_schedule_submenu(config, schedule_status))
    nodes.append(schedule_node)
    nodes.append(_item("Customize Appearance…", "customize_appearance"))
    nodes.append(_item("Settings…", "settings"))

    nodes.append(SEPARATOR)
    if prefs.clickToSwitch:
        nodes.append(_note("Tip: click the icon to switch · right-click for this menu"))
    nodes.append(_item("Quit and Restore Display", "quit"))

    return nodes


def tooltip_text(*, active: bool, color_remaining: float | None,
                  needs_recovery: bool = False, error: str | None = None) -> str:
    """Tray icon tooltip: the menu header text, plus the color countdown."""
    if needs_recovery or error:
        return "E-Ink Mode needs attention"
    if active and color_remaining is not None:
        return f"E-Ink Mode · On, showing color · {countdown(color_remaining)} remaining"
    return f"E-Ink Mode · {'On' if active else 'Off'}"


# ----------------------------------------------------------------------
# Icon shading: unshaded/shaded/half, or None for the warning glyph -- the
# same rule for the plain dot and for Wildcat mode (WildcatIcon.swift).
# ----------------------------------------------------------------------


def icon_shade(*, active: bool, color_remaining: float | None,
                needs_recovery: bool = False, error: str | None = None) -> str | None:
    if needs_recovery or error:
        return None
    if active and color_remaining is not None:
        return "half"
    return "shaded" if active else "unshaded"


# ----------------------------------------------------------------------
# External-change debounce (spec item 5): the OS filter reading "off" while
# a session wants grayscale is either the user pressing Win+Ctrl+C / using
# Settings, or our own in-flight press briefly reading the opposite value.
# Two consecutive off-reads at least `min_interval` apart settle it.
# ----------------------------------------------------------------------


@dataclass
class ExternalGrayscaleWatcher:
    min_interval: float = 1.5
    _since_off: float | None = field(default=None, init=False, repr=False)

    def reset(self) -> None:
        self._since_off = None

    def observe(self, active: bool, now: float) -> bool:
        """Call on every tick with the OS filter's current `Active` reading
        and a monotonic clock. Returns True once two consecutive off-reads at
        least `min_interval` seconds apart have been observed."""
        if active:
            self._since_off = None
            return False
        if self._since_off is None:
            self._since_off = now
            return False
        return (now - self._since_off) >= self.min_interval


def read_active_cheap(adapter) -> bool | None:
    """Reads only the OS filter's `Active` flag when that is possible --
    the real `WindowsSystem` exposes a module-level `filter_active()` that is
    a single registry read, unlike `snapshot()` (WMI + taskbar + theme +
    SPI). Anything else (`SimulatedSystem`/`FakeSystem` in tests) has no WMI
    cost to begin with, so a full snapshot is fine and keeps tests off the
    registry entirely."""
    try:
        import eink_win
    except ImportError:
        eink_win = None
    if eink_win is not None and isinstance(adapter, eink_win.WindowsSystem):
        return eink_win.filter_active()
    value = adapter.snapshot().values.get("grayscale")
    return None if value is None else grayscale_on(value)


# ----------------------------------------------------------------------
# Legacy migration (PARITY-SPEC.md "Legacy migration").
# ----------------------------------------------------------------------


def migrate_legacy(store: Store, adapter, *, legacy_state_path: Path,
                    legacy_config_path: Path) -> None:
    """Ports the v0 tray's grayscale capture and click-action preference.

    v0 kept a filter capture at `legacy_state_path` (`tray-grayscale.json`)
    and its own prefs (`click_action`/`exit_action`) in `legacy_config_path`
    (`prototype0-win/config.json`). "Once" (spec) is implemented as
    "`preferences.json` does not exist yet" -- the first run of the new tray
    against a given home always creates it, so a second run never re-applies
    a stale legacy preference over a value the person has since changed.
    """
    with store.locked():
        state = RuntimeState.from_dict(store.read_json("state.json"))
        if state.session is None and legacy_state_path.exists():
            captured = None
            try:
                captured = json.loads(legacy_state_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                LOG.exception("legacy grayscale capture unreadable")
            if isinstance(captured, dict):
                value = {"active": bool(captured.get("active")),
                          "filterType": int(captured.get("filterType", 0))}
                try:
                    adapter.set("grayscale", value)
                except Exception:
                    LOG.exception("legacy grayscale restore failed")
            try:
                legacy_state_path.unlink()
            except OSError:
                pass

        if store.read_json("preferences.json") is None:
            legacy_config: dict = {}
            try:
                legacy_config = json.loads(legacy_config_path.read_text(encoding="utf-8-sig"))
            except (OSError, ValueError):
                legacy_config = {}
            prefs = Preferences()
            if legacy_config.get("click_action") == "toggle":
                prefs.clickToSwitch = True
            store.write_json(prefs.to_dict(), "preferences.json")


def write_tray_status(store: Store, *, shortcut_id: str, message: str, pid: int | None = None) -> None:
    with store.locked():
        store.write_json({
            "pid": pid if pid is not None else os.getpid(),
            "hotkey": shortcut_id,
            "hotkeyMessage": message,
            "updated": datetime.now(timezone.utc).isoformat(),
        }, "tray-status.json")


# ============================================================================
# Windows integration (icon drawing, hidden window, pystray glue). Not unit
# tested -- PARITY-SPEC.md forbids tests touching the real display, registry,
# taskbar, or hotkeys, and there is no pure logic left to extract here.
# ============================================================================

THEME_KEY = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"


def taskbar_is_light() -> bool:
    """Pick ink that reads against the taskbar it sits on."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, THEME_KEY) as key:
            value, _ = winreg.QueryValueEx(key, "SystemUsesLightTheme")
        return value == 1
    except OSError:
        return False


def _scale(points, size):
    k = size / 100.0
    return [(x * k, y * k) for x, y in points]


_WILDCAT_HEAD = [(20, 6), (39, 25), (50, 23), (61, 25), (80, 6), (86, 37), (96, 50), (87, 57),
                 (93, 70), (77, 75), (62, 93), (50, 96), (38, 93), (23, 75), (7, 70), (13, 57),
                 (4, 50), (14, 37)]
_WILDCAT_INNER_EARS = [[(23, 15), (35, 28), (19, 35)], [(77, 15), (65, 28), (81, 35)]]
_WILDCAT_EYES = [[(24, 46), (44, 52), (41, 58), (29, 56)], [(76, 46), (56, 52), (59, 58), (71, 56)]]
_WILDCAT_NOSE = [(42, 64), (58, 64), (50, 73)]
_WILDCAT_STRIPES = [[(47, 27), (53, 27), (50, 42)], [(38, 30), (43, 29), (42, 40)],
                    [(62, 30), (57, 29), (58, 40)]]
_WILDCAT_MOUTH = [(40, 82), (46, 84.5), (50, 79), (54, 84.5), (60, 82)]
_WILDCAT_MOUTH_STEM = [(50, 73), (50, 79)]


def _draw_wildcat_style(style: str, draw: "ImageDraw.ImageDraw", size: int, ink) -> None:
    head = _scale(_WILDCAT_HEAD, size)
    thick = max(2, round(size * 0.07))
    thin = max(1, round(size * 0.045))
    if style == "outline":
        draw.line(head + [head[0]], fill=ink, width=thick, joint="curve")
        for shape in _WILDCAT_EYES + _WILDCAT_STRIPES + [_WILDCAT_NOSE]:
            draw.polygon(_scale(shape, size), fill=ink)
        draw.line(_scale(_WILDCAT_MOUTH_STEM, size), fill=ink, width=thin)
        draw.line(_scale(_WILDCAT_MOUTH, size), fill=ink, width=thin, joint="curve")
    else:  # "filled" -- knock the features out of the solid head.
        draw.polygon(head, fill=ink)
        transparent = (0, 0, 0, 0)
        for shape in _WILDCAT_INNER_EARS + _WILDCAT_EYES + _WILDCAT_STRIPES + [_WILDCAT_NOSE]:
            draw.polygon(_scale(shape, size), fill=transparent)
        draw.line(_scale(_WILDCAT_MOUTH_STEM, size), fill=transparent, width=thin)
        draw.line(_scale(_WILDCAT_MOUTH, size), fill=transparent, width=thin, joint="curve")


def draw_wildcat(style: str, *, size: int = 64, ink=(0, 0, 0, 255)) -> Image.Image:
    """Ports `WildcatIcon.swift`'s path drawing to PIL: outline / filled /
    half, with the same shading rule (half = outline everywhere, filled
    solid on the left half)."""
    if style == "half":
        outline_img = Image.new("RGBA", (size, size))
        _draw_wildcat_style("outline", ImageDraw.Draw(outline_img), size, ink)
        filled_img = Image.new("RGBA", (size, size))
        _draw_wildcat_style("filled", ImageDraw.Draw(filled_img), size, ink)
        left_half = size // 2
        outline_img.paste(filled_img.crop((0, 0, left_half, size)), (0, 0))
        return outline_img
    img = Image.new("RGBA", (size, size))
    _draw_wildcat_style(style, ImageDraw.Draw(img), size, ink)
    return img


def _draw_dot(shade: str, *, size: int, ink) -> Image.Image:
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    pad = size * 0.125
    box = (pad, pad, size - pad, size - pad)
    width = max(2, round(size * 0.11))
    if shade == "shaded":
        draw.ellipse(box, fill=ink)
    elif shade == "half":
        draw.ellipse(box, outline=ink, width=width)
        draw.pieslice(box, start=90, end=270, fill=ink)
    else:
        draw.ellipse(box, outline=ink, width=width)
    return img


def _draw_warning(*, size: int, ink) -> Image.Image:
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    pad = size * 0.08
    triangle = [(size / 2, pad), (size - pad, size - pad), (pad, size - pad)]
    draw.polygon(triangle, outline=ink, width=max(2, round(size * 0.08)))
    try:
        font = ImageFont.truetype("segoeui.ttf", int(size * 0.4))
    except Exception:
        font = ImageFont.load_default()
    text = "!"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text((size / 2 - tw / 2 - bbox[0], size * 0.6 - th / 2 - bbox[1]), text, fill=ink, font=font)
    return img


def create_icon_image(shade: str | None, *, wildcat: bool = False, light: bool | None = None,
                       size: int = 64) -> Image.Image:
    """The tray icon: ○ off, ● on, ◐ temporary color, or a
    warning glyph while `shade` is None (error/recovery pending). Ink follows
    the taskbar theme unless `light` is given explicitly (tests)."""
    if light is None:
        light = taskbar_is_light()
    ink = (24, 24, 23, 255) if light else (244, 241, 232, 255)
    if shade is None:
        return _draw_warning(size=size, ink=ink)
    if wildcat:
        return draw_wildcat(icon_shade_to_wildcat_style(shade), size=size, ink=ink)
    return _draw_dot(shade, size=size, ink=ink)


def icon_shade_to_wildcat_style(shade: str) -> str:
    return {"unshaded": "outline", "shaded": "filled", "half": "half"}[shade]


# ----------------------------------------------------------------------
# Click-aware tray icon.
#
# pystray's win32 backend (`pystray._win32.Icon._on_notify`) calls the
# default menu item's action on a left click (`WM_LBUTTONUP -> self()`) and
# only shows the popup menu on a right click. macOS parity needs the
# opposite default: a left click opens the menu (like a right click
# everywhere else) unless the `clickToSwitch` preference is on, in which
# case a left click toggles and a right click still opens the menu. pystray
# has no public hook for choosing this, so this subclass overrides the
# private win32 notify handler directly -- the only place in this file that
# reaches into a pystray internal -- reusing its own popup-menu code
# (`TrackPopupMenuEx`) verbatim so a left-click menu behaves exactly like a
# real right-click one. It also calls `update_menu()` immediately before
# showing the popup on *either* click, so menu text (spec item 1) is always
# rebuilt fresh the moment the menu opens, not left stale from the last time.
# ----------------------------------------------------------------------


class ClickAwareIcon(pystray.Icon):
    def __init__(self, *args, click_to_switch, on_left_toggle, **kwargs):
        super().__init__(*args, **kwargs)
        self._click_to_switch = click_to_switch
        self._on_left_toggle = on_left_toggle

    def _on_notify(self, wparam, lparam):
        from pystray._util import win32

        if lparam == win32.WM_LBUTTONUP:
            if self._click_to_switch():
                self._on_left_toggle()
            else:
                self._popup_menu()
            return
        if self._menu_handle and lparam == win32.WM_RBUTTONUP:
            self._popup_menu()

    def _popup_menu(self):
        from pystray._util import win32

        self.update_menu()
        if not self._menu_handle:
            return
        win32.SetForegroundWindow(self._hwnd)
        point = wintypes.POINT()
        win32.GetCursorPos(ctypes.byref(point))
        hmenu, descriptors = self._menu_handle
        index = win32.TrackPopupMenuEx(
            hmenu, win32.TPM_RIGHTALIGN | win32.TPM_BOTTOMALIGN | win32.TPM_RETURNCMD,
            point.x, point.y, self._menu_hwnd, None)
        if index > 0:
            descriptors[index - 1](self)


# ----------------------------------------------------------------------
# Hidden top-level window for the global hotkey, sleep/resume, and session
# end. A *top-level* window (not HWND_MESSAGE) so it also receives the
# broadcasts WM_POWERBROADCAST and WM_QUERYENDSESSION/WM_ENDSESSION need
# (message-only windows do not get broadcast messages). RegisterHotKey must
# be called from the thread that pumps its messages, so re-registration goes
# through a private posted message rather than a direct cross-thread call.
# ----------------------------------------------------------------------

HOTKEY_ID = 1
_WM_REREGISTER = win32con.WM_APP + 1
_WM_QUIT = win32con.WM_APP + 2


class HotkeyWindow:
    def __init__(self, *, on_hotkey, on_power_resume, on_session_end, on_registered=None):
        self._on_hotkey = on_hotkey
        self._on_power_resume = on_power_resume
        self._on_session_end = on_session_end
        self._on_registered = on_registered
        self._hwnd = None
        self._atom = None
        self._hinstance = None
        self._next_shortcut = "none"
        self._session_ended = False
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, name="eink-hotkey", daemon=True)

    def start(self, shortcut_id: str) -> None:
        self._next_shortcut = shortcut_id
        self._thread.start()
        self._ready.wait(timeout=5)

    def set_shortcut(self, shortcut_id: str) -> None:
        if not self._hwnd:
            self._next_shortcut = shortcut_id
            return
        self._next_shortcut = shortcut_id
        win32gui.PostMessage(self._hwnd, _WM_REREGISTER, 0, 0)

    def stop(self) -> None:
        if self._hwnd:
            win32gui.PostMessage(self._hwnd, _WM_QUIT, 0, 0)
        self._thread.join(timeout=5)

    def _register(self, shortcut_id: str) -> str:
        try:
            win32gui.UnregisterHotKey(self._hwnd, HOTKEY_ID)
        except Exception:
            pass
        if shortcut_id not in SHORTCUT_SPECS:
            return hotkey_message(shortcut_id, registered=False)
        spec = SHORTCUT_SPECS[shortcut_id]
        try:
            win32gui.RegisterHotKey(self._hwnd, HOTKEY_ID, spec.modifiers, spec.vk)
            ok = True
        except Exception:
            LOG.exception("RegisterHotKey failed for %s", shortcut_id)
            ok = False
        return hotkey_message(shortcut_id, ok)

    def _handle_session_end(self) -> None:
        if self._session_ended:
            return
        self._session_ended = True
        try:
            self._on_session_end()
        except Exception:
            LOG.exception("session-end shutdown failed")

    def _wndproc(self, hwnd, msg, wparam, lparam):
        if msg == win32con.WM_HOTKEY and wparam == HOTKEY_ID:
            self._on_hotkey()
            return 0
        if msg == win32con.WM_POWERBROADCAST and wparam in (
                win32con.PBT_APMRESUMEAUTOMATIC, win32con.PBT_APMRESUMESUSPEND):
            self._on_power_resume()
            return 1
        if msg == win32con.WM_QUERYENDSESSION:
            self._handle_session_end()
            return 1
        if msg == win32con.WM_ENDSESSION:
            if wparam:
                self._handle_session_end()
            return 0
        if msg == _WM_REREGISTER:
            message = self._register(self._next_shortcut)
            if self._on_registered:
                self._on_registered(self._next_shortcut, message)
            return 0
        if msg == _WM_QUIT:
            win32gui.DestroyWindow(hwnd)
            return 0
        if msg == win32con.WM_DESTROY:
            try:
                win32gui.UnregisterHotKey(hwnd, HOTKEY_ID)
            except Exception:
                pass
            win32gui.PostQuitMessage(0)
            return 0
        return win32gui.DefWindowProc(hwnd, msg, wparam, lparam)

    def _run(self) -> None:
        wc = win32gui.WNDCLASS()
        wc.lpfnWndProc = self._wndproc
        wc.lpszClassName = f"EinkModeHotkeyWnd-{os.getpid()}"
        wc.hInstance = win32api.GetModuleHandle(None)
        self._hinstance = wc.hInstance
        try:
            self._atom = win32gui.RegisterClass(wc)
            self._hwnd = win32gui.CreateWindow(
                self._atom, "E-Ink Mode", 0, 0, 0, 0, 0, 0, 0, wc.hInstance, None)
            message = self._register(self._next_shortcut)
            if self._on_registered:
                self._on_registered(self._next_shortcut, message)
        finally:
            self._ready.set()
        try:
            win32gui.PumpMessages()
        finally:
            try:
                win32gui.UnregisterClass(self._atom, self._hinstance)
            except Exception:
                pass


# ----------------------------------------------------------------------
# Single-instance mutex (kept identical to v0's name).
# ----------------------------------------------------------------------


class InstanceLock:
    def __init__(self, name: str = MUTEX_NAME):
        self.name = name

    def __enter__(self):
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        kernel.CreateMutexW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel = kernel
        self.handle = kernel.CreateMutexW(None, False, self.name)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
            kernel.CloseHandle(self.handle)
            raise RuntimeError("E-Ink Mode is already running. Use its tray menu.")
        return self

    def __exit__(self, *args):
        self.kernel.CloseHandle(self.handle)


MB_YESNO = 0x4
MB_RETRYCANCEL = 0x5
MB_ICONWARNING = 0x30
MB_ICONERROR = 0x10
IDYES = 6
IDRETRY = 4


def message_box(text: str, title: str = "E-Ink Mode", flags: int = 0x10) -> int:
    return ctypes.windll.user32.MessageBoxW(0, text, title, flags)


def launch_ui(*args: str) -> None:
    """Launches `eink_ui.py` as a separate process (PARITY-SPEC.md "Process
    model") -- the tray never imports it. Frozen-aware via `eink_paths.ui_argv`
    (dev: pythonw + the sibling script; frozen: `EInkMode.exe ui ...`)."""
    try:
        subprocess.Popen(
            ui_argv(*args),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except Exception:
        LOG.exception("launching eink_ui.py failed")


def _make_adapter(home: Path):
    """Same lazy-import pattern as `eink_cli._make_adapter`: only reaches for
    `eink_win` (ctypes/winreg/WMI) off the simulated path."""
    if os.environ.get("EINK_SIMULATED") == "1":
        from eink_sim import SimulatedSystem
        return SimulatedSystem(home / "simulated-system.json")
    from eink_win import WindowsSystem
    return WindowsSystem()


def setup_logging(home: Path | None = None) -> None:
    home = home or home_dir()
    home.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(home / "eink.log", maxBytes=500_000, backupCount=3,
                                  encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    LOG.handlers.clear()
    LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)


# ----------------------------------------------------------------------
# EinkTray: wires the pieces above to pystray + the hidden window.
# ----------------------------------------------------------------------


class EinkTray:
    def __init__(self, store: Store, adapter, tz=None, enable_hotkey: bool = True):
        self.store = store
        self.adapter = adapter
        self.tz = tz
        self.controller = Controller(store, adapter, tz=tz)
        self.enable_hotkey = enable_hotkey
        self.busy = threading.Lock()
        self.needs_recovery = False
        self.error: str | None = None
        self._external_watcher = ExternalGrayscaleWatcher()
        self._stop_tick = threading.Event()
        self.icon = ClickAwareIcon(
            "eink", create_icon_image("unshaded", light=True), "E-Ink Mode",
            menu=pystray.Menu(self._build_menu),
            click_to_switch=lambda: self._prefs().clickToSwitch,
            on_left_toggle=self._left_click,
        )
        self.hotkey = HotkeyWindow(
            on_hotkey=self._hotkey_pressed,
            on_power_resume=self._on_power_resume,
            on_session_end=self._on_session_end,
            on_registered=self._on_hotkey_registered,
        )

    # -- state reads (cheap: local JSON, never Controller.status()) --------

    def _tz(self):
        return self.tz if self.tz is not None else local_zone()

    def _read_all(self):
        with self.store.locked():
            config = Configuration.from_dict(self.store.read_json("config.json"))
            state = RuntimeState.from_dict(self.store.read_json("state.json"))
            prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        return config, state, prefs

    def _prefs(self) -> Preferences:
        try:
            return Preferences.from_dict(self.store.read_json("preferences.json"))
        except Exception:
            return Preferences()

    # -- menu ---------------------------------------------------------------

    def _build_menu(self):
        config, state, prefs = self._read_all()
        nodes = menu_view(config=config, state=state, prefs=prefs, now=datetime.now(self._tz()),
                          tz=self._tz(), needs_recovery=self.needs_recovery, error=self.error)
        return [self._to_pystray(node) for node in nodes]

    def _to_pystray(self, node: MenuNode):
        if node is SEPARATOR:
            return pystray.Menu.SEPARATOR
        if node.children is not None:
            submenu = pystray.Menu(*(self._to_pystray(child) for child in node.children))
            return pystray.MenuItem(node.label, submenu, enabled=node.enabled)
        action = node.action
        # `action` is this call's own local (one `_to_pystray` call per node,
        # not a shared loop variable), so a plain closure is safe here -- no
        # late-binding trap. pystray inspects `action.__code__.co_argcount`
        # and only accepts exactly 0, 1, or 2 parameters, so this must take
        # precisely (icon, item) with no default-valued extra parameter.
        handler = (lambda icon, item: self._dispatch(action)) if action else None
        kwargs = {}
        if node.checked is not None:
            checked = node.checked
            kwargs["checked"] = lambda item, c=checked: c
            kwargs["radio"] = True
        return pystray.MenuItem(node.label, handler, enabled=node.enabled, **kwargs)

    def _dispatch(self, action: str) -> None:
        if action == "restore_display":
            self.run_exclusive(lambda: self.controller.set_mode(False), clear_recovery=True)
        elif action == "continue_session":
            self.run_exclusive(self.controller.resume, clear_recovery=True)
        elif action == "show_error":
            self._show_error_box()
        elif action == "turn_on":
            self.run_exclusive(lambda: self.controller.set_mode(True))
        elif action == "turn_off":
            self.run_exclusive(lambda: self.controller.set_mode(False))
        elif action == "color_5":
            self.run_exclusive(lambda: self.controller.start_temporary_color(300))
        elif action == "end_color":
            self.run_exclusive(self.controller.end_temporary_color)
        elif action == "schedule_off":
            self.run_exclusive(lambda: self.controller.edit(lambda c: setattr(c.schedule, "enabled", False)))
        elif action == "schedule_evening":
            def _evening(config):
                config.schedule = Schedule.evening()
                config.schedule.enabled = True
            self.run_exclusive(lambda: self.controller.edit(_evening))
        elif action == "schedule_custom":
            self.run_exclusive(lambda: self.controller.edit(lambda c: setattr(c.schedule, "enabled", True)))
        elif action == "edit_schedule":
            launch_ui("settings", "--tab", "schedule")
        elif action == "customize_appearance":
            launch_ui("settings", "--tab", "appearance")
        elif action == "settings":
            launch_ui("settings", "--tab", "general")
        elif action == "quit":
            self.quit_and_restore()

    # -- actions --------------------------------------------------------------

    def run_exclusive(self, work, *, clear_recovery: bool = False) -> None:
        """Keeps action work off the tray thread, one at a time (v0's
        pattern): a second action arriving while one is running is simply
        dropped rather than queued or blocking the click that triggered it."""
        if not self.busy.acquire(blocking=False):
            return

        def worker():
            try:
                work()
                if clear_recovery:
                    self.needs_recovery = False
                self.error = None
            except Exception as exc:
                LOG.exception("action failed")
                self.error = str(exc)
                try:
                    self.icon.notify(str(exc)[:240], "E-Ink Mode")
                except Exception:
                    pass
            finally:
                self.busy.release()
                self.refresh()

        threading.Thread(target=worker, daemon=True).start()

    def _left_click(self) -> None:
        if self.needs_recovery:
            self.icon._popup_menu()
            return
        self.run_exclusive(self.controller.toggle)

    def _show_error_box(self) -> None:
        message = self.error or ""

        def worker():
            answer = message_box(message + "\n\nRestore your display now?",
                                 flags=MB_YESNO | MB_ICONWARNING)
            if answer == IDYES:
                self.run_exclusive(lambda: self.controller.set_mode(False))

        threading.Thread(target=worker, daemon=True).start()

    def quit_and_restore(self) -> None:
        if not self.busy.acquire(blocking=False):
            return

        def worker():
            while True:
                try:
                    self.controller.shutdown(resume_schedule_on_launch=False)
                    self.busy.release()
                    self.stop()
                    self.icon.stop()
                    return
                except Exception as exc:
                    LOG.exception("quit restore failed")
                    answer = message_box(
                        "Your display couldn't be fully restored.\n\n" + str(exc) +
                        "\n\nIf you disconnected a display, reconnect it and try again. "
                        "E-Ink Mode stays open so nothing is lost.",
                        flags=MB_RETRYCANCEL | MB_ICONERROR)
                    if answer != IDRETRY:
                        self.error = str(exc)
                        self.busy.release()
                        self.refresh()
                        return

        threading.Thread(target=worker, daemon=True).start()

    # -- hotkey / power / session-end callbacks (run on the hotkey thread) --

    def _hotkey_pressed(self) -> None:
        if self.needs_recovery:
            return
        self.run_exclusive(self.controller.toggle)

    def _on_power_resume(self) -> None:
        threading.Thread(target=self._tick_once, daemon=True).start()

    def _on_session_end(self) -> None:
        # Must complete before the wndproc returns (spec item 7) -- called
        # synchronously, inline, on the hotkey/session window's own thread.
        self.controller.shutdown(resume_schedule_on_launch=True)

    def _on_hotkey_registered(self, shortcut_id: str, message: str) -> None:
        try:
            write_tray_status(self.store, shortcut_id=shortcut_id, message=message)
        except Exception:
            LOG.exception("writing tray-status.json failed")

    # -- recovery prompt (spec item 8) --------------------------------------

    def prompt_recovery(self) -> None:
        def worker():
            answer = message_box(
                "E-Ink Mode didn't close properly.\n\n"
                "Restore Display puts your screen back exactly as it was. "
                "Continue Session keeps E-Ink Mode running as it was.",
                flags=MB_YESNO | MB_ICONWARNING)
            if answer == IDYES:
                self.run_exclusive(lambda: self.controller.set_mode(False), clear_recovery=True)
            else:
                self.run_exclusive(self.controller.resume, clear_recovery=True)

        threading.Thread(target=worker, daemon=True).start()

    # -- tick loop ------------------------------------------------------------

    def _maybe_apply_external_off(self, config: Configuration, state: RuntimeState) -> None:
        if state.session is None:
            self._external_watcher.reset()
            return
        color_active = state.colorUntil is not None and state.colorUntil > datetime.now(timezone.utc)
        if not config.grayscale or color_active:
            self._external_watcher.reset()
            return
        active = read_active_cheap(self.adapter)
        if active is None:
            return
        if self._external_watcher.observe(active, time.monotonic()):
            self.run_exclusive(lambda: self.controller.set_mode(False))

    def _tick_once(self, now=None) -> None:
        if not self.needs_recovery:
            try:
                self.controller.tick(now=now)
            except Exception as exc:
                LOG.exception("controller.tick failed")
                self.error = str(exc)
        config, state, prefs = self._read_all()
        self._maybe_apply_external_off(config, state)
        self.refresh(config=config, state=state, prefs=prefs)

    def _tick_loop(self) -> None:
        while not self._stop_tick.wait(1.0):
            try:
                self._tick_once()
            except Exception:
                LOG.exception("tick failed")

    def refresh(self, config=None, state=None, prefs=None) -> None:
        if config is None:
            config, state, prefs = self._read_all()
        status = Status(config, state, Snapshot(values={}))
        color_remaining = status.temporary_color_remaining()
        shade = icon_shade(active=status.active, color_remaining=color_remaining,
                            needs_recovery=self.needs_recovery, error=self.error)
        try:
            self.icon.icon = create_icon_image(shade, wildcat=prefs.wildcat, light=taskbar_is_light())
        except Exception:
            LOG.exception("icon refresh failed")
        tooltip = tooltip_text(active=status.active, color_remaining=color_remaining,
                               needs_recovery=self.needs_recovery, error=self.error)
        if prefs.clickToSwitch:
            tooltip += " — click to switch, right-click for menu"
        self.icon.title = tooltip[:127]

    # -- lifecycle ------------------------------------------------------------

    def run(self) -> None:
        def setup(icon):
            icon.visible = True
            if self.enable_hotkey:
                self.hotkey.start(self._prefs().shortcut)
            threading.Thread(target=self._tick_loop, daemon=True).start()

        self.icon.run(setup=setup)

    def stop(self) -> None:
        self._stop_tick.set()
        if self.enable_hotkey:
            self.hotkey.stop()


def _install_signal_handlers(tray: EinkTray) -> None:
    """Best-effort: console Ctrl+C/Break still restore the display. A
    forcibly killed process (no signal delivered at all) cannot be caught by
    any process -- that is what crash recovery (spec item 8) is for."""
    def handler(signum, frame):
        try:
            tray.controller.shutdown(resume_schedule_on_launch=True)
        except Exception:
            LOG.exception("shutdown on signal failed")
        finally:
            try:
                tray.icon.stop()
            except Exception:
                pass

    for name in ("SIGTERM", "SIGBREAK", "SIGINT"):
        sig = getattr(signal, name, None)
        if sig is not None:
            try:
                signal.signal(sig, handler)
            except Exception:
                pass


# ----------------------------------------------------------------------
# CLI: `--status/--on/--off/--toggle/--resync` are thin aliases kept for
# back-compat with v0's flags, all delegating straight to `Controller` (the
# same object the tray and hotkey use) or, for `--resync` (Windows-only,
# no `eink_cli` equivalent), to `eink_win.resync()`. `eink_cli.py` is the
# real, full CLI surface (PARITY-SPEC.md) -- these exist so a v0 shortcut or
# script calling `eink_tray.py --toggle` keeps working, not as a second
# surface to maintain.
# ----------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--status", action="store_true", help="Print state as JSON and exit")
    group.add_argument("--on", action="store_true", help="Turn E-Ink Mode on, then exit")
    group.add_argument("--off", action="store_true", help="Restore the display, then exit")
    group.add_argument("--toggle", action="store_true", help="Flip E-Ink Mode, then exit")
    group.add_argument("--resync", action="store_true",
                       help="Force the screen to agree with the registry, then exit")
    # Hidden: for the automated smoke test only (see PARITY-SPEC.md "Live-machine
    # rules"). Never used in a real launch.
    parser.add_argument("--smoke-seconds", type=float, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--smoke-hotkey", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    home = home_dir()
    setup_logging(home)
    store = Store(home)
    adapter = _make_adapter(home)
    controller = Controller(store, adapter)

    once = args.status or args.on or args.off or args.toggle or args.resync
    try:
        if not args.status:
            if args.on:
                controller.set_mode(True)
            elif args.off:
                controller.set_mode(False)
            elif args.toggle:
                controller.toggle()
            elif args.resync:
                if os.environ.get("EINK_SIMULATED") != "1":
                    import eink_win
                    eink_win.resync()
        if once:
            print(json.dumps(controller.status().to_dict(), indent=2, sort_keys=True))
            return 0
    except EinkError as error:
        print(str(error), file=sys.stderr)
        return 1

    # A distinct mutex only for the automated smoke test (never for a real
    # launch): the real v0 tray may hold MUTEX_NAME on this machine right
    # now, and the smoke test must not fight it or wait on it.
    mutex_name = (f"Local\\EinkMode.Smoke.{os.getpid()}"
                  if args.smoke_seconds is not None else MUTEX_NAME)
    try:
        with InstanceLock(mutex_name):
            migrate_legacy(store, adapter, legacy_state_path=home / "tray-grayscale.json",
                           legacy_config_path=ROOT / "config.json")
            enable_hotkey = not (args.smoke_seconds is not None and not args.smoke_hotkey)
            tray = EinkTray(store, adapter, enable_hotkey=enable_hotkey)
            _install_signal_handlers(tray)

            state = RuntimeState.from_dict(store.read_json("state.json"))
            if state.session is not None:
                tray.needs_recovery = True
                tray.prompt_recovery()
            else:
                try:
                    controller.tick()
                except Exception:
                    LOG.exception("startup tick failed")

            if not tray._prefs().welcomeShown:
                launch_ui("welcome")

            if args.smoke_seconds is not None:
                def _stop_soon():
                    time.sleep(args.smoke_seconds)
                    tray.stop()
                    tray.icon.stop()
                threading.Thread(target=_stop_soon, daemon=True).start()

            tray.run()
    except RuntimeError as exc:
        message_box(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
