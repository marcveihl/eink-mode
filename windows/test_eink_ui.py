"""Unit tests for `eink_ui`'s testable-without-a-display logic: view-model
helpers, the preview state machine, Run-key command building, and
tray-status staleness. None of this touches Tk, the real registry, or the
real display -- `eink_sim.FakeSystem`/`SimulatedSystem` stand in for the
system adapter, and a temp `EINK_HOME`-equivalent directory stands in for
`%LOCALAPPDATA%\\eink`.

Per PARITY-SPEC.md, tests must never create a Tk window. This file never
constructs `tk.Tk()`; it only imports `eink_ui` (importing `tkinter` is
display-independent) and exercises the pure functions and the `Controller`-
backed helpers directly.
"""

import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from eink_core import Configuration, Controller, EinkError, Schedule, Store
from eink_sim import FakeSystem

import eink_ui


def _tmpdir(prefix: str) -> Path:
    return Path(tempfile.mkdtemp(prefix=prefix))


# ---------------------------------------------------------------------------
# Keyboard shortcut labels
# ---------------------------------------------------------------------------

class ShortcutLabelTests(unittest.TestCase):
    def test_labels_cover_every_core_choice_in_order(self):
        from eink_core import SHORTCUT_CHOICES

        self.assertEqual(tuple(eink_ui.SHORTCUT_ORDER), SHORTCUT_CHOICES)
        for shortcut_id in SHORTCUT_CHOICES:
            self.assertIn(shortcut_id, eink_ui.SHORTCUT_LABELS)

    def test_known_labels_match_the_spec_wording(self):
        self.assertEqual(eink_ui.shortcut_label("ctrl-shift-e"), "Ctrl+Shift+E")
        self.assertEqual(eink_ui.shortcut_label("ctrl-alt-shift-e"), "Ctrl+Alt+Shift+E")
        self.assertEqual(eink_ui.shortcut_label("ctrl-alt-e"), "Ctrl+Alt+E")
        self.assertEqual(eink_ui.shortcut_label("ctrl-alt-shift-g"), "Ctrl+Alt+Shift+G")
        self.assertEqual(eink_ui.shortcut_label("none"), "None")

    def test_unknown_id_falls_back_to_itself(self):
        self.assertEqual(eink_ui.shortcut_label("mystery"), "mystery")

    def test_label_round_trips_to_id(self):
        for shortcut_id, label in eink_ui.shortcut_choices():
            self.assertEqual(eink_ui.shortcut_id_for_label(label), shortcut_id)
        self.assertIsNone(eink_ui.shortcut_id_for_label("Not a real label"))


# ---------------------------------------------------------------------------
# Schedule choice <-> Configuration
# ---------------------------------------------------------------------------

