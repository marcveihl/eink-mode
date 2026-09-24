"""Unit tests for WindowsSystem. Nothing here touches the real display,
registry, taskbar or WMI -- every OS boundary is monkeypatched at the module
level, the same shape as `test_eink_tray.py`'s `FakeFilter`.

`FakeFilter` below models the build-26200 behaviour PLAN.md/pick_up.md
describe: writing `Active` persists but does not apply, and the Win+Ctrl+C
hotkey reads `Active`, inverts it, applies that to the screen, and writes it
back. Grayscale assertions check `showing` -- the modelled screen -- because
that is what a real read-back after a press would confirm.
"""

import ctypes
from ctypes import wintypes
import unittest
from unittest import mock

import eink_win
from eink_win import CF_KEY, EinkWinError, WindowsSystem


# --------------------------------------------------------------------------
# grayscale
# --------------------------------------------------------------------------


class FakeFilter:
    def __init__(self, active=0, filter_type=0, hotkey_enabled=1, hotkey_lands=True):
        self.values = {CF_KEY: {"Active": active, "FilterType": filter_type,
                                "HotkeyEnabled": hotkey_enabled}}
        self.showing = active
        self.showing_type = filter_type
        self.presses = 0
        # A press that "does not land" models a hotkey that fails to apply --
        # the case the contract says must raise so the core can retry.
        self.hotkey_lands = hotkey_lands

    def read(self, key, name, default=None):
        return self.values.get(key, {}).get(name, default)

    def write(self, key, name, value):
        self.values.setdefault(key, {})[name] = int(value)

    def press(self):
        self.presses += 1
        if not self.hotkey_lands:
            return
        self.values[CF_KEY]["Active"] = 0 if self.values[CF_KEY]["Active"] else 1
        self.showing = self.values[CF_KEY]["Active"]
        self.showing_type = self.values[CF_KEY]["FilterType"]

    @property
    def in_sync(self):
        # FilterType only matters while the filter is actually showing: it
        # does not apply live (pick_up.md), so writing it while off can
        # legitimately leave it different from "the type last shown" without
        # that being any kind of desync -- it's just queued for next time.
        if not self.showing:
            return self.showing == self.values[CF_KEY]["Active"]
        return (self.showing == self.values[CF_KEY]["Active"]
                and self.showing_type == self.values[CF_KEY]["FilterType"])


