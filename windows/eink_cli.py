#!/usr/bin/env python3
"""`eink` -- the command-line surface for E-Ink Mode, mirroring macOS `eink`
minus everything Focus/Pomodoro (out of scope on Windows per PARITY-SPEC.md).

  eink status | on | off | toggle | version
  eink color [minutes]        show color temporarily (default 5), then return to grayscale
  eink grayscale              end temporary color now
  eink config                 show configuration
  eink set grayscale|dock|motion|transparency on|off
  eink set brightness 5..100|unchanged
  eink set schedule evening|on|off
  eink set schedule-on|schedule-off HH:MM

EINK_HOME selects an isolated config/state directory (default
%LOCALAPPDATA%\\eink). EINK_SIMULATED=1 swaps in `SimulatedSystem` so nothing
here ever has to touch the real display or registry (P3).

Exit 0 on success; on error, exit 1 with a one-line message on stderr -- one
state machine (`eink_core.Controller`, P8) behind every command, so the tray
and the scheduler get the exact same behaviour this CLI does.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from eink_core import Configuration, Controller, EinkError, Schedule, Store, home_dir

VERSION = "0.1.0"

USAGE = """E-Ink Mode
  eink status | on | off | toggle | version
  eink color [minutes]        show color temporarily (default 5), then return to grayscale
  eink grayscale              end temporary color now
  eink config                 show configuration
  eink set grayscale|dock|motion|transparency on|off
  eink set brightness 5..100|unchanged
  eink set schedule evening|on|off
  eink set schedule-on|schedule-off HH:MM

EINK_HOME selects an isolated config/state directory; EINK_SIMULATED=1 enables safe simulation.
"""


def _boolean(value: str) -> bool:
    lowered = value.lower()
    if lowered in ("on", "true", "yes"):
        return True
    if lowered in ("off", "false", "no"):
        return False
    raise EinkError("Expected on or off.")


def _make_adapter(home: Path):
    if os.environ.get("EINK_SIMULATED") == "1":
        from eink_sim import SimulatedSystem
        return SimulatedSystem(home / "simulated-system.json")
    # Lazy: eink_win.py belongs to the windows builder and may not exist yet.
    # Only importing it here (and only off the simulated path) keeps this
    # module loadable -- and every test in this repo runnable -- without it.
    from eink_win import WindowsSystem
    return WindowsSystem()


def _apply_set(config: Configuration, key: str, value: str) -> None:
    if key == "grayscale":
        config.grayscale = _boolean(value)
    elif key == "brightness":
        if value == "unchanged":
            config.brightness = None
        else:
            try:
                number = float(value)
            except ValueError:
                raise EinkError("Brightness needs a percentage or unchanged.")
            config.brightness = number / 100
    elif key == "dock":
        config.hideDock = _boolean(value)
    elif key == "motion":
        config.reduceMotion = _boolean(value)
    elif key == "transparency":
        config.reduceTransparency = _boolean(value)
    elif key == "schedule" and value == "evening":
        config.schedule = Schedule.evening()
        config.schedule.enabled = True
    elif key == "schedule":
        config.schedule.enabled = _boolean(value)
    elif key == "schedule-on":
        config.schedule.on = Schedule.parse(value)
    elif key == "schedule-off":
        config.schedule.off = Schedule.parse(value)
    else:
        raise EinkError(USAGE)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    command = argv[0] if argv else "status"

    if command in ("help", "--help", "-h"):
        print(USAGE)
        return 0
    if command in ("version", "--version", "-v"):
        print(f"E-Ink Mode {VERSION}")
        return 0

    try:
        home = home_dir()
        controller = Controller(Store(home), _make_adapter(home))

        if command == "status":
            pass
        elif command == "on":
            controller.set_mode(True)
        elif command == "off":
            controller.set_mode(False)
        elif command == "toggle":
            controller.toggle()
        elif command == "resume":
            controller.resume()
        elif command == "tick":
            controller.tick()
        elif command == "color":
            if len(argv) > 2:
                raise EinkError(USAGE)
            minutes = float(argv[1]) if len(argv) == 2 else 5.0
            if not (1 <= minutes <= 240):
                raise EinkError("Color minutes must be 1-240.")
            controller.start_temporary_color(seconds=minutes * 60)
        elif command == "grayscale":
            controller.end_temporary_color()
        elif command == "config":
            print(json.dumps(controller.status().configuration.to_dict(), indent=2, sort_keys=True))
            return 0
        elif command == "set":
            if len(argv) != 3:
                raise EinkError(USAGE)
            key, value = argv[1], argv[2]
            controller.edit(lambda config: _apply_set(config, key, value))
        else:
            raise EinkError(USAGE)

        print(json.dumps(controller.status().to_dict(), indent=2, sort_keys=True))
    except EinkError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception as error:  # P3 - never crash bare; always a one-line message
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