class ScheduleChoiceTests(unittest.TestCase):
    def test_choice_off_when_disabled(self):
        self.assertEqual(eink_ui.schedule_choice(Schedule(enabled=False)), eink_ui.SCHEDULE_OFF)

    def test_choice_evening_when_enabled_and_matches_evening_times(self):
        schedule = Schedule.evening()
        schedule.enabled = True
        self.assertEqual(eink_ui.schedule_choice(schedule), eink_ui.SCHEDULE_EVENING)

    def test_choice_custom_when_enabled_with_other_times(self):
        schedule = Schedule(enabled=True, on=13 * 60, off=6 * 60)
        self.assertEqual(eink_ui.schedule_choice(schedule), eink_ui.SCHEDULE_CUSTOM)

    def test_apply_off(self):
        config = Configuration(schedule=Schedule(enabled=True, on=1, off=2))
        eink_ui.apply_schedule_choice(config, eink_ui.SCHEDULE_OFF)
        self.assertFalse(config.schedule.enabled)

    def test_apply_evening_replaces_times(self):
        config = Configuration(schedule=Schedule(enabled=False, on=1, off=2))
        eink_ui.apply_schedule_choice(config, eink_ui.SCHEDULE_EVENING)
        self.assertTrue(config.schedule.enabled)
        self.assertEqual(config.schedule.on, 21 * 60)
        self.assertEqual(config.schedule.off, 7 * 60)

    def test_apply_custom_only_enables_leaves_times_alone(self):
        config = Configuration(schedule=Schedule(enabled=False, on=100, off=200))
        eink_ui.apply_schedule_choice(config, eink_ui.SCHEDULE_CUSTOM)
        self.assertTrue(config.schedule.enabled)
        self.assertEqual(config.schedule.on, 100)
        self.assertEqual(config.schedule.off, 200)

    def test_apply_unknown_choice_raises(self):
        with self.assertRaises(ValueError):
            eink_ui.apply_schedule_choice(Configuration(), "sometimes")

    def test_custom_schedule_dirty(self):
        schedule = Schedule(enabled=True, on=21 * 60, off=7 * 60)
        self.assertFalse(eink_ui.custom_schedule_dirty(schedule, 21 * 60, 7 * 60))
        self.assertTrue(eink_ui.custom_schedule_dirty(schedule, 22 * 60, 7 * 60))
        self.assertTrue(eink_ui.custom_schedule_dirty(Schedule(enabled=False, on=1, off=2), 1, 2))


# ---------------------------------------------------------------------------
# Time-field validation
# ---------------------------------------------------------------------------

class TimeValidationTests(unittest.TestCase):
    def test_valid_time(self):
        result = eink_ui.validate_time_field(21, 30)
        self.assertTrue(result.ok)
        self.assertEqual(result.minutes, 21 * 60 + 30)

    def test_invalid_hour(self):
        result = eink_ui.validate_time_field(24, 0)
        self.assertFalse(result.ok)
        self.assertIsNone(result.minutes)

    def test_schedule_times_must_differ(self):
        self.assertIsNone(eink_ui.validate_schedule_times(60, 120))
        error = eink_ui.validate_schedule_times(60, 60)
        self.assertIsNotNone(error)
        self.assertIn("different times", error)


# ---------------------------------------------------------------------------
# PreviewState (AppModel.startPreview/endPreview parity) with a fake clock
# ---------------------------------------------------------------------------

class FakeClock:
    def __init__(self, start: float = 0.0):
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class PreviewStateTests(unittest.TestCase):
    def test_starts_when_inactive_and_not_already_running(self):
        clock = FakeClock()
        preview = eink_ui.PreviewState(duration=10, clock=clock)
        self.assertTrue(preview.start(active=False))
        self.assertTrue(preview.running)
        self.assertEqual(preview.remaining(), 10)

    def test_refuses_when_mode_already_active(self):
        preview = eink_ui.PreviewState(duration=10, clock=FakeClock())
        self.assertFalse(preview.start(active=True))
        self.assertFalse(preview.running)

    def test_refuses_double_start(self):
        clock = FakeClock()
        preview = eink_ui.PreviewState(duration=10, clock=clock)
        self.assertTrue(preview.start(active=False))
        self.assertFalse(preview.start(active=False))

    def test_remaining_counts_down_and_never_negative(self):
        clock = FakeClock()
        preview = eink_ui.PreviewState(duration=10, clock=clock)
        preview.start(active=False)
        clock.advance(4)
        self.assertEqual(preview.remaining(), 6)
        clock.advance(20)
        self.assertEqual(preview.remaining(), 0)

    def test_expired_flips_after_duration(self):
        clock = FakeClock()
        preview = eink_ui.PreviewState(duration=10, clock=clock)
        preview.start(active=False)
        self.assertFalse(preview.expired())
        clock.advance(10)
        self.assertTrue(preview.expired())

    def test_end_allows_restarting(self):
        clock = FakeClock()
        preview = eink_ui.PreviewState(duration=10, clock=clock)
        preview.start(active=False)
        preview.end()
        self.assertFalse(preview.running)
        self.assertTrue(preview.start(active=False))

    def test_remaining_and_expired_are_false_before_starting(self):
        preview = eink_ui.PreviewState(duration=10, clock=FakeClock())
        self.assertEqual(preview.remaining(), 0)
        self.assertFalse(preview.expired())


