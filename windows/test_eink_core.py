"""Unit tests for `eink_core`, ported from the macOS Swift suites minus every
Focus/Pomodoro test (out of scope on Windows per PARITY-SPEC.md):

  ControllerTests.swift      -> ControllerTests            (15 tests)
  ScheduleTests.swift        -> ScheduleTests               (11 tests)
  BetaFeatureTests.swift:
    TemporaryColorTests      -> TemporaryColorTests         (10 tests)
    ScheduleStatusTests      -> ScheduleStatusTests         ( 7 tests)
    UpdateTests               skipped: the auto-updater is tier 4, deferred.
  FocusTests.swift            skipped entirely, per the build contract.

Plus two Windows-specific additions the contract calls for: a round-trip test
for the opaque "grayscale" dict restore token, and a real cross-process
exclusivity test for `Store.locked()`.

Nothing here touches the real display or registry: `FakeSystem` is in-memory,
and `eink_core`/`eink_sim` do not import `winreg` or `ctypes`.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from eink_core import (
    Configuration,
    Controller,
    EinkError,
    RuntimeState,
    Schedule,
    ScheduleStatus,
    Session,
    Store,
    countdown,
    grayscale_on,
    local_zone,
)
from eink_sim import FakeSystem


def _tmpdir(prefix: str) -> Path:
    return Path(tempfile.mkdtemp(prefix=prefix))


# ---------------------------------------------------------------------------
# ControllerTests (ported from ControllerTests.swift)
# ---------------------------------------------------------------------------

class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.directory = _tmpdir("eink-controller-")
        self.system = FakeSystem()
        self.controller = Controller(Store(self.directory), self.system)
        # Opt in to the full profile these tests exercise; defaults are
        # grayscale-only.
        config = Configuration(brightness=0.35, hideDock=True)
        self.controller.update(config)

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_restores_exact_per_display_and_preexisting_accessibility_state(self):
        original = dict(self.system.values)
        self.controller.set_mode(True)
        self.assertEqual(self.system.values["brightness:A"], 0.35)
        self.controller.set_mode(True)  # no recapture
        self.controller.set_mode(False)
        self.assertEqual(self.system.values, original)
        self.assertFalse(self.controller.status().active)

    def test_off_without_session_does_not_clear_existing_grayscale(self):
        original = dict(self.system.values)
        self.controller.set_mode(False)
        self.assertEqual(self.system.values, original)
        self.assertEqual(self.system.writes, 0)

    def test_grayscale_can_change_without_losing_capture_or_exiting_mode(self):
        original = dict(self.system.values)
        self.controller.set_mode(True)
        config = self.controller.status().configuration
        config.grayscale = False
        self.controller.update(config)
        self.assertTrue(self.controller.status().active)
        self.assertEqual(self.system.values["grayscale"], False)
        self.assertEqual(self.system.values["dock"], True)
        self.controller.set_mode(False)
        self.assertEqual(self.system.values, original)

    def test_failed_restore_keeps_journal_and_can_retry_after_restart(self):
        original = dict(self.system.values)
        self.controller.set_mode(True)
        self.system.failure = "grayscale"
        with self.assertRaises(EinkError):
            self.controller.set_mode(False)
        self.assertEqual(self.controller.status().state.session.phase, "restoring")
        self.system.failure = None
        restarted = Controller(Store(self.directory), self.system)
        restarted.set_mode(False)
        self.assertEqual(self.system.values, original)
        self.assertFalse(restarted.status().active)

    def test_disabling_managed_settings_restores_their_original_values_immediately(self):
        original = dict(self.system.values)
        self.controller.set_mode(True)
        config = self.controller.status().configuration
        config.brightness = None
        config.hideDock = False
        config.reduceMotion = True
        self.controller.update(config)
        self.assertEqual(self.system.values["brightness:A"], original["brightness:A"])
        self.assertEqual(self.system.values["dock"], False)
        self.assertEqual(self.system.values["motion"], True)
        self.controller.set_mode(False)
        self.assertEqual(self.system.values, original)

    def test_invalid_config_does_not_change_persisted_config_or_system(self):
        original = dict(self.system.values)
        config = Configuration(brightness=float("nan"))
        with self.assertRaises(EinkError):
            self.controller.update(config)
        expected = Configuration(brightness=0.35, hideDock=True)
        self.assertEqual(self.controller.status().configuration, expected)
        self.assertEqual(self.system.values, original)

    def test_corrupt_state_refuses_mutation(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        (self.directory / "state.json").write_text("broken", encoding="utf-8")
        with self.assertRaises(EinkError):
            self.controller.set_mode(True)
        self.assertEqual(self.system.writes, 0)

    def test_activation_failure_rolls_back_already_applied_settings(self):
        original = dict(self.system.values)
        self.system.fail_once = "grayscale"
        with self.assertRaises(EinkError):
            self.controller.set_mode(True)
        self.assertEqual(self.system.values, original)
        self.assertFalse(self.controller.status().active)

    def test_activation_and_rollback_failure_retain_recovery_journal(self):
        self.system.failure = "grayscale"
        with self.assertRaises(EinkError):
            self.controller.set_mode(True)
        self.assertEqual(self.controller.status().state.session.phase, "restoring")
        self.system.failure = None
        self.controller.set_mode(False)
        self.assertFalse(self.controller.status().active)

    def test_resume_preserves_original_capture_after_restart(self):
        original = dict(self.system.values)
        self.controller.set_mode(True)
        started = self.controller.status().state.session.started
        restarted = Controller(Store(self.directory), self.system)
        self.system.values["grayscale"] = False
        restarted.resume()
        self.assertEqual(self.system.values["grayscale"], True)
        self.assertEqual(restarted.status().state.session.started, started)
        restarted.set_mode(False)
        self.assertEqual(self.system.values, original)

    def test_new_display_is_never_changed_without_an_original_capture(self):
        self.controller.set_mode(True)
        self.system.values["brightness:C"] = 0.91
        config = self.controller.status().configuration
        config.brightness = 0.5
        self.controller.update(config)
        self.assertEqual(self.system.values["brightness:C"], 0.91)
        self.controller.set_mode(False)
        self.assertEqual(self.system.values["brightness:C"], 0.91)

    def test_missing_optional_controls_do_not_prevent_grayscale(self):
        self.system.values = {"grayscale": False}
        self.controller.set_mode(True)
        self.assertEqual(self.system.values, {"grayscale": True})
        self.controller.set_mode(False)
        self.assertEqual(self.system.values, {"grayscale": False})

    def test_missing_grayscale_refuses_activation_without_other_changes(self):
        del self.system.values["grayscale"]
        original = dict(self.system.values)
        with self.assertRaises(EinkError):
            self.controller.set_mode(True)
        self.assertEqual(self.system.values, original)
        self.assertEqual(self.system.writes, 0)

    def test_restore_still_works_when_configuration_is_corrupt(self):
        original = dict(self.system.values)
        self.controller.set_mode(True)
        (self.directory / "config.json").write_text("broken", encoding="utf-8")
        self.controller.set_mode(False)
        self.assertEqual(self.system.values, original)
        state = RuntimeState.from_dict(Store(self.directory).read_json("state.json"))
        self.assertIsNone(state.session)

    def test_atomic_edits_preserve_unrelated_changes(self):
        self.controller.edit(lambda c: setattr(c, "hideDock", False))
        self.controller.edit(lambda c: setattr(c, "reduceMotion", True))
        config = self.controller.status().configuration
        self.assertFalse(config.hideDock)
        self.assertTrue(config.reduceMotion)


# ---------------------------------------------------------------------------
# ScheduleTests (ported from ScheduleTests.swift)
# ---------------------------------------------------------------------------

class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.tz = ZoneInfo("America/Chicago")
        self.directory = _tmpdir("eink-schedule-")
        self.system = FakeSystem()
        self.controller = Controller(Store(self.directory), self.system, tz=self.tz)

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def dt(self, text: str) -> datetime:
        return datetime.fromisoformat(text)

    def enable(self, at: datetime) -> None:
        config = Configuration(schedule=Schedule(enabled=True))
        self.controller.update(config, now=at)

    def test_overnight_boundaries_and_wake_catchup(self):
        self.enable(self.dt("2026-09-16T20:59:00-05:00"))
        self.assertFalse(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-09-16T21:00:00-05:00"))
        self.assertTrue(self.controller.status().active)
        capture = self.controller.status().state.session.started
        self.controller.tick(now=self.dt("2026-09-17T03:00:00-05:00"))
        self.assertEqual(self.controller.status().state.session.started, capture)
        self.controller.tick(now=self.dt("2026-09-17T09:30:00-05:00"))
        self.assertFalse(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-09-19T01:00:00-05:00"))
        self.assertTrue(self.controller.status().active)

    def test_manual_override_persists_across_restart_until_next_boundary(self):
        self.enable(self.dt("2026-09-16T22:00:00-05:00"))
        self.controller.set_mode(False, now=self.dt("2026-09-16T23:00:00-05:00"))
        restarted = Controller(Store(self.directory), self.system, tz=self.tz)
        restarted.tick(now=self.dt("2026-09-17T02:00:00-05:00"))
        self.assertFalse(restarted.status().active)
        restarted.tick(now=self.dt("2026-09-17T21:00:00-05:00"))
        self.assertTrue(restarted.status().active)

    def test_manual_on_during_day_survives_polling(self):
        self.enable(self.dt("2026-09-16T12:00:00-05:00"))
        self.controller.set_mode(True, now=self.dt("2026-09-16T13:00:00-05:00"))
        self.controller.tick(now=self.dt("2026-09-16T14:00:00-05:00"))
        self.assertTrue(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-09-17T07:00:00-05:00"))
        self.assertFalse(self.controller.status().active)

    def test_disabled_schedule_never_activates_at_launch(self):
        self.controller.tick(now=self.dt("2026-09-16T23:00:00-05:00"))
        self.assertFalse(self.controller.status().active)
        self.assertEqual(self.system.writes, 0)

    def test_daytime_schedule_and_identical_time_validation(self):
        config = Configuration(schedule=Schedule(enabled=True, on=9 * 60, off=17 * 60))
        self.controller.update(config, now=self.dt("2026-09-16T12:00:00-05:00"))
        self.assertTrue(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-09-16T17:00:00-05:00"))
        self.assertFalse(self.controller.status().active)
        config.schedule.off = config.schedule.on
        with self.assertRaises(EinkError):
            self.controller.update(config)

    def test_dst_keeps_local_wall_clock_times(self):
        schedule = Schedule()
        self.assertTrue(schedule.boundary(self.dt("2026-03-08T06:59:00-05:00"), self.tz)[1])
        self.assertFalse(schedule.boundary(self.dt("2026-03-08T07:00:00-05:00"), self.tz)[1])
        self.assertTrue(schedule.boundary(self.dt("2026-11-01T01:30:00-05:00"), self.tz)[1])
        self.assertTrue(schedule.boundary(self.dt("2026-11-01T01:30:00-06:00"), self.tz)[1])
        self.assertFalse(schedule.boundary(self.dt("2026-11-01T07:00:00-06:00"), self.tz)[1])

    def test_schedule_changes_reconcile_immediately(self):
        self.enable(self.dt("2026-09-16T20:30:00-05:00"))
        self.assertFalse(self.controller.status().active)
        config = self.controller.status().configuration
        config.schedule.on = 20 * 60
        self.controller.update(config, now=self.dt("2026-09-16T20:30:00-05:00"))
        self.assertTrue(self.controller.status().active)

    def test_time_input_validation(self):
        self.assertEqual(Schedule.parse("21:00"), 1260)
        for text in ["24:00", "21:60", "9pm", "-1:00", "", "21:00:00"]:
            with self.assertRaises(EinkError):
                Schedule.parse(text)

    def test_repeated_dst_hour_has_only_one_daily_boundary(self):
        config = Configuration(schedule=Schedule(enabled=True, on=90))
        self.controller.update(config, now=self.dt("2026-11-01T01:35:00-05:00"))
        self.assertTrue(self.controller.status().active)
        self.controller.set_mode(False, now=self.dt("2026-11-01T01:40:00-05:00"))
        self.controller.tick(now=self.dt("2026-11-01T01:45:00-06:00"))
        self.assertFalse(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-11-02T01:30:00-06:00"))
        self.assertTrue(self.controller.status().active)

    def test_skipped_dst_time_runs_at_next_valid_wall_time(self):
        config = Configuration(schedule=Schedule(enabled=True, on=150))
        self.controller.update(config, now=self.dt("2026-03-08T01:59:00-06:00"))
        self.assertFalse(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-03-08T03:00:00-05:00"))
        self.assertTrue(self.controller.status().active)

    def test_quit_pauses_schedule_but_logout_catches_up_on_next_launch(self):
        self.enable(self.dt("2026-09-16T21:30:00-05:00"))
        self.assertTrue(self.controller.status().active)
        self.controller.shutdown(False, now=self.dt("2026-09-16T22:00:00-05:00"))
        self.controller.tick(now=self.dt("2026-09-16T22:05:00-05:00"))
        self.assertFalse(self.controller.status().active,
                          "a deliberate quit holds until the next boundary")
        self.controller.set_mode(True, now=self.dt("2026-09-16T22:10:00-05:00"))
        self.controller.shutdown(True, now=self.dt("2026-09-16T22:15:00-05:00"))
        self.assertEqual(self.system.values["grayscale"], True,
                          "FakeSystem starts grayscale; restored exactly")
        self.assertFalse(self.controller.status().active)
        self.controller.tick(now=self.dt("2026-09-16T22:20:00-05:00"))
        self.assertTrue(self.controller.status().active,
                         "after logout the schedule resumes on launch")


# ---------------------------------------------------------------------------
# TemporaryColorTests (ported from BetaFeatureTests.swift)
# ---------------------------------------------------------------------------

class TemporaryColorTests(unittest.TestCase):
    def setUp(self):
        self.directory = _tmpdir("eink-color-")
        self.system = FakeSystem()
        self.system.values["grayscale"] = False
        self.controller = Controller(Store(self.directory), self.system)
        self.start = datetime.fromtimestamp(1_800_000_000, tz=timezone.utc)
        config = Configuration(hideDock=True, brightness=0.4)
        self.controller.update(config, now=self.start)

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_defaults_change_grayscale_only(self):
        fresh = Controller(Store(self.directory / "fresh"), self.system)
        before = dict(self.system.values)
        fresh.set_mode(True, now=self.start)
        expected = dict(before)
        expected["grayscale"] = True
        self.assertEqual(self.system.values, expected)
        fresh.set_mode(False, now=self.start)
        self.assertEqual(self.system.values, before)

    def test_color_lifts_grayscale_only_and_returns_automatically(self):
        self.controller.set_mode(True, now=self.start)
        config = self.controller.status().configuration
        self.controller.start_temporary_color(seconds=300, now=self.start)
        self.assertEqual(self.system.values["grayscale"], False)
        self.assertEqual(self.system.values["dock"], True)
        self.assertEqual(self.system.values["brightness:A"], 0.4)
        self.assertEqual(self.controller.status().configuration, config,
                          "saved profile must be untouched")
        remaining = self.controller.status().temporary_color_remaining(
            now=self.start + timedelta(seconds=28))
        self.assertAlmostEqual(remaining, 272, delta=0.01)
        self.controller.tick(now=self.start + timedelta(seconds=299))
        self.assertEqual(self.system.values["grayscale"], False)
        self.controller.tick(now=self.start + timedelta(seconds=300))
        self.assertEqual(self.system.values["grayscale"], True)
        self.assertIsNone(self.controller.status().state.colorUntil)
        self.assertTrue(self.controller.status().active)

    def test_cancel_resumes_grayscale(self):
        self.controller.set_mode(True, now=self.start)
        self.controller.start_temporary_color(now=self.start)
        self.controller.end_temporary_color(now=self.start + timedelta(seconds=10))
        self.assertEqual(self.system.values["grayscale"], True)
        self.assertIsNone(
            self.controller.status().temporary_color_remaining(now=self.start + timedelta(seconds=11)))

    def test_wake_after_expiry_catches_up(self):
        self.controller.set_mode(True, now=self.start)
        self.controller.start_temporary_color(now=self.start)
        # Asleep for an hour: the first tick on wake returns to grayscale.
        self.controller.tick(now=self.start + timedelta(seconds=3600))
        self.assertEqual(self.system.values["grayscale"], True)

    def test_turning_off_during_color_restores_original_and_clears_timer(self):
        original = dict(self.system.values)
        self.controller.set_mode(True, now=self.start)
        self.controller.start_temporary_color(now=self.start)
        self.controller.set_mode(False, now=self.start + timedelta(seconds=5))
        self.assertEqual(self.system.values, original)
        self.assertIsNone(self.controller.status().state.colorUntil)
        self.controller.set_mode(True, now=self.start + timedelta(seconds=10))
        self.assertEqual(self.system.values["grayscale"], True, "a later session starts in grayscale")

    def test_settings_edits_during_color_keep_color_until_expiry(self):
        self.controller.set_mode(True, now=self.start)
        self.controller.start_temporary_color(now=self.start)
        self.controller.edit(lambda c: setattr(c, "reduceMotion", True),
                              now=self.start + timedelta(seconds=20))
        self.assertEqual(self.system.values["grayscale"], False)
        self.assertEqual(self.system.values["motion"], True)

    def test_resume_after_crash_honors_expiry(self):
        self.controller.set_mode(True, now=self.start)
        self.controller.start_temporary_color(now=self.start)
        restarted = Controller(Store(self.directory), self.system)
        restarted.resume(now=self.start + timedelta(seconds=60))
        self.assertEqual(self.system.values["grayscale"], False)
        restarted.resume(now=self.start + timedelta(seconds=600))
        self.assertEqual(self.system.values["grayscale"], True)

    def test_color_requires_active_grayscale_profile(self):
        with self.assertRaises(EinkError):
            self.controller.start_temporary_color(now=self.start)
        self.controller.edit(lambda c: setattr(c, "grayscale", False), now=self.start)
        self.controller.set_mode(True, now=self.start)
        with self.assertRaises(EinkError):
            self.controller.start_temporary_color(now=self.start)

    def test_preview_profile_is_not_saved_and_restores_exactly(self):
        original = dict(self.system.values)
        saved = self.controller.status().configuration
        self.controller.set_mode(True, manual=False, profile=Configuration(), now=self.start)
        self.assertEqual(self.system.values["grayscale"], True)
        self.assertEqual(self.system.values["dock"], original["dock"], "preview must not touch the taskbar")
        self.assertEqual(self.controller.status().configuration, saved)
        self.controller.set_mode(False, manual=False, now=self.start + timedelta(seconds=10))
        self.assertEqual(self.system.values, original)

    def test_countdown_formatting(self):
        self.assertEqual(countdown(272), "4:32")
        self.assertEqual(countdown(299.2), "5:00")
        self.assertEqual(countdown(-3), "0:00")


# ---------------------------------------------------------------------------
# ScheduleStatusTests (ported from BetaFeatureTests.swift)
# ---------------------------------------------------------------------------

class ScheduleStatusTests(unittest.TestCase):
    def setUp(self):
        self.tz = ZoneInfo("America/Chicago")

    def dt(self, text: str) -> datetime:
        return datetime.fromisoformat(text)

    def status(self, config, state=None, at=""):
        return ScheduleStatus(config, state or RuntimeState(), now=self.dt(at), tz=self.tz)

    def evening(self) -> Configuration:
        return Configuration(schedule=Schedule(enabled=True, on=21 * 60, off=7 * 60))

    def active_state(self) -> RuntimeState:
        state = RuntimeState()
        state.session = Session(started=datetime.now(timezone.utc), original={}, managed=[], phase="active")
        return state

    def test_disabled(self):
        self.assertEqual(self.status(Configuration(), at="2026-09-16T12:00:00-05:00").short, "Off")

    def test_turns_on_tonight(self):
        s = self.status(self.evening(), at="2026-09-16T12:00:00-05:00")
        self.assertEqual(s.short, "Turns on tonight at 9:00 PM")
        self.assertTrue(s.turnsOn)

    def test_until_morning_while_active(self):
        self.assertEqual(
            self.status(self.evening(), self.active_state(), at="2026-09-16T23:00:00-05:00").short,
            "Until 7:00 AM")
        self.assertEqual(
            self.status(self.evening(), self.active_state(), at="2026-09-17T02:00:00-05:00").short,
            "Until 7:00 AM")

    def test_this_morning_phrasing(self):
        s = self.status(self.evening(), self.active_state(), at="2026-09-17T00:30:00-05:00")
        self.assertTrue(s.detail.startswith("On until this morning at 7:00 AM"))

    def test_tomorrow_phrasing(self):
        config = self.evening()
        config.schedule.on = 6 * 60
        config.schedule.off = 8 * 60
        self.assertEqual(self.status(config, at="2026-09-16T12:00:00-05:00").short,
                          "Turns on tomorrow at 6:00 AM")

    def test_manual_override_explains_when_schedule_resumes(self):
        state = RuntimeState()
        # Off by hand during the scheduled evening period.
        state.manualUntilBoundary = self.dt("2026-09-16T21:00:00-05:00")
        s = self.status(self.evening(), state, at="2026-09-16T22:00:00-05:00")
        self.assertTrue(s.manualOverride)
        self.assertEqual(s.short, "Off by hand \u00b7 resumes 7:00 AM")
        self.assertIn("won't change it until tomorrow at 7:00 AM", s.detail)

    def test_evening_preset(self):
        self.assertTrue(Schedule.evening().is_evening)
        self.assertEqual(Schedule.format(Schedule.evening().on), "21:00")
        self.assertEqual(Schedule.format(Schedule.evening().off), "07:00")


# ---------------------------------------------------------------------------
# Windows-specific additions: the grayscale dict restore token, a real
# cross-process lock, and a real (DST-aware) default time zone.
# ---------------------------------------------------------------------------

class GrayscaleDictRestoreTests(unittest.TestCase):
    """The Windows adapter's "grayscale" key is a dict (the exact OS filter
    state), not a bool -- P1 needs it to come back byte-for-byte, e.g. a user
    who had "Inverted" on before E-Ink Mode touched anything must get
    "Inverted" back, not plain grayscale-off."""

    def test_grayscale_dict_restore_token_round_trips_exactly(self):
        directory = _tmpdir("eink-grayscale-dict-")
        try:
            system = FakeSystem()
            original_token = {"active": True, "filterType": 1}  # Inverted, already on
            system.values["grayscale"] = original_token
            controller = Controller(Store(directory), system)
            controller.set_mode(True)
            self.assertEqual(system.values["grayscale"], True, "the core only ever sends bools while active")
            controller.set_mode(False)
            self.assertEqual(system.values["grayscale"], original_token)
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_grayscale_on_helper(self):
        self.assertTrue(grayscale_on({"active": True, "filterType": 0}))
        self.assertFalse(grayscale_on({"active": True, "filterType": 1}))
        self.assertFalse(grayscale_on({"active": False, "filterType": 0}))
        self.assertTrue(grayscale_on(True))
        self.assertFalse(grayscale_on(False))


class LocalZoneTests(unittest.TestCase):
    """A `Controller` built with no `tz` must resolve a real IANA zone (not a
    fixed UTC offset frozen at construction time) so a tray running across a
    DST change keeps firing its schedule at the right wall-clock time."""

    def test_local_zone_resolves_to_a_real_iana_zone(self):
        zone = local_zone()
        self.assertTrue(hasattr(zone, "key"), f"expected a zoneinfo.ZoneInfo, got {zone!r}")
        self.assertTrue(zone.key)

    def test_controller_with_no_tz_resolves_local_zone_per_call(self):
        directory = _tmpdir("eink-localzone-")
        try:
            controller = Controller(Store(directory), FakeSystem())
            self.assertIsNone(controller.tz, 'None means "resolve fresh on every use"')
            resolved = controller._tz()
            self.assertTrue(hasattr(resolved, "key"), f"expected a zoneinfo.ZoneInfo, got {resolved!r}")
        finally:
            shutil.rmtree(directory, ignore_errors=True)


class StoreLockTests(unittest.TestCase):
    """`Store.locked()` must be a real cross-process exclusive lock, not just
    an in-process one -- two `eink` invocations racing on the same home
    directory must never interleave their read-modify-write."""

    def test_locked_is_exclusive_across_two_processes(self):
        directory = _tmpdir("eink-lock-")
        try:
            core_dir = str(Path(__file__).resolve().parent)
            script = (
                "import sys, time, json\n"
                f"sys.path.insert(0, {core_dir!r})\n"
                "from eink_core import Store\n"
                f"store = Store({str(directory)!r})\n"
                "with store.locked():\n"
                "    start = time.time()\n"
                "    time.sleep(0.15)\n"
                "    end = time.time()\n"
                "with open(sys.argv[1], 'w', encoding='utf-8') as f:\n"
                "    json.dump({'start': start, 'end': end}, f)\n"
            )
            out1, out2 = directory / "p1.json", directory / "p2.json"
            p1 = subprocess.Popen([sys.executable, "-c", script, str(out1)])
            time.sleep(0.05)  # let p1 take the lock first
            p2 = subprocess.Popen([sys.executable, "-c", script, str(out2)])
            self.assertEqual(p1.wait(timeout=30), 0)
            self.assertEqual(p2.wait(timeout=30), 0)
            r1 = json.loads(out1.read_text(encoding="utf-8"))
            r2 = json.loads(out2.read_text(encoding="utf-8"))
            overlap = max(r1["start"], r2["start"]) < min(r1["end"], r2["end"])
            self.assertFalse(overlap, f"lock was not exclusive: {r1} vs {r2}")
        finally:
            shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
