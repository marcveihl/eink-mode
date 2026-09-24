"""Unit tests for the pure logic in `eink_tray.py`: the menu model, icon
shading, the shortcut/hotkey-message mapping, the external-change debouncer,
and legacy migration. Nothing here touches the real display, registry,
taskbar, or a global hotkey -- `FakeSystem` and a temp `EINK_HOME` (via
`Store`) stand in throughout, per `PARITY-SPEC.md`.

The Windows-integration half of `eink_tray.py` (icon drawing aside, which is
pure PIL) -- `HotkeyWindow`, `ClickAwareIcon`, `EinkTray`, `main()` -- is
deliberately not unit-tested: there is no pure logic left to extract from it,
and PARITY-SPEC.md forbids a test from touching any of the real resources it
wraps.
"""

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import eink_tray as tray
from eink_core import Configuration, Preferences, RuntimeState, Schedule, Session, Store
from eink_sim import FakeSystem

UTC = timezone.utc
NOW = datetime(2026, 1, 1, 12, 0, tzinfo=UTC)


def _session(now=NOW):
    return Session(started=now, original={"grayscale": False}, managed=["grayscale"], phase="active")


def find(nodes, action):
    """Depth-first search for the first node with this action id."""
    for node in nodes:
        if node is tray.SEPARATOR:
            continue
        if node.action == action:
            return node
        if node.children:
            found = find(node.children, action)
            if found is not None:
                return found
    return None


def labels(nodes):
    return [("---" if n is tray.SEPARATOR else n.label) for n in nodes]


class WrapTests(unittest.TestCase):
    def test_short_text_is_one_line(self):
        self.assertEqual(tray.wrap("On now.", 46), "On now.")

    def test_wraps_at_width_without_breaking_words(self):
        text = ("On now. The schedule turns it on again tonight at 9:00 PM; "
                "switching by hand pauses the schedule until then.")
        wrapped = tray.wrap(text, 46)
        for line in wrapped.split("\n"):
            self.assertLessEqual(len(line), 46, line)
        self.assertEqual(wrapped.replace("\n", " "), text)


class ShortcutTests(unittest.TestCase):
    def test_symbol_for_each_choice(self):
        self.assertEqual(tray.shortcut_symbol("ctrl-shift-e"), "Ctrl+Shift+E")
        self.assertEqual(tray.shortcut_symbol("ctrl-alt-shift-e"), "Ctrl+Alt+Shift+E")
        self.assertEqual(tray.shortcut_symbol("ctrl-alt-e"), "Ctrl+Alt+E")
        self.assertEqual(tray.shortcut_symbol("ctrl-alt-shift-g"), "Ctrl+Alt+Shift+G")
        self.assertEqual(tray.shortcut_symbol("none"), "")

    def test_every_spec_key_combo_is_distinct(self):
        combos = {(spec.modifiers, spec.vk) for spec in tray.SHORTCUT_SPECS.values()}
        self.assertEqual(len(combos), len(tray.SHORTCUT_SPECS))

    def test_hotkey_message_wording(self):
        self.assertEqual(tray.hotkey_message("ctrl-shift-e", True),
                         "Ctrl+Shift+E switches E-Ink Mode from any app.")
        self.assertEqual(tray.hotkey_message("ctrl-shift-e", False),
                         "Ctrl+Shift+E is already taken by another app. Choose a different shortcut.")
        self.assertEqual(tray.hotkey_message("none", False), "No keyboard shortcut. Use the tray icon.")


class IconShadeTests(unittest.TestCase):
    def test_off_is_unshaded(self):
        self.assertEqual(tray.icon_shade(active=False, color_remaining=None), "unshaded")

    def test_on_is_shaded(self):
        self.assertEqual(tray.icon_shade(active=True, color_remaining=None), "shaded")

    def test_on_with_color_is_half(self):
        self.assertEqual(tray.icon_shade(active=True, color_remaining=120.0), "half")

    def test_recovery_or_error_wins_over_everything(self):
        self.assertIsNone(tray.icon_shade(active=True, color_remaining=None, needs_recovery=True))
        self.assertIsNone(tray.icon_shade(active=False, color_remaining=None, error="boom"))

    def test_wildcat_style_mapping(self):
        self.assertEqual(tray.icon_shade_to_wildcat_style("unshaded"), "outline")
        self.assertEqual(tray.icon_shade_to_wildcat_style("shaded"), "filled")
        self.assertEqual(tray.icon_shade_to_wildcat_style("half"), "half")