# ---------------------------------------------------------------------------
# Welcome-guide config change + full flow against a real Controller
# ---------------------------------------------------------------------------

class WelcomeConfigChangeTests(unittest.TestCase):
    def test_dim_sets_brightness_fraction(self):
        config = Configuration(grayscale=False, brightness=None, hideDock=True)
        eink_ui.welcome_config_change(dim=True, brightness_percent=45, hide_taskbar=False)(config)
        self.assertTrue(config.grayscale)
        self.assertAlmostEqual(config.brightness, 0.45)
        self.assertFalse(config.hideDock)

    def test_no_dim_clears_brightness(self):
        config = Configuration(brightness=0.8)
        eink_ui.welcome_config_change(dim=False, brightness_percent=80, hide_taskbar=True)(config)
        self.assertIsNone(config.brightness)
        self.assertTrue(config.hideDock)


class WelcomeFlowIntegrationTests(unittest.TestCase):
    """Exercises the same `Controller.edit`/`set_mode` calls the Welcome
    window's buttons make, end to end, against a `FakeSystem` -- no Tk."""

    def setUp(self):
        self.directory = _tmpdir("eink-ui-welcome-")
        self.system = FakeSystem()
        self.controller = Controller(Store(self.directory), self.system)

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_not_now_saves_config_but_does_not_turn_on(self):
        self.controller.edit(eink_ui.welcome_config_change(True, 40, True))
        status = self.controller.status()
        self.assertAlmostEqual(status.configuration.brightness, 0.40)
        self.assertTrue(status.configuration.hideDock)
        self.assertFalse(status.active)

    def test_turn_on_saves_then_activates(self):
        self.controller.edit(eink_ui.welcome_config_change(False, 50, False))
        self.controller.set_mode(True)
        status = self.controller.status()
        self.assertTrue(status.active)
        self.assertIsNone(status.configuration.brightness)

    def test_preview_profile_is_grayscale_only_and_never_saved(self):
        clock = FakeClock()
        preview = eink_ui.PreviewState(duration=10, clock=clock)
        self.assertTrue(preview.start(active=False))
        self.controller.set_mode(True, manual=False, profile=Configuration())
        self.assertTrue(self.system.values["grayscale"])
        saved = self.controller.status().configuration
        self.assertTrue(saved.grayscale)  # the *saved* profile is untouched (still default)
        self.assertIsNone(saved.brightness)
        clock.advance(10)
        self.assertTrue(preview.expired())
        self.controller.set_mode(False, manual=False)
        self.assertFalse(self.controller.status().active)

    def test_preview_refuses_to_start_while_mode_already_on(self):
        self.controller.set_mode(True)
        active = self.controller.status().active
        preview = eink_ui.PreviewState(duration=10, clock=FakeClock())
        self.assertFalse(preview.start(active=active))


# ---------------------------------------------------------------------------
# Run-key command building / login checkbox truth
# ---------------------------------------------------------------------------

