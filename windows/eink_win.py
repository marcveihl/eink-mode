"""WindowsSystem: the SystemAdapter for E-Ink Mode's Windows port.

Implements the `SystemAdapter` protocol from `PARITY-SPEC.md` (`snapshot()` /
`set()`) for five keys: `grayscale`, `brightness:<InstanceName>`, `dock`,
`transparency`, `motion`. `eink_core.py` (owned by another builder) drives this
module through that protocol only -- it never touches `winreg`/`ctypes`/WMI
itself.

Principles from `2.Windows Handoff.md`, referenced as P1..P9:
  P1  Capture -> Modify -> Restore. Never Enable -> Disable. (the core's job;
      this module just reports exact state and applies exact state.)
  P3  Fail-safe: a failing subsystem in snapshot() becomes a warning and a
      missing key, never an exception -- see `Snapshot.warnings`.
  P5  Drive the same switch the Settings UI drives.
  P7  Only act -- press a key, bounce a shell, write a byte -- when the
      current value actually differs from the target. Every setter here is
      checked for a no-op first.

The one thing not to re-break (`..\\pick_up.md`): writing
`HKCU\\Software\\Microsoft\\ColorFiltering\\Active` persists but does not
apply on this machine (build 26200). Only Win+Ctrl+C applies it, and reading
`Active` back afterwards is the only verification there is. This module NEVER
writes `Active`. The hotkey algorithm below (`press_hotkey`, `set_active`,
`set_filter_type`, `resync`) is the same one proven in `eink_tray.ColorFilter`
-- reproduced here verbatim rather than imported, so this module does not
depend on the tray's internals.
"""

from dataclasses import dataclass, field
import ctypes
from ctypes import wintypes
import time
import winreg

# use_last_error=True is required for ctypes.get_last_error() to reflect the
# real GetLastError() value after a call through this handle -- without it,
# ctypes never captures the thread-local error and get_last_error() is always 0.
_user32 = ctypes.WinDLL("user32", use_last_error=True)
_shell32 = ctypes.WinDLL("shell32", use_last_error=True)

try:
    from eink_core import Snapshot  # type: ignore
except ImportError:
    @dataclass
    class Snapshot:
        """Fallback used until `eink_core.Snapshot` exists (PARITY-SPEC.md)."""
        values: dict = field(default_factory=dict)
        warnings: list = field(default_factory=list)


class EinkWinError(Exception):
    """A Windows-side setter could not confirm the change took effect."""


# --------------------------------------------------------------------------
# grayscale -- HKCU\Software\Microsoft\ColorFiltering, verbatim from
# eink_tray.ColorFilter (proven on this machine, pick_up.md).
# --------------------------------------------------------------------------

CF_KEY = r"Software\Microsoft\ColorFiltering"
GRAYSCALE = 0  # FilterType value this tool sets; others exist so P1 can restore them.


def read_dword(subkey, name, default=None):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, subkey) as key:
            value, kind = winreg.QueryValueEx(key, name)
    except OSError:
        return default
    return value if kind == winreg.REG_DWORD else default


def write_dword(subkey, name, value):
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, subkey) as key:
        winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, int(value))


def filter_active():
    return read_dword(CF_KEY, "Active", 0) == 1


def current_filter_type():
    return read_dword(CF_KEY, "FilterType", GRAYSCALE)


def press_hotkey():
    """Win+Ctrl+C. Reads `Active`, inverts it, applies that to the screen and
    writes it back -- the only path that applies on build 26200 (pick_up.md).
    Key-up order reverses key-down so the lone Win-up never reaches the shell
    and opens the Start menu. Interactive session only."""
    keyup = 2  # KEYEVENTF_KEYUP
    for vk in (0x5B, 0x11, 0x43):  # LWin, Ctrl, C
        _user32.keybd_event(vk, 0, 0, 0)
    time.sleep(0.04)
    for vk in (0x43, 0x11, 0x5B):
        _user32.keybd_event(vk, 0, keyup, 0)
    time.sleep(0.35)


def set_filter_type(filter_type):
    """A FilterType write does not apply live either, so change it while the
    filter is off and let the next press pick it up (P7 -- skip if already
    the target type)."""
    if current_filter_type() == filter_type:
        return
    was_active = filter_active()
    if was_active:
        press_hotkey()
    write_dword(CF_KEY, "FilterType", filter_type)
    if was_active:
        press_hotkey()