class TooltipTests(unittest.TestCase):
    def test_off(self):
        self.assertEqual(tray.tooltip_text(active=False, color_remaining=None), "E-Ink Mode · Off")

    def test_on(self):
        self.assertEqual(tray.tooltip_text(active=True, color_remaining=None), "E-Ink Mode · On")

    def test_on_with_color_counts_down(self):
        text = tray.tooltip_text(active=True, color_remaining=272.0)
        self.assertIn("On, showing color", text)
        self.assertIn("4:32", text)

    def test_recovery_or_error_overrides(self):
        self.assertEqual(tray.tooltip_text(active=True, color_remaining=None, needs_recovery=True),
                         "E-Ink Mode needs attention")
        self.assertEqual(tray.tooltip_text(active=True, color_remaining=None, error="x"),
                         "E-Ink Mode needs attention")


class MenuViewTests(unittest.TestCase):
    def test_off_header_and_toggle(self):
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=Preferences(),
                               now=NOW, tz=UTC)
        self.assertEqual(nodes[0].label, "E-Ink Mode · Off")
        self.assertFalse(nodes[0].enabled)
        toggle = nodes[1]
        self.assertEqual(toggle.label, "Turn On\tCtrl+Shift+E")
        self.assertEqual(toggle.action, "turn_on")
        self.assertTrue(toggle.enabled)
        self.assertIsNone(find(nodes, "color_5"))

    def test_no_shortcut_symbol_when_none(self):
        prefs = Preferences(shortcut="none")
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=prefs, now=NOW, tz=UTC)
        self.assertEqual(nodes[1].label, "Turn On")

    def test_active_shows_turn_off_and_color_option(self):
        state = RuntimeState(session=_session())
        nodes = tray.menu_view(config=Configuration(grayscale=True), state=state, prefs=Preferences(),
                               now=NOW, tz=UTC)
        self.assertEqual(nodes[0].label, "E-Ink Mode · On")
        self.assertEqual(nodes[1].action, "turn_off")
        color_item = find(nodes, "color_5")
        self.assertIsNotNone(color_item)
        self.assertEqual(color_item.label, "Color for 5 Minutes")

    def test_active_without_grayscale_in_profile_has_no_color_option(self):
        state = RuntimeState(session=_session())
        nodes = tray.menu_view(config=Configuration(grayscale=False), state=state, prefs=Preferences(),
                               now=NOW, tz=UTC)
        self.assertIsNone(find(nodes, "color_5"))
        self.assertIsNone(find(nodes, "end_color"))

    def test_temporary_color_shows_countdown_and_header(self):
        state = RuntimeState(session=_session(), colorUntil=NOW + timedelta(seconds=272))
        nodes = tray.menu_view(config=Configuration(grayscale=True), state=state, prefs=Preferences(),
                               now=NOW, tz=UTC)
        self.assertEqual(nodes[0].label, "E-Ink Mode · On, showing color")
        end_item = find(nodes, "end_color")
        self.assertEqual(end_item.label, "Resume grayscale · 4:32 remaining")
        self.assertIsNone(find(nodes, "color_5"))

    def test_recovery_prepends_and_disables_toggle(self):
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=Preferences(),
                               now=NOW, tz=UTC, needs_recovery=True)
        self.assertEqual(nodes[0].label, "Unfinished session found")
        self.assertEqual(nodes[1].action, "restore_display")
        self.assertEqual(nodes[2].action, "continue_session")
        self.assertIs(nodes[3], tray.SEPARATOR)
        toggle = find(nodes, "turn_on")
        self.assertFalse(toggle.enabled)

    def test_error_prepends_truncated_message_and_restore(self):
        error = "x" * 90
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=Preferences(),
                               now=NOW, tz=UTC, error=error)
        self.assertTrue(nodes[0].label.startswith("⚠"))
        detail = nodes[1]
        self.assertEqual(detail.action, "show_error")
        self.assertTrue(detail.label.endswith("…"))
        self.assertEqual(len(detail.label), 61)
        self.assertEqual(detail.tooltip, error)
        self.assertEqual(nodes[2].action, "restore_display")
        # The normal menu still follows -- error never replaces it.
        self.assertIn("E-Ink Mode · Off", labels(nodes))

    def test_error_shorter_than_60_is_not_truncated(self):
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=Preferences(),
                               now=NOW, tz=UTC, error="short message")
        detail = find(nodes, "show_error")
        self.assertEqual(detail.label, "short message")

    def test_click_to_switch_tip_only_when_enabled(self):
        nodes_off = tray.menu_view(config=Configuration(), state=RuntimeState(),
                                   prefs=Preferences(clickToSwitch=False), now=NOW, tz=UTC)
        self.assertNotIn("Tip: click the icon to switch · right-click for this menu", labels(nodes_off))
        nodes_on = tray.menu_view(config=Configuration(), state=RuntimeState(),
                                  prefs=Preferences(clickToSwitch=True), now=NOW, tz=UTC)
        self.assertIn("Tip: click the icon to switch · right-click for this menu", labels(nodes_on))

    def test_quit_item_always_present(self):
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=Preferences(),
                               now=NOW, tz=UTC)
        quit_item = find(nodes, "quit")
        self.assertEqual(quit_item.label, "Quit and Restore Display")

    def test_schedule_submenu_off(self):
        nodes = tray.menu_view(config=Configuration(), state=RuntimeState(), prefs=Preferences(),
                               now=NOW, tz=UTC)
        schedule_node = next(n for n in nodes if n.label.startswith("Schedule ·"))
        self.assertEqual(schedule_node.label, "Schedule · Off")
        off_item = next(c for c in schedule_node.children if c.action == "schedule_off")
        self.assertTrue(off_item.checked)
        evening_item = next(c for c in schedule_node.children if c.action == "schedule_evening")
        self.assertFalse(evening_item.checked)
        self.assertIsNone(next((c for c in schedule_node.children if c.action == "schedule_custom"), None))
        edit_item = next(c for c in schedule_node.children if c.action == "edit_schedule")
        self.assertEqual(edit_item.label, "Edit Schedule…")

    def test_schedule_submenu_evening(self):
        config = Configuration(schedule=Schedule.evening())
        config.schedule.enabled = True
        nodes = tray.menu_view(config=config, state=RuntimeState(), prefs=Preferences(), now=NOW, tz=UTC)
        schedule_node = next(n for n in nodes if n.label.startswith("Schedule ·"))
        evening_item = next(c for c in schedule_node.children if c.action == "schedule_evening")
        self.assertTrue(evening_item.checked)
        self.assertEqual(evening_item.label, "Evening · 9:00 PM – 7:00 AM")
        self.assertIsNone(next((c for c in schedule_node.children if c.action == "schedule_custom"), None))

    def test_schedule_submenu_custom(self):
        config = Configuration(schedule=Schedule(enabled=True, on=20 * 60, off=6 * 60))
        nodes = tray.menu_view(config=config, state=RuntimeState(), prefs=Preferences(), now=NOW, tz=UTC)
        schedule_node = next(n for n in nodes if n.label.startswith("Schedule ·"))
        custom_item = next(c for c in schedule_node.children if c.action == "schedule_custom")
        self.assertTrue(custom_item.checked)
        self.assertEqual(custom_item.label, "Custom · 20:00 – 06:00")
        detail_note = next(c for c in schedule_node.children
                           if c.action is None and c is not tray.SEPARATOR)
        for line in detail_note.label.split("\n"):
            self.assertLessEqual(len(line), 46)


