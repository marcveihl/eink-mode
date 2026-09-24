"""E-Ink Mode core: a Windows port of macOS `EinkCore`, minus Focus/Pomodoro.

This module owns the state machine every surface (CLI, tray, UI, scheduler)
must share -- P8 from `2.Windows Handoff.md`. It is pure Python, stdlib only,
and never touches the real display or registry: `winreg`/`ctypes` are banned
here so this file stays testable without a Windows session.

Principles ported from the macOS `Controller.swift`, referenced as P1..P9:
  P1  Capture -> Modify -> Restore. Never Enable -> Disable.
  P2  The state file IS the mode (`RuntimeState.session`).
  P3  Fail-safe off: restoring with no session must be a no-op, never throw.
  P7  Only touch a setting when its key is present in the adapter's snapshot.
  P8  One state machine: every command lands in `Controller`.

Journaling contract (do not "simplify" this away -- it's what makes a crashed
process resumable): a session is written with phase "applying" *before* any
`adapter.set` call, "active" once every managed key has been pushed, and
"restoring" before undoing any of them. A failed restore leaves the session
in place (phase "restoring") so a later process can retry; grayscale that
this process never turned on is never cleared, because `restore()` only acts
when `state.session` exists.
"""

from __future__ import annotations

import json
import math
import os
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import date as ddate
from datetime import datetime, timedelta, timezone
from datetime import time as dtime
from pathlib import Path

import msvcrt  # file locking only -- not the registry, not ctypes.


