; installer\eink.iss -- Inno Setup script for E-Ink Mode.
; Built by build.ps1 (`ISCC.exe installer\eink.iss`), after PyInstaller has
; produced dist\EInkMode\{EInkMode.exe,eink.exe,_internal\...}.
;
; Per-user install, no admin: PrivilegesRequired=lowest, installs under
; {localappdata}\Programs\E-Ink Mode. AppId is a fixed GUID -- never change
; it, or an "upgrade" will install side-by-side instead of in place.

#define MyAppName "E-Ink Mode"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "E-Ink Mode"
#define MyAppExeName "EInkMode.exe"
#define MyCliExeName "eink.exe"

[Setup]
AppId={{B6C1E1B0-6B0C-4B7B-9B7C-6E7D8B6A1C3F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UsePreviousAppDir=yes
OutputDir=..\dist
OutputBaseFilename=EInkMode-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\eink.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; The tray's single-instance mutex (kept identical to the legacy v0 tray's
; name, per PARITY-SPEC.md, so the two can never run together). Setup uses
; this to detect *either* tray running and asks the user to close it before
; installing/uninstalling over its files -- this is what makes "quit the old
; v0 tray first" (README) an enforced step, not just a suggestion.
AppMutex=Local\EinkMode.Grayscale.v1
; Restart Manager: close whatever is holding a lock on files under {app}
; (i.e. only a running instance of *this* installed EInkMode.exe/eink.exe,
; identified by the file handles it holds -- never a same-named process
; elsewhere) before installing or uninstalling.
CloseApplications=yes
CloseApplicationsFilter={#MyAppExeName},{#MyCliExeName}
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "..\dist\EInkMode\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Restore the display *before* anything else -- the emergency-switch
; contract: uninstalling must never leave the screen grayscale/dimmed, even
; if the tray has already been (or is about to be) killed. `eink.exe off`
; talks straight to Controller/Store like any other CLI call, so it works
; whether or not the tray process is still alive.
Filename: "{app}\{#MyCliExeName}"; Parameters: "off"; Flags: runhidden waituntilterminated; RunOnceId: "EInkModeRestoreDisplay"

[Registry]
; The "Open E-Ink Mode at login" Run value (eink_ui.py RUN_VALUE_NAME) --
; removed on uninstall so a stale entry doesn't try to launch a deleted exe.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "EInkMode"; ValueType: none; Flags: uninsdeletevalue