class ExternalGrayscaleWatcherTests(unittest.TestCase):
    def test_single_off_read_does_not_trigger(self):
        watcher = tray.ExternalGrayscaleWatcher(min_interval=1.5)
        self.assertFalse(watcher.observe(False, now=0.0))

    def test_two_reads_close_together_do_not_trigger(self):
        watcher = tray.ExternalGrayscaleWatcher(min_interval=1.5)
        watcher.observe(False, now=0.0)
        self.assertFalse(watcher.observe(False, now=0.5))

    def test_two_reads_far_enough_apart_trigger(self):
        watcher = tray.ExternalGrayscaleWatcher(min_interval=1.5)
        watcher.observe(False, now=0.0)
        self.assertTrue(watcher.observe(False, now=1.6))

    def test_an_on_read_resets_the_window(self):
        watcher = tray.ExternalGrayscaleWatcher(min_interval=1.5)
        watcher.observe(False, now=0.0)
        watcher.observe(True, now=1.0)
        self.assertFalse(watcher.observe(False, now=1.6))
        self.assertTrue(watcher.observe(False, now=3.2))

    def test_reset_clears_state(self):
        watcher = tray.ExternalGrayscaleWatcher(min_interval=1.5)
        watcher.observe(False, now=0.0)
        watcher.reset()
        self.assertFalse(watcher.observe(False, now=1.6))


