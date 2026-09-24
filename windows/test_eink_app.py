"""Unit tests for eink_app.py -- the single frozen entry point that
dispatches argv to eink_tray/eink_ui/eink_cli (see PARITY-SPEC.md and the
module docstring). Mocks each target module's `main()` so this never touches
the tray, a Tk window, or the real system.
"""

import unittest
from unittest import mock

import eink_app


class DispatchTests(unittest.TestCase):
    def test_no_args_runs_the_tray(self):
        with mock.patch("eink_tray.main", return_value=0) as tray_main:
            self.assertEqual(eink_app.main([]), 0)
        tray_main.assert_called_once_with([])

    def test_ui_settings_runs_eink_ui(self):
        with mock.patch("eink_ui.main", return_value=0) as ui_main:
            self.assertEqual(eink_app.main(["ui", "settings", "--tab", "schedule"]), 0)
        ui_main.assert_called_once_with(["settings", "--tab", "schedule"])

    def test_ui_welcome_runs_eink_ui(self):
        with mock.patch("eink_ui.main", return_value=0) as ui_main:
            eink_app.main(["ui", "welcome"])
        ui_main.assert_called_once_with(["welcome"])

    def test_cli_runs_eink_cli(self):
        with mock.patch("eink_cli.main", return_value=0) as cli_main:
            eink_app.main(["cli", "status"])
        cli_main.assert_called_once_with(["status"])

    def test_unknown_head_falls_back_to_tray_flags(self):
        with mock.patch("eink_tray.main", return_value=0) as tray_main:
            eink_app.main(["--toggle"])
        tray_main.assert_called_once_with(["--toggle"])


if __name__ == "__main__":
    unittest.main()
