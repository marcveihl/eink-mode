# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for E-Ink Mode: builds `dist\\EInkMode\\EInkMode.exe`
(windowed, the tray + `ui ...` dispatcher, entry `eink_app.py`) and
`dist\\EInkMode\\eink.exe` (console, the CLI, entry `eink_cli.py`) into the
same --onedir folder, sharing one copy of the interpreter/libs via MERGE.

Run through `build.ps1`, not directly, so the venv/paths are right:
    .venv\\Scripts\\python.exe -m PyInstaller eink.spec --noconfirm --clean
"""

from PyInstaller.utils.hooks import collect_data_files

block_cipher = None

# zoneinfo needs tzdata's IANA database bundled as data files (there is no
# system tzdata on Windows); tzlocal/pystray/win32com hidden imports are
# reached only via a plain `import` inside a function (`eink_core.local_zone`,
# `eink_win._wmi_root`) which PyInstaller's modulegraph finds statically, but
# they're listed explicitly here too since that's the one place a future
# refactor (e.g. an importlib string) would silently break the frozen build.
datas = collect_data_files("tzdata")

hidden_imports = [
    "pystray._win32",
    "PIL._tkinter_finder",
    "tzlocal",
    "tzlocal.windows_tz",
    "win32com.client",
    "win32comext.shell",
    "pythoncom",
    "pywintypes",
    "winreg",
    "tkinter",
    "tkinter.ttk",
]

app_a = Analysis(
    ["eink_app.py"],
    pathex=["."],
    binaries=[],
    datas=datas,
    hiddenimports=hidden_imports + [
        "eink_tray", "eink_ui", "eink_cli", "eink_core", "eink_win",
        "eink_sim", "eink_paths",
    ],
    hookspath=[],
    excludes=[],
    noarchive=False,
)

cli_a = Analysis(
    ["eink_cli.py"],
    pathex=["."],
    binaries=[],
    datas=datas,
    hiddenimports=hidden_imports + [
        "eink_core", "eink_sim", "eink_win",
    ],
    hookspath=[],
    excludes=[],
    noarchive=False,
)

MERGE((app_a, "EInkMode", "EInkMode"), (cli_a, "eink", "eink"))

app_pyz = PYZ(app_a.pure, app_a.zipped_data)
app_exe = EXE(
    app_pyz,
    app_a.scripts,
    [],
    exclude_binaries=True,
    name="EInkMode",
    debug=False,
    console=False,
    icon="eink.ico",
    version="version_info.txt",
)

cli_pyz = PYZ(cli_a.pure, cli_a.zipped_data)
cli_exe = EXE(
    cli_pyz,
    cli_a.scripts,
    [],
    exclude_binaries=True,
    name="eink",
    debug=False,
    console=True,
    icon="eink.ico",
    version="version_info.txt",
)

# Both EXEs collected into ONE folder (dist\EInkMode\) so `eink.exe` sits
# next to `EInkMode.exe` -- this is the documented "multiple executables,
# one onedir" recipe: pass both EXE objects (built with exclude_binaries=True
# above) and both Analyses' binaries/zipfiles/datas to a single COLLECT.
coll = COLLECT(
    app_exe,
    app_a.binaries,
    app_a.zipfiles,
    app_a.datas,
    cli_exe,
    cli_a.binaries,
    cli_a.zipfiles,
    cli_a.datas,
    strip=False,
    upx=False,
    name="EInkMode",
)