class ReadActiveCheapTests(unittest.TestCase):
    def test_bool_value(self):
        system = FakeSystem()
        system.values["grayscale"] = True
        self.assertTrue(tray.read_active_cheap(system))
        system.values["grayscale"] = False
        self.assertFalse(tray.read_active_cheap(system))

    def test_dict_value_only_true_for_grayscale_filter(self):
        system = FakeSystem()
        system.values["grayscale"] = {"active": True, "filterType": 0}
        self.assertTrue(tray.read_active_cheap(system))
        system.values["grayscale"] = {"active": True, "filterType": 1}
        self.assertFalse(tray.read_active_cheap(system))

    def test_missing_key_is_none(self):
        system = FakeSystem()
        del system.values["grayscale"]
        self.assertIsNone(tray.read_active_cheap(system))


class MigrateLegacyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.store = Store(self.home)
        self.legacy_state = Path(self.tmp.name) / "tray-grayscale.json"
        self.legacy_config = Path(self.tmp.name) / "config.json"
        self.system = FakeSystem()

    def migrate(self):
        tray.migrate_legacy(self.store, self.system, legacy_state_path=self.legacy_state,
                            legacy_config_path=self.legacy_config)

    def test_no_legacy_files_creates_default_preferences(self):
        self.migrate()
        prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        self.assertFalse(prefs.clickToSwitch)

    def test_click_action_toggle_maps_to_click_to_switch(self):
        self.legacy_config.write_text(json.dumps({"click_action": "toggle"}), encoding="utf-8")
        self.migrate()
        prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        self.assertTrue(prefs.clickToSwitch)

    def test_click_action_none_does_not_set_click_to_switch(self):
        self.legacy_config.write_text(json.dumps({"click_action": "none"}), encoding="utf-8")
        self.migrate()
        prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        self.assertFalse(prefs.clickToSwitch)

    def test_existing_preferences_are_never_overwritten(self):
        with self.store.locked():
            self.store.write_json(Preferences(clickToSwitch=False).to_dict(), "preferences.json")
        self.legacy_config.write_text(json.dumps({"click_action": "toggle"}), encoding="utf-8")
        self.migrate()
        prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        self.assertFalse(prefs.clickToSwitch, "migration is a one-time seed, not a standing override")

    def test_restores_captured_grayscale_when_no_session(self):
        self.legacy_state.write_text(json.dumps({"active": 1, "filterType": 1}), encoding="utf-8")
        self.migrate()
        self.assertEqual(self.system.values["grayscale"], {"active": True, "filterType": 1})
        self.assertFalse(self.legacy_state.exists())

    def test_does_not_restore_when_a_session_is_active(self):
        with self.store.locked():
            state = RuntimeState(session=_session())
            self.store.write_json(state.to_dict(), "state.json")
        self.legacy_state.write_text(json.dumps({"active": 1, "filterType": 0}), encoding="utf-8")
        original = dict(self.system.values)
        self.migrate()
        self.assertEqual(self.system.values, original)
        self.assertTrue(self.legacy_state.exists())

    def test_corrupt_legacy_state_does_not_crash(self):
        self.legacy_state.write_text("{ not json", encoding="utf-8")
        self.migrate()  # must not raise
        prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        self.assertFalse(prefs.clickToSwitch)

    def test_corrupt_legacy_config_falls_back_to_defaults(self):
        self.legacy_config.write_text("{ not json", encoding="utf-8")
        self.migrate()  # must not raise
        prefs = Preferences.from_dict(self.store.read_json("preferences.json"))
        self.assertFalse(prefs.clickToSwitch)


