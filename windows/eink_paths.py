"""eink_paths.py -- frozen-aware helpers for relaunching this application.

E-Ink Mode ships two ways: as `python eink_tray.py` / `python eink_ui.py`
from a checkout (dev), or as a PyInstaller `--onedir` build where
`EInkMode.exe` is `eink_app.py` frozen -- `getattr(sys, "frozen", False)` is
then True and `sys.executable` is `EInkMode.exe` itself, which dispatches on
argv (see `eink_app.py`: no args -> tray, `ui ...` -> `eink_ui`, `cli ...` ->
`eink_cli`).

Every place that spawns a sibling process or builds a command line (tray
`launch_ui`, Settings' "Show Welcome Guide" `spawn_window`, the HKCU Run key
for "Open at login") goes through this module, so there is exactly one
frozen/dev branch to keep straight instead of one per call site.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def pythonw_executable() -> str:
    """The venv's pythonw.exe next to the running interpreter, falling back
    to the interpreter itself if pythonw.exe isn't there (a bare CPython
    install). Only meaningful unfrozen -- a frozen build never calls this."""
    exe = Path(sys.executable)
    candidate = exe.with_name("pythonw.exe")
    return str(candidate) if candidate.exists() else str(exe)


def ui_argv(*args: str) -> list[str]:
    """argv to launch `eink_ui.py` with the given subcommand/args as a
    separate process. Frozen: `EInkMode.exe ui <args>` (`eink_app.py`
    dispatches "ui" to `eink_ui.main`). Dev: `pythonw.exe <abs>/eink_ui.py
    <args>` -- exactly what running from a checkout has always done."""
    if is_frozen():
        return [sys.executable, "ui", *args]
    return [pythonw_executable(), str(ROOT / "eink_ui.py"), *args]


def run_key_command() -> str:
    """The HKCU Run value that relaunches the tray at login. Frozen: the
    exe's own quoted path (no args -- `EInkMode.exe` with no argv opens the
    tray). Dev: `"pythonw.exe" "<abs>/eink_tray.py"`, quoted for the
    registry, matching what `eink_ui.build_run_command` has always built."""
    if is_frozen():
        return f'"{sys.executable}"'
    return f'"{pythonw_executable()}" "{ROOT / "eink_tray.py"}"'
