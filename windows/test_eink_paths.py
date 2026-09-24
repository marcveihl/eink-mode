"""Unit tests for eink_paths.py -- the frozen-aware argv/command-line
helpers shared by eink_tray.py, eink_ui.py, and eink_app.py. Never touches a
real process or the registry; only checks what argv/string each branch
builds.
"""

import sys
import unittest
from unittest import mock

import eink_paths


class FrozenDetectionTests(unittest.TestCase):
    def test_not_frozen_by_default(self):
        self.assertFalse(eink_paths.is_frozen())

    def test_frozen_when_sys_frozen_is_set(self):
        with mock.patch.object(sys, "frozen", True, create=True):
            self.assertTrue(eink_paths.is_frozen())


class UiArgvTests(unittest.TestCase):
    def test_dev_uses_pythonw_and_the_sibling_script(self):
        argv = eink_paths.ui_argv("settings", "--tab", "general")
        self.assertTrue(argv[0].lower().endswith("pythonw.exe"))
        self.assertTrue(argv[1].endswith("eink_ui.py"))
        self.assertEqual(argv[2:], ["settings", "--tab", "general"])

    def test_frozen_reuses_this_exe_with_a_ui_prefix(self):
        with mock.patch.object(sys, "frozen", True, create=True), \
             mock.patch.object(sys, "executable", r"C:\Program Files\EInkMode\EInkMode.exe"):
            argv = eink_paths.ui_argv("welcome")
        self.assertEqual(argv, [r"C:\Program Files\EInkMode\EInkMode.exe", "ui", "welcome"])


class RunKeyCommandTests(unittest.TestCase):
    def test_dev_quotes_pythonw_and_the_tray_script(self):
        command = eink_paths.run_key_command()
        self.assertTrue(command.startswith('"'))
        self.assertIn("eink_tray.py", command)

    def test_frozen_is_just_this_exes_own_quoted_path(self):
        with mock.patch.object(sys, "frozen", True, create=True), \
             mock.patch.object(sys, "executable", r"C:\Program Files\EInkMode\EInkMode.exe"):
            command = eink_paths.run_key_command()
        self.assertEqual(command, r'"C:\Program Files\EInkMode\EInkMode.exe"')


if __name__ == "__main__":
    unittest.main()
