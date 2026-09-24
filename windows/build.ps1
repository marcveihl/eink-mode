<#
.SYNOPSIS
    Reproducible build: PyInstaller onedir app -> Inno Setup installer.

.DESCRIPTION
    1. Installs requirements.txt + requirements-build.txt into .venv.
    2. Runs PyInstaller on eink.spec -> dist\EInkMode\EInkMode.exe (windowed
       tray/UI) and dist\EInkMode\eink.exe (console CLI), one onedir folder.
    3. Locates ISCC.exe (Inno Setup's compiler), installing Inno Setup via
       winget if it isn't already on the machine.
    4. Compiles installer\eink.iss -> dist\EInkMode-Setup-0.1.0.exe.

    Run from the repo root:  .\build.ps1
    Skip the installer step (PyInstaller only):  .\build.ps1 -SkipInstaller
#>
[CmdletBinding()]
param(
    [switch]$SkipInstaller
)

# Not "Stop": PyInstaller/pip/winget/ISCC all write ordinary progress info to
# stderr, which PowerShell would otherwise turn into a terminating
# NativeCommandError even on a zero exit code. Every native call below checks
# $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
Set-Location $root

$venvPython = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    throw "Expected a venv at .venv (got none at $venvPython). Create it first."
}

Write-Host "==> Installing runtime + build requirements into .venv" -ForegroundColor Cyan
& $venvPython -m pip install -q -r (Join-Path $root "requirements.txt") -r (Join-Path $root "requirements-build.txt")
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

Write-Host "==> Removing previous build\ and dist\" -ForegroundColor Cyan
foreach ($dir in @("build", "dist")) {
    $p = Join-Path $root $dir
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}

Write-Host "==> Running PyInstaller (eink.spec)" -ForegroundColor Cyan
& $venvPython -m PyInstaller (Join-Path $root "eink.spec") --noconfirm --clean
if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed" }

$appExe = Join-Path $root "dist\EInkMode\EInkMode.exe"
$cliExe = Join-Path $root "dist\EInkMode\eink.exe"
if (-not (Test-Path $appExe)) { throw "Build did not produce $appExe" }
if (-not (Test-Path $cliExe)) { throw "Build did not produce $cliExe" }
Write-Host "==> Built $appExe and $cliExe" -ForegroundColor Green

if ($SkipInstaller) {
    Write-Host "==> -SkipInstaller passed; stopping after PyInstaller." -ForegroundColor Yellow
    exit 0
}

# --- Locate or install Inno Setup's compiler (ISCC.exe) --------------------

function Find-ISCC {
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$Env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "$Env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$Env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

$iscc = Find-ISCC
if (-not $iscc) {
    Write-Host "==> ISCC.exe not found; installing Inno Setup via winget (user scope)" -ForegroundColor Cyan
    winget install --id JRSoftware.InnoSetup -e --scope user --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "==> User-scope winget install failed; retrying machine scope" -ForegroundColor Yellow
        winget install --id JRSoftware.InnoSetup -e --scope machine --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget could not install Inno Setup" }
    }
    $iscc = Find-ISCC
    if (-not $iscc) { throw "Inno Setup installed but ISCC.exe still not found; open a new shell and re-run build.ps1" }
}
Write-Host "==> Using ISCC at $iscc" -ForegroundColor Green

Write-Host "==> Compiling installer\eink.iss" -ForegroundColor Cyan
& $iscc (Join-Path $root "installer\eink.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC (Inno Setup) build failed" }

$setupExe = Join-Path $root "dist\EInkMode-Setup-0.1.0.exe"
if (-not (Test-Path $setupExe)) { throw "Installer build did not produce $setupExe" }
$size = (Get-Item $setupExe).Length
Write-Host ("==> Installer ready: {0} ({1:N1} MB)" -f $setupExe, ($size / 1MB)) -ForegroundColor Green