def set_active(target):
    """Idempotent (P7): no press when `Active` already reads as the target.
    Returns whether `Active` confirms the target after acting -- that
    read-back IS the verification (pick_up.md). Never writes `Active` itself."""
    write_dword(CF_KEY, "HotkeyEnabled", 1)  # the only path that applies; keep it on
    if filter_active() == bool(target):
        return True
    press_hotkey()
    return filter_active() == bool(target)


def resync():
    """Two presses: the registry ends where it started and the screen is
    forced to agree with it. The cure for a stale mismatch -- what an older
    tool leaves behind the moment it writes `Active` directly."""
    write_dword(CF_KEY, "HotkeyEnabled", 1)
    press_hotkey()
    press_hotkey()


# --------------------------------------------------------------------------
# brightness -- WMI root\wmi, WmiMonitorBrightness / WmiMonitorBrightnessMethods.
# Internal/laptop panels only; externals over HDMI/DP generally don't expose
# this (they'd need DDC/CI), and a desktop with no such panel makes the WMI
# provider throw rather than return zero rows -- both cases collapse to
# "no instances" below, matching the spec's "omit the keys, add a warning".
# --------------------------------------------------------------------------


def _wmi_root():
    import pythoncom
    import win32com.client
    try:
        pythoncom.CoInitialize()
    except Exception:
        pass  # already initialized on this thread -- fine
    return win32com.client.GetObject(r"winmgmts:root\wmi")


def query_brightness_instances():
    """[(InstanceName, CurrentBrightness 0-100)] for every WMI-controllable
    display. Never raises: any failure (no provider, no COM, no rows) means
    "this machine/display can't report it", which is exactly the empty-list
    case the caller already handles."""
    try:
        wmi = _wmi_root()
        rows = wmi.ExecQuery("SELECT InstanceName, CurrentBrightness FROM WmiMonitorBrightness")
        return [(row.InstanceName, int(row.CurrentBrightness)) for row in rows]
    except Exception:
        return []


def set_brightness_instance(instance_name, percent):
    """Call WmiSetBrightness on the WmiMonitorBrightnessMethods instance whose
    InstanceName pairs with `instance_name`. Raises EinkWinError if it can't
    be found or the WMI call fails."""
    try:
        wmi = _wmi_root()
        rows = wmi.ExecQuery("SELECT * FROM WmiMonitorBrightnessMethods")
        for row in rows:
            if row.InstanceName == instance_name:
                row.WmiSetBrightness(0, int(percent))
                return
    except Exception as exc:
        raise EinkWinError(f"brightness: WMI set failed for {instance_name}: {exc}") from exc
    raise EinkWinError(f"brightness: no controllable display named {instance_name}")


# --------------------------------------------------------------------------
# dock -- taskbar auto-hide via SHAppBarMessage. Instant, no Explorer restart
# (P7 -- handoff section 4.3 / PARITY-SPEC P7).
# --------------------------------------------------------------------------

ABM_GETSTATE = 0x4
ABM_SETSTATE = 0xA
ABS_AUTOHIDE = 0x1
ABS_ALWAYSONTOP = 0x2


class _RECT(ctypes.Structure):
    _fields_ = [("left", wintypes.LONG), ("top", wintypes.LONG),
                ("right", wintypes.LONG), ("bottom", wintypes.LONG)]


class _APPBARDATA(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("hWnd", wintypes.HWND),
                ("uCallbackMessage", wintypes.UINT), ("uEdge", wintypes.UINT),
                ("rc", _RECT), ("lParam", wintypes.LPARAM)]


def _find_tray_hwnd():
    return _user32.FindWindowW("Shell_TrayWnd", None)


def _appbar_message(msg, data):
    return _shell32.SHAppBarMessage(msg, ctypes.byref(data))


def taskbar_autohide():
    """True/False, or None if there is no taskbar to ask (no Shell_TrayWnd)."""
    hwnd = _find_tray_hwnd()
    if not hwnd:
        return None
    data = _APPBARDATA()
    data.cbSize = ctypes.sizeof(_APPBARDATA)
    data.hWnd = hwnd
    state = _appbar_message(ABM_GETSTATE, data)
    return bool(state & ABS_AUTOHIDE)