class EinkError(Exception):
    """A user-facing failure. `str(err)` is the one-line message to show."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.message


# --------------------------------------------------------------------------
# Paths (spec: "Shared contract > Paths")
# --------------------------------------------------------------------------

def home_dir() -> Path:
    override = os.environ.get("EINK_HOME")
    if override:
        return Path(override)
    return Path(os.environ["LOCALAPPDATA"]) / "eink"


# --------------------------------------------------------------------------
# Schedule
# --------------------------------------------------------------------------

@dataclass
class Schedule:
    enabled: bool = False
    on: int = 21 * 60
    off: int = 7 * 60

    def validate(self) -> None:
        if not (0 <= self.on < 1440) or not (0 <= self.off < 1440) or self.on == self.off:
            raise EinkError("Schedule needs two different times between 00:00 and 23:59.")

    @staticmethod
    def parse(text: str) -> int:
        parts = text.split(":")
        if len(parts) != 2:
            raise EinkError("Use a 24-hour time such as 21:00.")
        try:
            hour, minute = int(parts[0]), int(parts[1])
        except ValueError:
            raise EinkError("Use a 24-hour time such as 21:00.")
        if not (0 <= hour < 24) or not (0 <= minute < 60):
            raise EinkError("Use a 24-hour time such as 21:00.")
        return hour * 60 + minute

    @staticmethod
    def format(minutes: int) -> str:
        return f"{minutes // 60:02d}:{minutes % 60:02d}"

    @staticmethod
    def evening() -> "Schedule":
        """9:00 PM - 7:00 AM every day. Disabled until the caller enables it."""
        return Schedule(enabled=False, on=21 * 60, off=7 * 60)

    @property
    def is_evening(self) -> bool:
        evening = Schedule.evening()
        return self.on == evening.on and self.off == evening.off

    def boundary(self, at: datetime, tz) -> tuple[datetime, bool]:
        """The most recent on/off boundary at-or-before `at`, and whether it turns
        the mode on. Wall-clock, DST-correct: see `_resolve_wall` below."""
        return _boundary(self, at, tz)

    def next_change(self, after: datetime, tz) -> tuple[datetime, bool]:
        """The next scheduled change strictly after `after`, and whether it turns
        the mode on."""
        return _next_change(self, after, tz)

    def to_dict(self) -> dict:
        return {"enabled": self.enabled, "on": self.on, "off": self.off}

    @classmethod
    def from_dict(cls, d: dict | None) -> "Schedule":
        d = d or {}
        default = cls()
        return cls(
            enabled=d.get("enabled", default.enabled),
            on=d.get("on", default.on),
            off=d.get("off", default.off),
        )


def _valid_local(naive: datetime, tz) -> bool:
    """True unless `naive` falls in a spring-forward gap (it never round-trips
    through UTC and back for either fold of a genuinely nonexistent time)."""
    aware = naive.replace(tzinfo=tz, fold=0)
    back = aware.astimezone(timezone.utc).astimezone(tz).replace(tzinfo=None)
    return back == naive


def _resolve_wall(naive: datetime, tz) -> datetime:
    """Resolve a naive wall-clock time the way Foundation's
    `Calendar.nextDate(matchingPolicy: .nextTime, repeatedTimePolicy: .first)`
    does: an ambiguous (fall-back) time takes its first/earlier occurrence
    (Python's `fold=0` already means this); a nonexistent (spring-forward gap)
    time resolves to the first instant after the gap closes."""
    if _valid_local(naive, tz):
        return naive.replace(tzinfo=tz, fold=0)
    # Binary-search the smallest valid wall time >= naive. Gaps are at most a
    # few hours; widen the search window until its far end is valid.
    lo = naive
    hi = naive + timedelta(hours=6)
    while not _valid_local(hi, tz):
        hi += timedelta(hours=6)
    lo_s, hi_s = 0, int((hi - lo).total_seconds())
    while lo_s < hi_s:
        mid = (lo_s + hi_s) // 2
        if _valid_local(lo + timedelta(seconds=mid), tz):
            hi_s = mid
        else:
            lo_s = mid + 1
    return (lo + timedelta(seconds=lo_s)).replace(tzinfo=tz, fold=0)


def _local_date(at: datetime, tz) -> ddate:
    return at.astimezone(tz).date()


def _boundary(schedule: Schedule, at: datetime, tz) -> tuple[datetime, bool]:
    at_date = _local_date(at, tz)

    def last(minutes: int) -> datetime:
        for offset in range(3):
            day = at_date - timedelta(days=offset)
            naive = datetime.combine(day, dtime(minutes // 60, minutes % 60))
            candidate = _resolve_wall(naive, tz)
            if candidate <= at:
                return candidate
        raise EinkError("Could not resolve a daily schedule boundary.")

    start, end = last(schedule.on), last(schedule.off)
    return (start, True) if start > end else (end, False)


def _next_change(schedule: Schedule, after: datetime, tz) -> tuple[datetime, bool]:
    after_date = _local_date(after, tz)

    def nxt(minutes: int) -> datetime:
        for offset in range(3):
            day = after_date + timedelta(days=offset)
            naive = datetime.combine(day, dtime(minutes // 60, minutes % 60))
            candidate = _resolve_wall(naive, tz)
            if candidate > after:
                return candidate
        raise EinkError("Could not resolve a daily schedule boundary.")

    start, end = nxt(schedule.on), nxt(schedule.off)
    return (start, True) if start < end else (end, False)


def _same_instant(a: datetime | None, b: datetime | None) -> bool:
    """Datetime equality that survives a JSON round-trip.

    `RuntimeState` persists `manualUntilBoundary`/`lastBoundary` as
    ISO-8601 strings and reads them back with `datetime.fromisoformat`, which
    always attaches a fixed-offset `timezone`, never the original
    `zoneinfo.ZoneInfo`. On this interpreter, comparing two aware datetimes
    for the *same instant* with `==` can return False when their `tzinfo`
    objects differ in type/identity, even though `<`/`<=` on the same pair
    correctly agree they are neither less nor greater. Route every boundary
    comparison through this helper instead of bare `==`.
    """
    if a is None or b is None:
        return a is b
    return not (a < b) and not (b < a)


def countdown(interval: float) -> str:
    """Formats a countdown like "4:32"."""
    seconds = max(0, math.ceil(interval))
    return f"{seconds // 60}:{seconds % 60:02d}"


# --------------------------------------------------------------------------
# Configuration (config.json)
# --------------------------------------------------------------------------

@dataclass
class Configuration:
    # Gentle defaults: grayscale only. Brightness and taskbar changes are opt-in.
    grayscale: bool = True
    brightness: float | None = None
    hideDock: bool = False
    reduceMotion: bool = False
    reduceTransparency: bool = False
    schedule: Schedule = field(default_factory=Schedule)

    def validate(self) -> None:
        if self.brightness is not None:
            if not math.isfinite(self.brightness) or not (0.05 <= self.brightness <= 1):
                raise EinkError("Brightness must be 5–100%, or unchanged.")
        self.schedule.validate()

    def to_dict(self) -> dict:
        d = {
            "grayscale": self.grayscale,
            "hideDock": self.hideDock,
            "reduceMotion": self.reduceMotion,
            "reduceTransparency": self.reduceTransparency,
            "schedule": self.schedule.to_dict(),
        }
        if self.brightness is not None:
            d["brightness"] = self.brightness
        return d

    @classmethod
    def from_dict(cls, d: dict | None) -> "Configuration":
        d = d or {}
        default = cls()
        return cls(
            grayscale=d.get("grayscale", default.grayscale),
            brightness=d.get("brightness", default.brightness),
            hideDock=d.get("hideDock", default.hideDock),
            reduceMotion=d.get("reduceMotion", default.reduceMotion),
            reduceTransparency=d.get("reduceTransparency", default.reduceTransparency),
            schedule=Schedule.from_dict(d.get("schedule")),
        )


# --------------------------------------------------------------------------
# System adapter contract: Snapshot / SystemAdapter (a Protocol, duck-typed)
# --------------------------------------------------------------------------

@dataclass
class Snapshot:
    """`values` is JSON-serialisable: bool (flags), float (levels 0.0-1.0), or
    dict (an opaque exact-restore token, e.g. the OS's grayscale filter state).
    A key missing here means this machine cannot control that setting."""

    values: dict
    warnings: list = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"values": self.values, "warnings": list(self.warnings)}


def grayscale_on(value) -> bool:
    """Is `value` (a captured/observed "grayscale" setting) actually showing
    grayscale? A dict is the OS's exact filter state -- only FilterType 0
    ("Grayscale") counts; any other filter (Inverted, Deuteranopia, ...) does
    not. A bool is already the answer."""
    if isinstance(value, dict):
        return bool(value.get("active")) and value.get("filterType") == 0
    return bool(value)


class SystemAdapter:
    """Documentation-only protocol; adapters duck-type this, they need not
    subclass it.

        def snapshot(self) -> Snapshot: ...
        def set(self, key: str, value) -> None: ...   # raises on failure
    """


# --------------------------------------------------------------------------
# RuntimeState (state.json)
# --------------------------------------------------------------------------

@dataclass
class Session:
    started: datetime
    original: dict
    managed: list
    phase: str

    def to_dict(self) -> dict:
        return {
            "started": self.started.isoformat(),
            "original": dict(self.original),
            "managed": list(self.managed),
            "phase": self.phase,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Session":
        return cls(
            started=datetime.fromisoformat(d["started"]),
            original=dict(d.get("original", {})),
            managed=list(d.get("managed", [])),
            phase=d["phase"],
        )


@dataclass
class RuntimeState:
    session: Session | None = None
    manualUntilBoundary: datetime | None = None
    lastBoundary: datetime | None = None
    # While set and in the future, grayscale is lifted without changing the
    # saved profile.
    colorUntil: datetime | None = None

    def to_dict(self) -> dict:
        # Mirrors Swift's synthesized Codable: Optional fields use
        # encodeIfPresent, so a nil value omits the key rather than writing
        # null. `"session" not in state` is how callers detect "not active".
        d = {}
        if self.session is not None:
            d["session"] = self.session.to_dict()
        if self.manualUntilBoundary is not None:
            d["manualUntilBoundary"] = self.manualUntilBoundary.isoformat()
        if self.lastBoundary is not None:
            d["lastBoundary"] = self.lastBoundary.isoformat()
        if self.colorUntil is not None:
            d["colorUntil"] = self.colorUntil.isoformat()
        return d

    @classmethod
    def from_dict(cls, d: dict | None) -> "RuntimeState":
        d = d or {}
        return cls(
            session=Session.from_dict(d["session"]) if d.get("session") is not None else None,
            manualUntilBoundary=datetime.fromisoformat(d["manualUntilBoundary"])
            if d.get("manualUntilBoundary") else None,
            lastBoundary=datetime.fromisoformat(d["lastBoundary"]) if d.get("lastBoundary") else None,
            colorUntil=datetime.fromisoformat(d["colorUntil"]) if d.get("colorUntil") else None,
        )


class Status:
    def __init__(self, configuration: Configuration, state: RuntimeState, system: Snapshot):
        self.configuration = configuration
        self.state = state
        self.system = system

    @property
    def active(self) -> bool:
        return self.state.session is not None

    def temporary_color_remaining(self, now: datetime | None = None) -> float | None:
        now = now or datetime.now(timezone.utc)
        if not self.active:
            return None
        until = self.state.colorUntil
        if until is None or until <= now:
            return None
        return (until - now).total_seconds()

    def to_dict(self) -> dict:
        return {
            "configuration": self.configuration.to_dict(),
            "state": self.state.to_dict(),
            "system": self.system.to_dict(),
        }


# --------------------------------------------------------------------------
# Store: locked, atomic, JSON-on-disk persistence
# --------------------------------------------------------------------------

def _acquire_lock(handle, timeout: float = 30.0) -> None:
    """`msvcrt.locking` already retries internally (10 attempts, 1s apart)
    before raising -- this wraps it in a tighter retry loop instead, so the
    wait is smooth (50ms) and its total budget is explicit and testable."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
            return
        except OSError:
            if time.monotonic() >= deadline:
                raise EinkError("Cannot lock E-Ink state.")
            time.sleep(0.05)


def replace_with_retry(src, dst, attempts: int = 8, delay: float = 0.05) -> None:
    """`os.replace`, retried a handful of times.

    On Windows, a brand-new file can be held open momentarily by the
    indexer or antivirus real-time scan, which makes `os.replace` fail with
    `WinError 5 (Access is denied)` even though nothing in this process is
    still holding it. That is transient, not a real conflict -- our own
    `Store.locked()` is what actually serializes writers -- so retry briefly
    instead of surfacing a spurious failure.
    """
    last_error = None
    for _ in range(attempts):
        try:
            os.replace(src, dst)
            return
        except OSError as error:
            last_error = error
            time.sleep(delay)
    raise last_error


class Store:
    """One directory holding `config.json`, `state.json`, `preferences.json`
    and the `lock` file that makes every read-modify-write against them a
    real cross-process critical section (P2/P8: the state file is the mode,
    so two processes racing on it would corrupt the mode itself)."""

    def __init__(self, directory):
        self.directory = Path(directory)

    @contextmanager
    def locked(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        lock_path = self.directory / "lock"
        handle = open(lock_path, "a+b")
        try:
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b"\0")
                handle.flush()
            handle.seek(0)
            _acquire_lock(handle)
            try:
                yield
            finally:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        finally:
            handle.close()

    def read_json(self, name: str):
        """Returns the parsed JSON, or None if the file does not exist yet.
        Malformed JSON is not silently swallowed: it raises, and the message
        tells the person to keep the file rather than delete it."""
        path = self.directory / name
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise EinkError(f"Cannot read {name}. Preserve this file for recovery: {error}")

    def write_json(self, value, name: str) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        path = self.directory / name
        temporary = self.directory / (name + ".tmp")
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
        replace_with_retry(temporary, path)


# --------------------------------------------------------------------------
# Preferences (preferences.json) -- UI-only, not part of Configuration.
# --------------------------------------------------------------------------

SHORTCUT_CHOICES = ("ctrl-shift-e", "ctrl-alt-shift-e", "ctrl-alt-e", "ctrl-alt-shift-g", "none")


@dataclass
class Preferences:
    clickToSwitch: bool = False
    shortcut: str = "ctrl-shift-e"
    welcomeShown: bool = False
    launchAtLogin: bool = False
    wildcat: bool = False

    def validate(self) -> None:
        if self.shortcut not in SHORTCUT_CHOICES:
            raise EinkError(f"shortcut must be one of {', '.join(SHORTCUT_CHOICES)}")

    def to_dict(self) -> dict:
        return {
            "clickToSwitch": self.clickToSwitch,
            "shortcut": self.shortcut,
            "welcomeShown": self.welcomeShown,
            "launchAtLogin": self.launchAtLogin,
            "wildcat": self.wildcat,
        }

    @classmethod
    def from_dict(cls, d: dict | None) -> "Preferences":
        d = d or {}
        default = cls()
        return cls(
            clickToSwitch=d.get("clickToSwitch", default.clickToSwitch),
            shortcut=d.get("shortcut", default.shortcut),
            welcomeShown=d.get("welcomeShown", default.welcomeShown),
            launchAtLogin=d.get("launchAtLogin", default.launchAtLogin),
            wildcat=d.get("wildcat", default.wildcat),
        )


def load_preferences(home=None) -> Preferences:
    store = Store(home or home_dir())
    with store.locked():
        return Preferences.from_dict(store.read_json("preferences.json"))


def save_preference(key: str, value, home=None) -> Preferences:
    """Persists one preference, validated, atomic, under the store lock --
    every other preference is left exactly as it was."""
    if key not in Preferences.__dataclass_fields__:
        raise EinkError(f"Unknown preference: {key}")
    store = Store(home or home_dir())
    with store.locked():
        prefs = Preferences.from_dict(store.read_json("preferences.json"))
        setattr(prefs, key, value)
        prefs.validate()
        store.write_json(prefs.to_dict(), "preferences.json")
        return prefs


# --------------------------------------------------------------------------
# ScheduleStatus: human-readable schedule state for menus and settings.
# --------------------------------------------------------------------------

def _format_time(dt: datetime, tz) -> str:
    # %#I is the Windows flag for "hour, no leading zero" (spec: plain space,
    # 12-hour "h:mm AM/PM" -- the POSIX equivalent is %-I, not used here).
    return dt.astimezone(tz).strftime("%#I:%M %p")


def _describe(dt: datetime, now: datetime, tz) -> str:
    """"tonight at 9:00 PM", "this morning at 7:00 AM", "today at 3:00 PM",
    "tomorrow at 7:00 AM", or "Saturday at 7:00 AM"."""
    time_str = _format_time(dt, tz)
    local_dt = dt.astimezone(tz)
    local_now = now.astimezone(tz)
    if local_dt.date() == local_now.date():
        hour = local_dt.hour
        if hour >= 17:
            return f"tonight at {time_str}"
        if hour < 12:
            return f"this morning at {time_str}"
        return f"today at {time_str}"
    if local_dt.date() == local_now.date() + timedelta(days=1):
        return f"tomorrow at {time_str}"
    return f"{local_dt.strftime('%A')} at {time_str}"


class ScheduleStatus:
    def __init__(self, configuration: Configuration, state: RuntimeState,
                 now: datetime | None = None, tz=None):
        now = now or datetime.now(tz or timezone.utc)
        tz = tz or now.tzinfo or timezone.utc
        schedule = configuration.schedule
        self.enabled = schedule.enabled
        active = state.session is not None
        if not schedule.enabled:
            self.manualOverride = False
            self.nextChange = None
            self.turnsOn = False
            self.short = "Off"
            self.detail = "E-Ink Mode changes only when you switch it."
            return
        next_date, turns_on = schedule.next_change(now, tz)
        self.nextChange = next_date
        self.turnsOn = turns_on
        current_date, current_active = schedule.boundary(now, tz)
        self.manualOverride = (
            state.manualUntilBoundary is not None
            and _same_instant(state.manualUntilBoundary, current_date)
            and active != current_active
        )
        when = _describe(next_date, now, tz)
        time_str = _format_time(next_date, tz)
        if self.manualOverride:
            self.short = f"{'On' if active else 'Off'} by hand · resumes {time_str}"
            self.detail = (
                f"You switched E-Ink Mode by hand, so the schedule won't change it "
                f"until {when}. After that it follows the schedule again."
            )
        elif turns_on:
            self.short = f"Turns on {when}"
            self.detail = (
                f"On now. The schedule turns it on again {when}; switching by hand "
                f"pauses the schedule until then."
                if active else
                f"The schedule turns E-Ink Mode on {when}. Switching by hand pauses "
                f"the schedule until its next change."
            )
        else:
            self.short = f"Until {time_str}" if active else f"Turns off {when}"
            self.detail = (
                f"On until {when}. Turning it off by hand pauses the schedule until then."
                if active else
                f"The schedule turns E-Ink Mode off {when}. Switching by hand pauses "
                f"the schedule until its next change."
            )


def local_zone():
    """The machine's current local IANA zone, e.g. `ZoneInfo("America/Chicago")`.

    Resolved fresh on every call -- deliberately not cached anywhere -- so a
    process that runs for weeks (the tray) picks up a Windows time-zone
    change without a restart, the same way `Calendar.autoupdatingCurrent`
    does on macOS. `tzlocal` reaches into the Windows registry for this and
    maps the result to an IANA key; that happens inside `tzlocal`'s own
    module, never via an `import winreg` written in this file. Falls back to
    the process's current fixed UTC offset (not DST-correct across a
    transition, but always available) if `tzlocal` can't resolve one.
    """
    try:
        import tzlocal
        return tzlocal.get_localzone()
    except Exception:
        return datetime.now().astimezone().tzinfo


# --------------------------------------------------------------------------
# Controller (P8: the one state machine)
# --------------------------------------------------------------------------

class Controller:
    """Port of `Controller.swift` minus every Focus/Pomodoro branch. Every
    public method here takes its own `store.locked()` and does not call
    another public method from inside it -- the private `_apply`/`_restore`/
    `_transition` helpers assume the lock is already held, exactly like the
    Swift original, so there is never a nested-lock deadlock risk."""

    def __init__(self, store: Store, adapter, tz=None):
        self.store = store
        self.adapter = adapter
        # Injectable for DST tests (pass a `zoneinfo.ZoneInfo` and every call
        # uses exactly that zone). `None` means "local, resolved fresh on
        # every use" -- see `_tz()` -- which is the real callers' default.
        self.tz = tz

    def _tz(self):
        return self.tz if self.tz is not None else local_zone()

    def _resolve_now(self, now: datetime | None) -> datetime:
        return now if now is not None else datetime.now(self._tz())

    def _configuration(self) -> Configuration:
        config = Configuration.from_dict(self.store.read_json("config.json"))
        config.validate()
        return config

    def _state(self) -> RuntimeState:
        return RuntimeState.from_dict(self.store.read_json("state.json"))

    def _save_state(self, state: RuntimeState) -> None:
        self.store.write_json(state.to_dict(), "state.json")

    # -- Public API (spec: "Controller API (P8)") --------------------------

    def status(self) -> Status:
        with self.store.locked():
            return Status(configuration=self._configuration(), state=self._state(),
                          system=self.adapter.snapshot())

    def set_mode(self, active: bool, manual: bool = True, profile: Configuration | None = None,
                 now: datetime | None = None) -> None:
        """`profile` activates with a one-off configuration (e.g. a first-run
        preview) without saving it."""
        now = self._resolve_now(now)
        with self.store.locked():
            state = self._state()
            if not active:
                if manual:
                    config = self._try_configuration()
                    state.manualUntilBoundary = (
                        config.schedule.boundary(now, self._tz())[0]
                        if config is not None and config.schedule.enabled else None
                    )
                    self._save_state(state)
                self._restore(state, now)
                return
            saved = self._configuration()
            if profile is not None:
                profile.validate()
            if manual:
                state.manualUntilBoundary = (
                    saved.schedule.boundary(now, self._tz())[0] if saved.schedule.enabled else None
                )
                self._save_state(state)
            self._transition(True, profile if profile is not None else saved, state, now)

    def shutdown(self, resume_schedule_on_launch: bool, now: datetime | None = None) -> None:
        """Restores the display for app exit. A deliberate quit pauses the
        schedule until its next change; a logout/restart lets the next launch
        catch up to the current period."""
        now = self._resolve_now(now)
        if not resume_schedule_on_launch:
            self.set_mode(False, now=now)
            return
        with self.store.locked():
            state = self._state()
            was_active = state.session is not None
            self._restore(state, now)
            if was_active:
                state.lastBoundary = None
                state.manualUntilBoundary = None
                self._save_state(state)

    def toggle(self, now: datetime | None = None) -> None:
        now = self._resolve_now(now)
        with self.store.locked():
            state = self._state()
            if state.session is not None:
                config = self._try_configuration()
                state.manualUntilBoundary = (
                    config.schedule.boundary(now, self._tz())[0]
                    if config is not None and config.schedule.enabled else None
                )
                self._save_state(state)
                self._restore(state, now)
            else:
                config = self._configuration()
                state.manualUntilBoundary = (
                    config.schedule.boundary(now, self._tz())[0] if config.schedule.enabled else None
                )
                self._save_state(state)
                self._transition(True, config, state, now)

    def update(self, config: Configuration, now: datetime | None = None) -> None:
        now = self._resolve_now(now)
        with self.store.locked():
            self._update_locked(config, now)

    def edit(self, change, now: datetime | None = None) -> None:
        """`change(config)` mutates a `Configuration` in place."""
        now = self._resolve_now(now)
        with self.store.locked():
            config = self._configuration()
            change(config)
            self._update_locked(config, now)

    def tick(self, now: datetime | None = None) -> None:
        now = self._resolve_now(now)
        with self.store.locked():
            state = self._state()
            self._tick_locked(self._configuration(), state, now)

    def resume(self, now: datetime | None = None) -> None:
        now = self._resolve_now(now)
        with self.store.locked():
            state = self._state()
            if state.session is None:
                return
            if state.colorUntil is not None and state.colorUntil <= now:
                state.colorUntil = None
            self._apply(self._configuration(), state, now)

    def start_temporary_color(self, seconds: float = 300, now: datetime | None = None) -> None:
        """Lifts grayscale for a while; every other profile setting stays
        applied and the saved profile is untouched."""
        now = self._resolve_now(now)
        with self.store.locked():
            state = self._state()
            config = self._configuration()
            if state.session is None:
                raise EinkError("Turn on E-Ink Mode first.")
            if not config.grayscale:
                raise EinkError("Grayscale is already off in your profile.")
            state.colorUntil = now + timedelta(seconds=seconds)
            self._apply(config, state, now)

    def end_temporary_color(self, now: datetime | None = None) -> None:
        now = self._resolve_now(now)
        with self.store.locked():
            state = self._state()
            if state.colorUntil is None:
                return
            state.colorUntil = None
            self._save_state(state)
            if state.session is not None:
                self._apply(self._configuration(), state, now)

    # -- Internals (assume the lock is already held) ------------------------

    def _try_configuration(self) -> Configuration | None:
        """`try?` in Swift: an intact restoration journal remains usable even
        if config.json is damaged, so reading it for `manualUntilBoundary`
        purposes must swallow any error."""
        try:
            return self._configuration()
        except Exception:
            return None

    def _update_locked(self, config: Configuration, now: datetime) -> None:
        config.validate()
        previous = self._configuration()
        state = self._state()
        self.store.write_json(config.to_dict(), "config.json")
        if previous.schedule != config.schedule:
            state.lastBoundary = None
            state.manualUntilBoundary = None
            self._save_state(state)
        if state.session is not None:
            self._apply(config, state, now)
        if previous.schedule != config.schedule:
            self._tick_locked(config, state, now)

    def _tick_locked(self, config: Configuration, state: RuntimeState, now: datetime) -> None:
        if state.colorUntil is not None and state.colorUntil <= now:
            state.colorUntil = None
            self._save_state(state)
            if state.session is not None:
                self._apply(config, state, now)
        if not config.schedule.enabled:
            return
        boundary_date, boundary_active = config.schedule.boundary(now, self._tz())
        if state.manualUntilBoundary is not None and _same_instant(state.manualUntilBoundary, boundary_date):
            return
        if _same_instant(state.lastBoundary, boundary_date):
            return
        self._transition(boundary_active, config, state, now)
        state.lastBoundary = boundary_date
        state.manualUntilBoundary = None
        self._save_state(state)

    def _transition(self, active: bool, config: Configuration, state: RuntimeState,
                     now: datetime) -> None:
        if active:
            if state.session is not None:
                return
            snapshot = self.adapter.snapshot()
            if "grayscale" not in snapshot.values:
                raise EinkError("Native grayscale is unavailable on this machine.")
            state.session = Session(started=now, original=dict(snapshot.values), managed=[],
                                     phase="applying")
            self._save_state(state)
            try:
                self._apply(config, state, now)
            except Exception as original_error:
                try:
                    self._restore(state, now)
                except Exception as restore_error:
                    raise EinkError(
                        f"Activation failed: {original_error}. "
                        f"Restoration needs retry: {restore_error}"
                    ) from original_error
                raise
        else:
            self._restore(state, now)

    def _desired(self, config: Configuration, original: dict) -> dict:
        values = {"grayscale": bool(config.grayscale)}
        if config.hideDock:
            values["dock"] = True
        if config.reduceMotion:
            values["motion"] = True
        if config.reduceTransparency:
            values["transparency"] = True
        if config.brightness is not None:
            for key in original:
                if key.startswith("brightness:"):
                    values[key] = config.brightness
        return {key: value for key, value in values.items() if key in original}

    def _apply(self, config: Configuration, state: RuntimeState, now: datetime) -> None:
        if state.session is None:
            return
        if state.session.phase == "restoring":
            raise EinkError("Restore the unfinished session before changing settings.")
        effective_grayscale = config.grayscale
        if state.colorUntil is not None and state.colorUntil > now:
            effective_grayscale = False  # temporary color wins while it lasts
        effective = Configuration(
            grayscale=effective_grayscale, brightness=config.brightness, hideDock=config.hideDock,
            reduceMotion=config.reduceMotion, reduceTransparency=config.reduceTransparency,
            schedule=config.schedule,
        )
        session = state.session
        targets = self._desired(effective, session.original)
        keys = sorted(set(targets) | set(session.managed))
        session.phase = "applying"
        session.managed = sorted(set(session.managed) | set(targets.keys()))
        self._save_state(state)  # journal every possible mutation before applying
        try:
            for key in keys:
                value = targets[key] if key in targets else session.original.get(key)
                if value is not None:
                    self.adapter.set(key, value)
            session.phase = "active"
            self._save_state(state)
        except Exception as error:
            raise EinkError(f"Settings could not be fully applied. Restore or retry. {error}")

    def _restore(self, state: RuntimeState, now: datetime | None = None) -> None:
        session = state.session
        if session is None:
            return  # P3/never clear somebody else's grayscale
        session.phase = "restoring"
        self._save_state(state)
        failures = []
        for key in session.managed:
            original = session.original.get(key)
            if original is not None:
                try:
                    self.adapter.set(key, original)
                except Exception as error:
                    failures.append(f"{key}: {error}")
        if failures:
            raise EinkError("\n".join(failures))
        state.session = None
        state.colorUntil = None
        self._save_state(state)
