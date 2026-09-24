"""eink_app.py -- single frozen entry point for E-Ink Mode.

PyInstaller builds this into the windowed `EInkMode.exe` (`build.ps1` /
`installer/eink.spec`). A separate console `eink.exe` is built directly from
`eink_cli.py` for scripting (`eink.exe status|on|off|...`); this module is
only the dispatcher behind `EInkMode.exe`:

    EInkMode.exe                          -> eink_tray.main()      (resident tray)
    EInkMode.exe ui settings [--tab X]    -> eink_ui.main(["settings", ...])
    EInkMode.exe ui welcome               -> eink_ui.main(["welcome", ...])
    EInkMode.exe cli <args>               -> eink_cli.main(<args>)

`eink_paths.ui_argv`/`run_key_command` build the `ui ...` and bare-exe argv
above when `sys.frozen` is set, so the tray's "launch the UI" and the HKCU
Run-key command agree with this dispatch. Unfrozen, `python eink_app.py ...`
follows the same rules, which is how the frozen branch gets exercised without
a build (see `test_eink_app.py`).
"""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if not argv:
        import eink_tray
        return eink_tray.main([])
    head, rest = argv[0], argv[1:]
    if head == "ui":
        import eink_ui
        return eink_ui.main(rest)
    if head == "cli":
        import eink_cli
        return eink_cli.main(rest)
    # Anything else (e.g. a v0 shortcut passing `--toggle` straight through)
    # is tray-flag syntax -- hand the whole argv to the tray's own parser,
    # same as running `eink_tray.py --toggle` directly.
    import eink_tray
    return eink_tray.main(argv)


if __name__ == "__main__":
    sys.exit(main())