class RunKeyTests(unittest.TestCase):
    def test_build_run_command_quotes_both_paths(self):
        command = eink_ui.build_run_command(r"C:\v\pythonw.exe", r"C:\app\eink_tray.py")
        self.assertEqual(command, r'"C:\v\pythonw.exe" "C:\app\eink_tray.py"')

    def test_default_run_command_points_at_eink_tray_next_to_this_repo(self):
        command = eink_ui.default_run_command(Path(r"C:\myapp"))
        self.assertTrue(command.endswith(r'"C:\myapp\eink_tray.py"'))

    def test_login_enabled_reflects_run_value_not_a_preference(self):
        self.assertFalse(eink_ui.login_enabled(None))
        self.assertFalse(eink_ui.login_enabled(""))
        self.assertTrue(eink_ui.login_enabled('"C:\\x\\pythonw.exe" "C:\\x\\eink_tray.py"'))

    def test_frozen_default_run_command_is_just_the_exes_own_path(self):
        """Frozen (PyInstaller build), the Run key should point straight at
        `EInkMode.exe` -- no pythonw, no `root_dir`, no `eink_tray.py`."""
        with mock.patch.object(sys, "frozen", True, create=True), \
             mock.patch.object(sys, "executable", r"C:\Program Files\EInkMode\EInkMode.exe"):
            command = eink_ui.default_run_command(Path(r"C:\myapp"))
        self.assertEqual(command, r'"C:\Program Files\EInkMode\EInkMode.exe"')


class FakeRunKey:
    """Stands in for `eink_ui.RunKeyAdapter` in tests -- never touches the
    real registry."""

    def __init__(self, initial=None):
        self.value = initial

    def get(self):
        return self.value

    def set(self, command):
        self.value = command

    def delete(self):
        self.value = None


class FakeRunKeyTests(unittest.TestCase):
    def test_round_trip(self):
        run_key = FakeRunKey()
        self.assertFalse(eink_ui.login_enabled(run_key.get()))
        run_key.set(eink_ui.default_run_command(Path("C:/app")))
        self.assertTrue(eink_ui.login_enabled(run_key.get()))
        run_key.delete()
        self.assertFalse(eink_ui.login_enabled(run_key.get()))


# ---------------------------------------------------------------------------
# tray-status.json staleness
# ---------------------------------------------------------------------------

class TrayStatusTests(unittest.TestCase):
    def test_missing_file_gives_fallback_message(self):
        directory = _tmpdir("eink-ui-tray-")
        try:
            self.assertIsNone(eink_ui.load_tray_status(directory))
            self.assertEqual(
                eink_ui.hotkey_message_from_status(None, datetime.now(timezone.utc)),
                eink_ui.FALLBACK_HOTKEY_MESSAGE,
            )
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_fresh_status_shows_its_message(self):
        now = datetime.now(timezone.utc)
        data = {"pid": 123, "hotkey": "ctrl-shift-e",
                "hotkeyMessage": "Ctrl+Shift+E switches E-Ink Mode from any app.",
                "updated": now.isoformat()}
        message = eink_ui.hotkey_message_from_status(data, now + timedelta(seconds=1))
        self.assertEqual(message, "Ctrl+Shift+E switches E-Ink Mode from any app.")

    def test_stale_status_falls_back(self):
        now = datetime.now(timezone.utc)
        data = {"updated": (now - timedelta(seconds=30)).isoformat(), "hotkeyMessage": "stale"}
        self.assertEqual(eink_ui.hotkey_message_from_status(data, now), eink_ui.FALLBACK_HOTKEY_MESSAGE)

    def test_missing_updated_field_falls_back(self):
        self.assertEqual(
            eink_ui.hotkey_message_from_status({"hotkeyMessage": "x"}, datetime.now(timezone.utc)),
            eink_ui.FALLBACK_HOTKEY_MESSAGE,
        )

    def test_corrupt_updated_field_falls_back(self):
        data = {"updated": "not-a-timestamp", "hotkeyMessage": "x"}
        self.assertEqual(eink_ui.hotkey_message_from_status(data, datetime.now(timezone.utc)),
                         eink_ui.FALLBACK_HOTKEY_MESSAGE)

    def test_load_tray_status_reads_real_file(self):
        directory = _tmpdir("eink-ui-tray-")
        try:
            path = directory / "tray-status.json"
            path.write_text('{"hotkeyMessage": "hello", "updated": "2026-01-01T00:00:00+00:00"}',
                            encoding="utf-8")
            data = eink_ui.load_tray_status(directory)
            self.assertEqual(data["hotkeyMessage"], "hello")
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_corrupt_file_returns_none(self):
        directory = _tmpdir("eink-ui-tray-")
        try:
            (directory / "tray-status.json").write_text("not json", encoding="utf-8")
            self.assertIsNone(eink_ui.load_tray_status(directory))
        finally:
            shutil.rmtree(directory, ignore_errors=True)