class GrayscaleTestCase(unittest.TestCase):
    active = 0
    filter_type = 0
    hotkey_lands = True

    def setUp(self):
        self.filter = FakeFilter(self.active, self.filter_type, hotkey_lands=self.hotkey_lands)
        patches = [
            mock.patch.object(eink_win, "read_dword", self.filter.read),
            mock.patch.object(eink_win, "write_dword", self.filter.write),
            mock.patch.object(eink_win, "press_hotkey", self.filter.press),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.system = WindowsSystem()

    def assertGrey(self):
        self.assertEqual(self.filter.showing, 1)
        self.assertEqual(self.filter.showing_type, 0)
        self.assertTrue(self.filter.in_sync)

    def assertColour(self):
        self.assertEqual(self.filter.showing, 0)
        self.assertTrue(self.filter.in_sync)


class ColdStart(GrayscaleTestCase):
    """No filter set to begin with -- the common case."""

    def test_snapshot_reports_active_and_filter_type(self):
        snap = self.system.snapshot()
        self.assertEqual(snap.values["grayscale"], {"active": False, "filterType": 0})

    def test_set_true_greys_the_screen_in_one_press(self):
        self.system.set("grayscale", True)
        self.assertGrey()
        self.assertEqual(self.filter.presses, 1)

    def test_set_true_is_idempotent(self):
        self.system.set("grayscale", True)
        presses = self.filter.presses
        self.system.set("grayscale", True)
        self.assertEqual(self.filter.presses, presses, "P7: no press for a no-op")

    def test_set_false_when_already_off_is_a_no_op(self):
        self.system.set("grayscale", False)
        self.assertEqual(self.filter.presses, 0)
        self.assertColour()

    def test_set_true_then_false_returns_colour(self):
        self.system.set("grayscale", True)
        self.system.set("grayscale", False)
        self.assertColour()

    def test_set_never_writes_active_directly(self):
        """The one thing not to re-break: Active only ever changes via press()."""
        write_calls = []
        original_write = self.filter.write

        def spy(key, name, value):
            write_calls.append(name)
            original_write(key, name, value)

        with mock.patch.object(eink_win, "write_dword", spy):
            self.system.set("grayscale", True)
        self.assertNotIn("Active", write_calls)

    def test_set_enables_the_hotkey_it_depends_on(self):
        self.filter.values[CF_KEY]["HotkeyEnabled"] = 0
        self.system.set("grayscale", True)
        self.assertEqual(self.filter.values[CF_KEY]["HotkeyEnabled"], 1)


class DictRestore(GrayscaleTestCase):
    """P1 -- a user who had Inverted on gets exactly that back, still on."""

    def test_dict_restores_exact_type_and_active(self):
        self.system.set("grayscale", {"active": True, "filterType": 1})
        self.assertEqual(self.filter.showing, 1)
        self.assertEqual(self.filter.showing_type, 1)
        self.assertTrue(self.filter.in_sync)

    def test_dict_can_restore_off(self):
        self.filter.press()  # start grey
        self.system.set("grayscale", {"active": False, "filterType": 0})
        self.assertColour()


class DictRestoreToOffAvoidsFlicker(GrayscaleTestCase):
    """Coordinator review finding: restoring {"active": False, "filterType":
    N} while a *different* type is currently showing must never flash type N
    on screen just to immediately turn it off again. Press off first (one
    press, straight to colour), then write the type directly -- it applies
    only the next time the filter turns on."""

    active = 1
    filter_type = 0  # currently on, Grayscale

    def test_restoring_off_with_a_different_type_never_shows_that_type(self):
        seen_while_showing = []
        real_press = self.filter.press

        def press_and_record():
            real_press()
            if self.filter.showing:
                seen_while_showing.append(self.filter.showing_type)

        with mock.patch.object(eink_win, "press_hotkey", press_and_record):
            self.system.set("grayscale", {"active": False, "filterType": 1})

        self.assertColour()
        self.assertEqual(self.filter.values[CF_KEY]["FilterType"], 1,
                          "the type is still restored, just without a press")
        self.assertNotIn(1, seen_while_showing,
                          "must never show Inverted en route to off")
        self.assertEqual(self.filter.presses, 1,
                          "one press straight to colour, not off-write-on-off")


class HotkeyDoesNotLand(GrayscaleTestCase):
    """Contract: if Active doesn't read back the target after a press, raise
    so the core keeps the session and can retry -- never silently proceed."""

    hotkey_lands = False

    def test_set_true_raises(self):
        with self.assertRaises(EinkWinError):
            self.system.set("grayscale", True)

    def test_set_dict_raises(self):
        with self.assertRaises(EinkWinError):
            self.system.set("grayscale", {"active": True, "filterType": 0})


class ResyncHelper(GrayscaleTestCase):
    active = 0
    filter_type = 0

    def setUp(self):
        super().setUp()
        # Model the out-of-sync case: screen filtered, registry says it isn't.
        self.filter.showing = 1
        self.filter.values[CF_KEY]["Active"] = 0

    def test_resync_presses_twice_and_leaves_registry_unchanged(self):
        eink_win.resync()
        self.assertEqual(self.filter.presses, 2)
        self.assertEqual(self.filter.values[CF_KEY]["Active"], 0)
        self.assertColour()


# --------------------------------------------------------------------------
# brightness
# --------------------------------------------------------------------------


class BrightnessTestCase(unittest.TestCase):
    def setUp(self):
        self.system = WindowsSystem()


class NoControllableDisplay(BrightnessTestCase):
    """Desktop / external monitor: WMI reports nothing. Never a hard failure
    -- omit the keys and warn (PARITY-SPEC)."""

    def setUp(self):
        super().setUp()
        patch = mock.patch.object(eink_win, "query_brightness_instances", lambda: [])
        patch.start()
        self.addCleanup(patch.stop)

    def test_snapshot_has_no_brightness_keys(self):
        snap = self.system.snapshot()
        self.assertFalse(any(k.startswith("brightness:") for k in snap.values))

    def test_snapshot_warns(self):
        snap = self.system.snapshot()
        self.assertTrue(any("doesn't let Windows control it" in w for w in snap.warnings))

    def test_set_unknown_instance_raises(self):
        with self.assertRaises(EinkWinError):
            self.system.set("brightness:DISPLAY\\FAKE", 0.5)


class OneControllableDisplay(BrightnessTestCase):
    def setUp(self):
        super().setUp()
        self.current = [("DISPLAY\\LAPTOP\\1", 40)]
        self.set_calls = []

        def fake_query():
            return list(self.current)

        def fake_set(instance_name, percent):
            self.set_calls.append((instance_name, percent))
            self.current[0] = (instance_name, percent)

        for target, fake in (("query_brightness_instances", fake_query),
                             ("set_brightness_instance", fake_set)):
            patch = mock.patch.object(eink_win, target, fake)
            patch.start()
            self.addCleanup(patch.stop)

    def test_snapshot_converts_percent_to_fraction(self):
        snap = self.system.snapshot()
        self.assertAlmostEqual(snap.values["brightness:DISPLAY\\LAPTOP\\1"], 0.40)

    def test_set_converts_fraction_to_percent(self):
        self.system.set("brightness:DISPLAY\\LAPTOP\\1", 0.75)
        self.assertEqual(self.set_calls, [("DISPLAY\\LAPTOP\\1", 75)])

    def test_set_is_idempotent(self):
        self.system.set("brightness:DISPLAY\\LAPTOP\\1", 0.40)  # already 40%
        self.assertEqual(self.set_calls, [], "P7: no WMI call for a no-op")


# --------------------------------------------------------------------------
# dock
# --------------------------------------------------------------------------


class FakeAppBar:
    def __init__(self, hwnd=1, autohide=False, apply_works=True):
        self.hwnd = hwnd
        self.autohide = autohide
        # A taskbar that accepts SETSTATE but doesn't actually change --
        # models the case the read-back-is-verification rule exists to catch.
        self.apply_works = apply_works
        self.set_calls = []

    def find_hwnd(self):
        return self.hwnd

    def message(self, msg, data):
        if msg == eink_win.ABM_GETSTATE:
            return eink_win.ABS_AUTOHIDE if self.autohide else eink_win.ABS_ALWAYSONTOP
        if msg == eink_win.ABM_SETSTATE:
            self.set_calls.append(data.lParam)
            if self.apply_works:
                self.autohide = bool(data.lParam & eink_win.ABS_AUTOHIDE)
            return 0
        raise AssertionError(f"unexpected message {msg}")


class DockTestCase(unittest.TestCase):
    def setUp(self):
        self.system = WindowsSystem()
        self.appbar = FakeAppBar()
        patches = [
            mock.patch.object(eink_win, "_find_tray_hwnd", self.appbar.find_hwnd),
            mock.patch.object(eink_win, "_appbar_message", self.appbar.message),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_snapshot_reports_current_state(self):
        self.appbar.autohide = True
        snap = self.system.snapshot()
        self.assertTrue(snap.values["dock"])

    def test_set_true_sends_autohide_and_alwaysontop(self):
        self.system.set("dock", True)
        self.assertEqual(self.appbar.set_calls, [eink_win.ABS_AUTOHIDE | eink_win.ABS_ALWAYSONTOP])
        self.assertTrue(self.appbar.autohide)

    def test_set_is_idempotent(self):
        self.appbar.autohide = True
        self.system.set("dock", True)
        self.assertEqual(self.appbar.set_calls, [], "P7: no SHAppBarMessage for a no-op")

    def test_no_taskbar_warns_instead_of_raising_in_snapshot(self):
        self.appbar.hwnd = 0
        snap = self.system.snapshot()
        self.assertNotIn("dock", snap.values)
        self.assertTrue(any("Shell_TrayWnd" in w for w in snap.warnings))

    def test_no_taskbar_raises_on_set(self):
        self.appbar.hwnd = 0
        with self.assertRaises(EinkWinError):
            self.system.set("dock", True)

    def test_set_raises_if_the_change_does_not_confirm(self):
        """Same read-back-is-verification rule as grayscale (pick_up.md): a
        SETSTATE call that doesn't actually move the taskbar must not be
        reported as success."""
        self.appbar.apply_works = False
        with self.assertRaises(EinkWinError):
            self.system.set("dock", True)


# --------------------------------------------------------------------------
# transparency
# --------------------------------------------------------------------------


class FakeRegistry:
    def __init__(self, initial=None):
        self.store = dict(initial or {})
        self.writes = []

    def read(self, subkey, name, default=None):
        return self.store.get((subkey, name), default)

    def write(self, subkey, name, value):
        self.writes.append((subkey, name, value))
        self.store[(subkey, name)] = int(value)


class TransparencyTestCase(unittest.TestCase):
    def setUp(self):
        self.system = WindowsSystem()
        self.registry = FakeRegistry()
        self.broadcasts = []
        patches = [
            mock.patch.object(eink_win, "read_dword", self.registry.read),
            mock.patch.object(eink_win, "write_dword", self.registry.write),
            mock.patch.object(eink_win, "_broadcast_setting_change", self.broadcasts.append),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_default_is_not_reduced(self):
        """No key at all means EnableTransparency's real-world default (on)."""
        snap = self.system.snapshot()
        self.assertFalse(snap.values["transparency"])

    def test_set_true_writes_zero_and_reports_reduced(self):
        self.system.set("transparency", True)
        self.assertEqual(self.registry.store[(eink_win.THEME_KEY, "EnableTransparency")], 0)
        self.assertTrue(self.system.snapshot().values["transparency"])
        self.assertEqual(self.broadcasts, ["ImmersiveColorSet"])

    def test_set_is_idempotent(self):
        self.system.set("transparency", True)
        self.broadcasts.clear()
        self.system.set("transparency", True)
        self.assertEqual(self.broadcasts, [], "P7: no broadcast for a no-op")

    def test_set_false_restores_one(self):
        self.system.set("transparency", True)
        self.system.set("transparency", False)
        self.assertEqual(self.registry.store[(eink_win.THEME_KEY, "EnableTransparency")], 1)


# --------------------------------------------------------------------------
# motion
# --------------------------------------------------------------------------


class FakeAnimation:
    def __init__(self, enabled=True):
        self.enabled = enabled
        self.set_calls = []

    def get(self):
        return self.enabled

    def set(self, enabled):
        self.set_calls.append(enabled)
        self.enabled = enabled


class MotionTestCase(unittest.TestCase):
    def setUp(self):
        self.system = WindowsSystem()
        self.anim = FakeAnimation(enabled=True)
        patches = [
            mock.patch.object(eink_win, "_spi_get_animation", self.anim.get),
            mock.patch.object(eink_win, "_spi_set_animation", self.anim.set),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_snapshot_false_when_animations_enabled(self):
        self.assertFalse(self.system.snapshot().values["motion"])

    def test_set_true_disables_animations(self):
        self.system.set("motion", True)
        self.assertFalse(self.anim.enabled)
        self.assertTrue(self.system.snapshot().values["motion"])

    def test_set_is_idempotent(self):
        self.system.set("motion", True)
        self.anim.set_calls.clear()
        self.system.set("motion", True)
        self.assertEqual(self.anim.set_calls, [], "P7: no SPI call for a no-op")

    def test_set_false_reenables_animations(self):
        self.anim.enabled = False
        self.system.set("motion", False)
        self.assertTrue(self.anim.enabled)


class SPIConstants(unittest.TestCase):
    """Coordinator review finding: SPI_SETCLIENTAREAANIMATION was 0x1041,
    which is actually SPI_SETDISABLEOVERLAPPEDCONTENT -- a different flag
    entirely. Pin both values against learn.microsoft.com so a future edit
    can't silently reintroduce that mixup."""

    def test_pins_documented_values(self):
        self.assertEqual(eink_win.SPI_GETCLIENTAREAANIMATION, 0x1042)
        self.assertEqual(eink_win.SPI_SETCLIENTAREAANIMATION, 0x1043)
        self.assertNotEqual(eink_win.SPI_SETCLIENTAREAANIMATION, 0x1041,
                             "0x1041 is SPI_SETDISABLEOVERLAPPEDCONTENT, a different flag")


class SPIArgumentPositions(unittest.TestCase):
    """Per learn.microsoft.com/windows/win32/api/winuser/nf-winuser-
    systemparametersinfoa, the BOOL for SPI_SETCLIENTAREAANIMATION travels in
    pvParam (as the pointer value itself: non-null=TRUE/null=FALSE), not
    uiParam. Pin the real call shape by stubbing the underlying WinDLL
    function -- nothing here reaches the real user32."""

    def test_set_true_passes_bool_in_pvparam_not_uiparam(self):
        calls = []

        def fake_spi(action, uiparam, pvparam, fwinini):
            calls.append((action, uiparam, pvparam, fwinini))
            return 1

        with mock.patch.object(eink_win._user32, "SystemParametersInfoW", fake_spi):
            eink_win._spi_set_animation(True)

        action, uiparam, pvparam, fwinini = calls[0]
        self.assertEqual(action, eink_win.SPI_SETCLIENTAREAANIMATION)
        self.assertEqual(uiparam, 0, "the BOOL must not be smuggled into uiParam")
        self.assertEqual(pvparam.value, 1)
        self.assertEqual(fwinini, eink_win.SPIF_UPDATEINIFILE | eink_win.SPIF_SENDCHANGE)

    def test_set_false_passes_null_pvparam(self):
        calls = []

        def fake_spi(action, uiparam, pvparam, fwinini):
            calls.append(pvparam)
            return 1

        with mock.patch.object(eink_win._user32, "SystemParametersInfoW", fake_spi):
            eink_win._spi_set_animation(False)

        self.assertIsNone(calls[0].value)

    def test_get_passes_a_pointer_for_the_result_not_the_bool_itself(self):
        calls = []

        def fake_spi(action, uiparam, pvparam, fwinini):
            calls.append((action, uiparam, fwinini))
            ctypes.cast(pvparam, ctypes.POINTER(wintypes.BOOL))[0] = wintypes.BOOL(1)
            return 1

        with mock.patch.object(eink_win._user32, "SystemParametersInfoW", fake_spi):
            result = eink_win._spi_get_animation()

        action, uiparam, fwinini = calls[0]
        self.assertEqual(action, eink_win.SPI_GETCLIENTAREAANIMATION)
        self.assertEqual(uiparam, 0)
        self.assertEqual(fwinini, 0)
        self.assertTrue(result)


# --------------------------------------------------------------------------
# snapshot() wrapping -- one failing subsystem is a warning, not an exception
# --------------------------------------------------------------------------


class SnapshotWrapping(unittest.TestCase):
    def test_a_broken_subsystem_becomes_a_warning_and_missing_key(self):
        system = WindowsSystem()
        with mock.patch.object(eink_win, "filter_active", side_effect=OSError("boom")):
            snap = system.snapshot()
        self.assertNotIn("grayscale", snap.values)
        self.assertTrue(any("Grayscale" in w for w in snap.warnings))

    def test_other_keys_still_populate_when_one_subsystem_fails(self):
        system = WindowsSystem()
        with mock.patch.object(eink_win, "filter_active", side_effect=OSError("boom")), \
             mock.patch.object(eink_win, "query_brightness_instances", lambda: []), \
             mock.patch.object(eink_win, "taskbar_autohide", lambda: True), \
             mock.patch.object(eink_win, "transparency_reduced", lambda: False), \
             mock.patch.object(eink_win, "motion_reduced", lambda: False):
            snap = system.snapshot()
        self.assertEqual(snap.values["dock"], True)
        self.assertEqual(snap.values["transparency"], False)
        self.assertEqual(snap.values["motion"], False)

    def test_snapshot_never_raises_even_if_everything_is_broken(self):
        system = WindowsSystem()
        with mock.patch.object(eink_win, "filter_active", side_effect=OSError()), \
             mock.patch.object(eink_win, "query_brightness_instances", side_effect=Exception()), \
             mock.patch.object(eink_win, "taskbar_autohide", side_effect=Exception()), \
             mock.patch.object(eink_win, "transparency_reduced", side_effect=Exception()), \
             mock.patch.object(eink_win, "motion_reduced", side_effect=Exception()):
            snap = system.snapshot()
        self.assertEqual(snap.values, {})
        self.assertEqual(len(snap.warnings), 5)


class UnknownKey(unittest.TestCase):
    def test_set_rejects_an_unknown_key(self):
        with self.assertRaises(KeyError):
            WindowsSystem().set("bogus", True)


if __name__ == "__main__":
    unittest.main()
