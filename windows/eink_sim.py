"""System adapters that never touch the real display or registry (P3/tests).

Two adapters live here, both implementing the `SystemAdapter` duck-type from
`eink_core` (`snapshot() -> Snapshot`, `set(key, value) -> None`):

  FakeSystem       In-memory, for `test_eink_core.py`. Mirrors the Swift test
                   double `FakeSystem` in `ControllerTests.swift`: a starting
                   `values` dict you can mutate directly, plus `failure` /
                   `fail_once` to make a specific key's `set()` raise once or
                   every time, and a `writes` counter.

  SimulatedSystem  Persisted to `<home>/simulated-system.json`, for
                   `EINK_SIMULATED=1` (the CLI's process-level tests and any
                   manual dry run). Every `eink` invocation is a fresh process,
                   and several may be queued on `Store.locked()` at once, each
                   having read the file at its own (different) startup time --
                   so every `snapshot()`/`set()` re-reads the file fresh rather
                   than trusting a cached copy. A `set()` that instead wrote
                   back a value cached from process-startup would silently
                   discard whatever another process wrote to *other* keys
                   while this one was queued on the lock.

Neither class imports `winreg` or `ctypes`; that is the whole point of them.
"""

from __future__ import annotations

import json
from pathlib import Path

from eink_core import EinkError, Snapshot, replace_with_retry


class FakeSystem:
    """A small, deliberately unrealistic OS: five keys with distinct types,
    so tests can tell settings apart by their starting value alone."""

    def __init__(self):
        self.values = {
            "grayscale": True,
            "dock": False,
            "motion": False,
            "transparency": True,
            "brightness:A": 0.81234567,
            "brightness:B": 0.62,
        }
        self.failure: str | None = None
        self.fail_once: str | None = None
        self.writes = 0

    def snapshot(self) -> Snapshot:
        return Snapshot(values=dict(self.values))

    def set(self, key: str, value) -> None:
        if self.fail_once == key:
            self.fail_once = None
            raise EinkError("one-shot failure")
        if self.failure == key:
            raise EinkError("simulated failure")
        self.writes += 1
        self.values[key] = value


class SimulatedSystem:
    """Stands in for `WindowsSystem` when `EINK_SIMULATED=1`. Starts with the
    OS's grayscale filter off (the dict form, matching the real adapter's
    contract for that key) and one simulated brightness-controllable display."""

    DEFAULT_VALUES = {
        "grayscale": {"active": False, "filterType": 0},
        "dock": False,
        "motion": False,
        "transparency": False,
        "brightness:simulated": 0.5,
    }

    def __init__(self, path):
        self.path = Path(path)

    def _load(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return dict(self.DEFAULT_VALUES)
        if isinstance(data, dict) and isinstance(data.get("values"), dict):
            return data["values"]
        return dict(self.DEFAULT_VALUES)

    def _save(self, values: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"values": values}, indent=2, sort_keys=True),
                              encoding="utf-8")
        replace_with_retry(temporary, self.path)

    def snapshot(self) -> Snapshot:
        return Snapshot(values=self._load())

    def set(self, key: str, value) -> None:
        values = self._load()
        values[key] = value
        self._save(values)