def set_taskbar_autohide(on):
    hwnd = _find_tray_hwnd()
    if not hwnd:
        raise EinkWinError("dock: Shell_TrayWnd not found")
    data = _APPBARDATA()
    data.cbSize = ctypes.sizeof(_APPBARDATA)
    data.hWnd = hwnd
    current = bool(_appbar_message(ABM_GETSTATE, data) & ABS_AUTOHIDE)
    if current == bool(on):
        return  # P7 -- no-op
    data.lParam = (ABS_AUTOHIDE | ABS_ALWAYSONTOP) if on else ABS_ALWAYSONTOP
    _appbar_message(ABM_SETSTATE, data)
    # Same rule as grayscale (pick_up.md): the read-back after acting IS the
    # verification. Confirm rather than trust the SETSTATE call succeeded.
    confirmed = bool(_appbar_message(ABM_GETSTATE, data) & ABS_AUTOHIDE)
    if confirmed != bool(on):
        raise EinkWinError(f"dock: auto-hide did not confirm target state ({on})")


# --------------------------------------------------------------------------
# transparency -- HKCU\...\Themes\Personalize, EnableTransparency.
# Key semantics per PARITY-SPEC: True (our "transparency" value) means
# *reduce* transparency, i.e. EnableTransparency = 0.
# --------------------------------------------------------------------------

THEME_KEY = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

WM_SETTINGCHANGE = 0x001A
HWND_BROADCAST = 0xFFFF
SMTO_ABORTIFHUNG = 0x0002


def _broadcast_setting_change(area):
    """Best-effort UI refresh; the registry write is what actually matters, so
    a failure here is never fatal to the setter."""
    try:
        result = wintypes.DWORD()
        _user32.SendMessageTimeoutW(
            HWND_BROADCAST, WM_SETTINGCHANGE, 0, area, SMTO_ABORTIFHUNG, 200, ctypes.byref(result)
        )
    except Exception:
        pass


def transparency_reduced():
    return read_dword(THEME_KEY, "EnableTransparency", 1) == 0


def set_transparency_reduced(reduce):
    target = 0 if reduce else 1
    if read_dword(THEME_KEY, "EnableTransparency", 1) == target:
        return  # P7
    write_dword(THEME_KEY, "EnableTransparency", target)
    _broadcast_setting_change("ImmersiveColorSet")


# --------------------------------------------------------------------------
# motion -- SPI_*CLIENTAREAANIMATION. True (our "motion" value) means
# *reduce* motion, i.e. animations off.
#
# Verified against learn.microsoft.com/windows/win32/api/winuser/nf-winuser-
# systemparametersinfoa (2026-09-23): SPI_GETCLIENTAREAANIMATION is 0x1042
# and SPI_SETCLIENTAREAANIMATION is 0x1043 -- 0x1041 is a different flag,
# SPI_SETDISABLEOVERLAPPEDCONTENT, and writing it would have silently toggled
# the wrong system setting. For both the BOOL travels in pvParam, not
# uiParam: GET wants a pointer to a BOOL to fill in, SET wants the BOOL
# value itself carried directly in the pvParam slot (TRUE/non-null vs
# FALSE/null) -- uiParam is unused (0) for this flag either way.
# --------------------------------------------------------------------------

SPI_GETCLIENTAREAANIMATION = 0x1042
SPI_SETCLIENTAREAANIMATION = 0x1043
SPIF_UPDATEINIFILE = 0x01
SPIF_SENDCHANGE = 0x02


def _spi_get_animation():
    value = wintypes.BOOL()
    ok = _user32.SystemParametersInfoW(
        SPI_GETCLIENTAREAANIMATION, 0, ctypes.byref(value), 0
    )
    if not ok:
        raise EinkWinError(f"motion: SystemParametersInfoW get failed ({ctypes.get_last_error()})")
    return bool(value.value)


def _spi_set_animation(enabled):
    # The BOOL is the pvParam value itself here, not a pointer to one: pass a
    # non-null pointer for True, NULL for False, and 0 (unused) for uiParam.
    pv = ctypes.c_void_p(1) if enabled else ctypes.c_void_p(None)
    ok = _user32.SystemParametersInfoW(
        SPI_SETCLIENTAREAANIMATION, 0, pv, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    )
    if not ok:
        raise EinkWinError(f"motion: SystemParametersInfoW set failed ({ctypes.get_last_error()})")


def motion_reduced():
    return not _spi_get_animation()


def set_motion_reduced(reduce):
    target_animations_enabled = not reduce
    if _spi_get_animation() == target_animations_enabled:
        return  # P7
    _spi_set_animation(target_animations_enabled)


# --------------------------------------------------------------------------
# WindowsSystem -- the SystemAdapter itself.
# --------------------------------------------------------------------------