class TrayStatusTests(unittest.TestCase):
    def test_write_tray_status_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp))
            tray.write_tray_status(store, shortcut_id="ctrl-shift-e",
                                   message="Ctrl+Shift+E switches E-Ink Mode from any app.", pid=4242)
            data = store.read_json("tray-status.json")
            self.assertEqual(data["pid"], 4242)
            self.assertEqual(data["hotkey"], "ctrl-shift-e")
            self.assertEqual(data["hotkeyMessage"], "Ctrl+Shift+E switches E-Ink Mode from any app.")
            self.assertIn("updated", data)


class IconDrawingTests(unittest.TestCase):
    def test_shades_differ(self):
        unshaded = tray.create_icon_image("unshaded", light=False).tobytes()
        shaded = tray.create_icon_image("shaded", light=False).tobytes()
        half = tray.create_icon_image("half", light=False).tobytes()
        self.assertNotEqual(unshaded, shaded)
        self.assertNotEqual(unshaded, half)
        self.assertNotEqual(shaded, half)

    def test_warning_glyph_differs_from_every_shade(self):
        warning = tray.create_icon_image(None, light=False).tobytes()
        for shade in ("unshaded", "shaded", "half"):
            self.assertNotEqual(warning, tray.create_icon_image(shade, light=False).tobytes())

    def test_ink_follows_the_taskbar_theme(self):
        light = tray.create_icon_image("shaded", light=True).getpixel((32, 32))
        dark = tray.create_icon_image("shaded", light=False).getpixel((32, 32))
        self.assertLess(sum(light[:3]), sum(dark[:3]))

    def test_wildcat_styles_differ(self):
        outline = tray.draw_wildcat("outline", size=48).tobytes()
        filled = tray.draw_wildcat("filled", size=48).tobytes()
        half = tray.draw_wildcat("half", size=48).tobytes()
        self.assertNotEqual(outline, filled)
        self.assertNotEqual(outline, half)
        self.assertNotEqual(filled, half)

    def test_wildcat_mode_is_used_when_requested(self):
        dot = tray.create_icon_image("shaded", wildcat=False, light=False)
        cat = tray.create_icon_image("shaded", wildcat=True, light=False)
        self.assertNotEqual(dot.tobytes(), cat.tobytes())


class LaunchUiTests(unittest.TestCase):
    """`launch_ui` just hands argv-building to `eink_paths.ui_argv` (frozen-
    aware) and calls `subprocess.Popen` -- this checks the argv, never spawns
    a real process."""

    def setUp(self):
        patcher = mock.patch.object(tray.subprocess, "Popen")
        self.popen = patcher.start()
        self.addCleanup(patcher.stop)

    def test_dev_launch_uses_pythonw_and_the_sibling_script(self):
        tray.launch_ui("settings", "--tab", "schedule")
        argv = self.popen.call_args.args[0]
        self.assertTrue(argv[0].lower().endswith("pythonw.exe"))
        self.assertTrue(argv[1].endswith("eink_ui.py"))
        self.assertEqual(argv[2:], ["settings", "--tab", "schedule"])

    def test_frozen_launch_reuses_this_exe(self):
        with mock.patch.object(sys, "frozen", True, create=True), \
             mock.patch.object(sys, "executable", r"C:\Program Files\EInkMode\EInkMode.exe"):
            tray.launch_ui("welcome")
        argv = self.popen.call_args.args[0]
        self.assertEqual(argv, [r"C:\Program Files\EInkMode\EInkMode.exe", "ui", "welcome"])


if __name__ == "__main__":
    unittest.main()