# ---------------------------------------------------------------------------
# Cheap store reads (no adapter.snapshot())
# ---------------------------------------------------------------------------

class StoreReadTests(unittest.TestCase):
    def setUp(self):
        self.directory = _tmpdir("eink-ui-store-")
        self.system = FakeSystem()
        self.controller = Controller(Store(self.directory), self.system)

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_read_config_state_matches_controller_defaults(self):
        config, state = eink_ui.read_config_state(Store(self.directory))
        self.assertTrue(config.grayscale)
        self.assertIsNone(state.session)

    def test_mode_active_tracks_set_mode(self):
        store = Store(self.directory)
        self.assertFalse(eink_ui.mode_active(store))
        self.controller.set_mode(True)
        self.assertTrue(eink_ui.mode_active(store))
        self.controller.set_mode(False)
        self.assertFalse(eink_ui.mode_active(store))

    def test_has_brightness(self):
        self.assertTrue(eink_ui.has_brightness({"brightness:A": 0.5, "grayscale": True}))
        self.assertFalse(eink_ui.has_brightness({"grayscale": True}))


# ---------------------------------------------------------------------------
# Schedule-tab commit helpers against a real Controller
# ---------------------------------------------------------------------------

class ScheduleCommitTests(unittest.TestCase):
    def setUp(self):
        self.directory = _tmpdir("eink-ui-schedule-")
        self.system = FakeSystem()
        self.controller = Controller(Store(self.directory), self.system)

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_choosing_evening_then_reading_schedule_status(self):
        self.controller.edit(lambda c: eink_ui.apply_schedule_choice(c, eink_ui.SCHEDULE_EVENING))
        config, state = eink_ui.read_config_state(Store(self.directory))
        self.assertTrue(config.schedule.enabled)
        self.assertTrue(config.schedule.is_evening)

    def test_custom_times_round_trip(self):
        def change(config):
            config.schedule.on = 20 * 60
            config.schedule.off = 6 * 60
            config.schedule.enabled = True

        self.controller.edit(change)
        config, _state = eink_ui.read_config_state(Store(self.directory))
        self.assertEqual(eink_ui.schedule_choice(config.schedule), eink_ui.SCHEDULE_CUSTOM)
        self.assertEqual(config.schedule.on, 20 * 60)


# ---------------------------------------------------------------------------
# Light/dark theme detection with an injected reader (never the real registry)
# ---------------------------------------------------------------------------

class ThemeDetectionTests(unittest.TestCase):
    def test_reader_result_is_used(self):
        self.assertTrue(eink_ui.detect_light_theme(reader=lambda: 1))
        self.assertFalse(eink_ui.detect_light_theme(reader=lambda: 0))

    def test_reader_failure_falls_back_to_default(self):
        def boom():
            raise OSError("no such key")

        self.assertTrue(eink_ui.detect_light_theme(reader=boom, default=True))
        self.assertFalse(eink_ui.detect_light_theme(reader=boom, default=False))


# ---------------------------------------------------------------------------
# eink_cli.VERSION is importable and non-empty (shown in both windows)
# ---------------------------------------------------------------------------

class VersionTests(unittest.TestCase):
    def test_version_is_a_non_empty_string(self):
        self.assertIsInstance(eink_ui.CLI_VERSION, str)
        self.assertTrue(eink_ui.CLI_VERSION)


if __name__ == "__main__":
    unittest.main()