class WindowsSystem:
    """SystemAdapter for Windows. `snapshot()` reads five kinds of OS state and
    never raises -- each key is captured in its own try/except so one broken
    subsystem yields a warning and a missing key, not a dead snapshot (P3).
    `set()` is the only thing that may raise, and only when it cannot confirm
    the change actually happened (e.g. the grayscale hotkey didn't land) --
    the core keeps its session and can retry.
    """

    def snapshot(self):
        values = {}
        warnings = []
        self._snapshot_grayscale(values, warnings)
        self._snapshot_brightness(values, warnings)
        self._snapshot_dock(values, warnings)
        self._snapshot_transparency(values, warnings)
        self._snapshot_motion(values, warnings)
        return Snapshot(values=values, warnings=warnings)

    def _snapshot_grayscale(self, values, warnings):
        try:
            values["grayscale"] = {"active": filter_active(), "filterType": current_filter_type()}
        except Exception as exc:
            warnings.append(f"Grayscale: {exc}")

    def _snapshot_brightness(self, values, warnings):
        try:
            instances = query_brightness_instances()
        except Exception as exc:  # query_brightness_instances already swallows; belt & braces
            warnings.append(f"Brightness: {exc}")
            return
        if not instances:
            warnings.append("Brightness: this display doesn't let Windows control it")
            return
        for name, percent in instances:
            values[f"brightness:{name}"] = round(percent / 100.0, 4)

    def _snapshot_dock(self, values, warnings):
        try:
            state = taskbar_autohide()
        except Exception as exc:
            warnings.append(f"Taskbar: {exc}")
            return
        if state is None:
            warnings.append("Taskbar: Shell_TrayWnd not found")
            return
        values["dock"] = state

    def _snapshot_transparency(self, values, warnings):
        try:
            values["transparency"] = transparency_reduced()
        except Exception as exc:
            warnings.append(f"Transparency: {exc}")

    def _snapshot_motion(self, values, warnings):
        try:
            values["motion"] = motion_reduced()
        except Exception as exc:
            warnings.append(f"Motion: {exc}")

    def set(self, key, value):
        if key == "grayscale":
            self._set_grayscale(value)
        elif key.startswith("brightness:"):
            self._set_brightness(key, value)
        elif key == "dock":
            set_taskbar_autohide(bool(value))
        elif key == "transparency":
            set_transparency_reduced(bool(value))
        elif key == "motion":
            set_motion_reduced(bool(value))
        else:
            raise KeyError(f"WindowsSystem: unknown key {key!r}")

    def _set_grayscale(self, value):
        # PARITY-SPEC: True -> FilterType 0 then hotkey on; False -> hotkey
        # off (leave FilterType alone); dict -> exact restore of type then
        # active. Never write Active directly (pick_up.md).
        #
        # Order matters when the target is *inactive*: set_filter_type()
        # presses off-then-on again if the filter is currently active and the
        # type differs, so calling it before turning off would flash the
        # restored type on screen for one press (e.g. restoring an Inverted
        # capture while Grayscale is showing would flash Inverted just to
        # immediately turn it off again). Press off first -- one press,
        # straight to colour -- then write the type directly: FilterType
        # does not apply live (handoff P4/P5), so writing it while the
        # filter is already off is silent and needs no further press.
        if isinstance(value, dict):
            filter_type = int(value.get("filterType", GRAYSCALE))
            target_active = bool(value.get("active", False))
        elif value is True:
            filter_type = GRAYSCALE
            target_active = True
        elif value is False:
            filter_type = None  # leave whatever it currently is
            target_active = False
        else:
            raise TypeError(f"grayscale: unsupported value {value!r}")

        if target_active:
            if filter_type is not None:
                set_filter_type(filter_type)
            confirmed = set_active(True)
        else:
            confirmed = set_active(False)
            if confirmed and filter_type is not None:
                write_dword(CF_KEY, "FilterType", filter_type)

        if not confirmed:
            raise EinkWinError(
                "grayscale: Win+Ctrl+C did not confirm the target state; "
                "keep the session and retry"
            )

    def _set_brightness(self, key, value):
        instance_name = key.split(":", 1)[1]
        target_percent = max(0, min(100, round(float(value) * 100)))
        current = dict(query_brightness_instances())
        if instance_name not in current:
            raise EinkWinError(f"brightness: {instance_name} is not WMI-controllable")
        if current[instance_name] == target_percent:
            return  # P7
        set_brightness_instance(instance_name, target_percent)
