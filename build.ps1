#Requires -Version 5.1
<#
.SYNOPSIS
    Build UsdShellExtension and assemble the final install package.

.DESCRIPTION
    Reads configuration from .env in the repo root (do not edit this script).
    Locates MSBuild via vswhere, builds the solution in Release|x64,
    copies runtime files, and writes UsdShellExtension.ini.

.PARAMETER Config
    MSBuild configuration: Release or Debug.
    Overrides CONFIG in .env. Default: Release.
#>
param(
    [string]$Config = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO = $PSScriptRoot
$SEP  = "  " + ("=" * 52)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Read-DotEnv {
    param([string]$Path)
    $cfg = @{}
    if (-not (Test-Path $Path)) { return $cfg }
    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -le 0) { continue }
        $cfg[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }
    return $cfg
}

function Assert-Path {
    param([string]$path, [string]$label)
    if (-not (Test-Path $path)) { Write-Error "Cannot find $label at: $path" }
}

function Write-Step {
    param([string]$msg)
    Write-Host ""
    Write-Host ("  >> {0}" -f $msg) -ForegroundColor Cyan
}

function Write-Detail {
    param([string]$key, [string]$value)
    Write-Host ("    {0,-14} {1}" -f ($key + " :"), $value) -ForegroundColor Gray
}

function Write-Item {
    param([string]$msg)
    Write-Host ("    + {0}" -f $msg) -ForegroundColor DarkGreen
}

# ---------------------------------------------------------------------------
# Load .env and resolve configuration
# ---------------------------------------------------------------------------
$cfg = Read-DotEnv (Join-Path $REPO ".env")

$USD_SDK = if ($cfg['USD_SDK']) { $cfg['USD_SDK'] } else { "D:\usd.py312.windows-x86_64.usdview.release-v25.08" }
if (-not $Config) { $Config = if ($cfg['CONFIG']) { $cfg['CONFIG'] } else { "Release" } }
if ($Config -notin @('Release', 'Debug')) {
    Write-Error "CONFIG must be 'Release' or 'Debug' (got: '$Config'). Check .env or use -Config."
}

$SLN     = Join-Path $REPO "UsdShellExtension.sln"
$OUT_DIR = Join-Path $REPO "bin\v145\3.12\$Config"

$version = if (Test-Path (Join-Path $REPO "version.txt")) {
    (Get-Content (Join-Path $REPO "version.txt")).Trim()
} else { "" }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ("    USD Shell Extension  {0}" -f $(if ($version) { "v$version" } else { "" })) -ForegroundColor White
Write-Host ("    Build  |  {0} | x64" -f $Config) -ForegroundColor DarkGray
Write-Host $SEP -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 1. Verify prerequisites
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

Assert-Path $USD_SDK "NVIDIA USD SDK"
Assert-Path $SLN     "Solution file"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Assert-Path $vswhere "vswhere.exe"

$allVsInstallPaths = & $vswhere -all -products * -requires Microsoft.Component.MSBuild `
                     -property installationPath 2>$null

$msbuild        = $null
$vcToolsVersion = $null

foreach ($vsPath in $allVsInstallPaths) {
    $msvcBase = Join-Path $vsPath "VC\Tools\MSVC"
    if (-not (Test-Path $msvcBase)) { continue }

    $found = Get-ChildItem $msvcBase |
        Where-Object { Test-Path (Join-Path $_.FullName "atlmfc\include\atlbase.h") } |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if ($found) {
        $vcToolsVersion = $found.Name
        $msBuildExe = & $vswhere -path $vsPath -find "MSBuild\**\Bin\MSBuild.exe" 2>$null |
                      Select-Object -First 1
        if ($msBuildExe -and (Test-Path $msBuildExe)) { $msbuild = $msBuildExe }
        break
    }
}

if (-not $msbuild -or -not (Test-Path $msbuild)) {
    Write-Error "MSBuild not found. Install Visual Studio 2026 with C++ tools."
}
if (-not $vcToolsVersion) {
    Write-Error "No MSVC toolset with ATL found. Install 'C++ ATL for v145 build tools' via Visual Studio Installer."
}

Write-Detail "MSBuild" $msbuild
Write-Detail "MSVC"    $vcToolsVersion
Write-Detail "USD SDK" $USD_SDK
Write-Detail "Output"  $OUT_DIR

# ---------------------------------------------------------------------------
# 2. Build the solution (skip the NSIS installer project)
# ---------------------------------------------------------------------------
Write-Step "Building solution ($Config|x64)"

$prevOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:VSLANG = "1033"

$PythonHome = Join-Path $USD_SDK "python\"

$msbuildArgs = @(
    $SLN,
    "/p:Configuration=$Config",
    "/p:Platform=x64",
    "/p:VCToolsVersion=$vcToolsVersion",
    "/p:PythonHome=$PythonHome",
    "/t:UsdShellExtension;UsdPreviewHandlerPython;UsdPreviewLocalServer;UsdPythonToolsLocalServer;UsdSdkToolsLocalServer;EventViewerMessages",
    "/m",
    "/nologo",
    "/verbosity:minimal",
    "/clp:Summary"
)

& $msbuild @msbuildArgs
[Console]::OutputEncoding = $prevOutputEncoding
if ($LASTEXITCODE -ne 0) {
    Write-Error "MSBuild failed with exit code $LASTEXITCODE"
}

Assert-Path $OUT_DIR "build output directory"

# ---------------------------------------------------------------------------
# 3. Copy files not handled by post-build events
# ---------------------------------------------------------------------------
Write-Step "Copying runtime files"

$USD_BIN     = Join-Path $USD_SDK "bin"
$USD_LIB     = Join-Path $USD_SDK "lib"
$USD_PY      = Join-Path $USD_SDK "python"
$USD_SCRIPTS = Join-Path $USD_SDK "scripts"
$USD_PYTHON  = "$USD_SDK\lib\python"
$USD_PKGS    = "$USD_SDK\pip-packages"

$vcruntime = Join-Path $USD_PY "vcruntime140.dll"
if (Test-Path $vcruntime) {
    Copy-Item $vcruntime $OUT_DIR -Force
    Write-Item "vcruntime140.dll"
}

$tbbProxy = Join-Path $USD_BIN "tbbmalloc_proxy.dll"
if (Test-Path $tbbProxy) {
    Copy-Item $tbbProxy $OUT_DIR -Force
    Write-Item "tbbmalloc_proxy.dll"
}

$usdPluginSrc = Join-Path $USD_LIB "usd"
$usdPluginDst = Join-Path $OUT_DIR "usd"
if (Test-Path $usdPluginSrc) {
    if (Test-Path $usdPluginDst) { Remove-Item $usdPluginDst -Recurse -Force }
    Copy-Item $usdPluginSrc $usdPluginDst -Recurse -Force
    Write-Item "lib\usd\ (USD plugins)"
}

$usdExtPluginSrc = Join-Path $USD_SDK "plugin\usd"
$usdExtPluginDst = Join-Path $OUT_DIR "plugin\usd"
if (Test-Path $usdExtPluginSrc) {
    if (Test-Path $usdExtPluginDst) { Remove-Item $usdExtPluginDst -Recurse -Force }
    Copy-Item $usdExtPluginSrc $usdExtPluginDst -Recurse -Force
    Write-Item "plugin\usd\ (hdStorm, usdAbc, ...)"
}

$icoSrc = Join-Path $REPO "UsdShellExtension\usd.ico"
if (Test-Path $icoSrc) {
    Copy-Item $icoSrc $OUT_DIR -Force
    Write-Item "usd.ico"
}

# ---------------------------------------------------------------------------
# 4. Write UsdShellExtension.ini with the correct runtime paths
# ---------------------------------------------------------------------------
Write-Step "Writing UsdShellExtension.ini"

$iniContent = @"
; UsdShellExtension runtime configuration
; Generated by build.ps1; re-run the script after moving the USD SDK.

[USD]
; Folders added to PATH so usdview/usdrecord scripts can be found
PATH=$USD_BIN;$USD_LIB;$USD_SCRIPTS
; Python module search path for USD Python bindings + PySide6/PyOpenGL
PYTHONPATH=$USD_PYTHON;$USD_PKGS
; USD plugin search paths; lib\usd plugins + renderer plugins (hdStorm, usdAbc, ...)
PXR_PLUGINPATH_NAME=%ProgramFiles%\UsdShellExtension\usd;%ProgramFiles%\UsdShellExtension\plugin\usd
; Text editor for the "Edit" context menu command (must block until file is closed)
EDITOR=

[RENDERER]
; Hydra renderer for each feature. Leave empty for the default Storm renderer.
; Examples: GL, Embree, Arnold, ...
PREVIEW=
THUMBNAIL=
VIEW=

[PYTHON]
; Path to the bundled Python (copied into the install dir by install.ps1)
PATH=%ProgramFiles%\UsdShellExtension\python\
; Additional packages for the COM servers (PySide6, PyOpenGL)
PYTHONPATH=%ProgramFiles%\UsdShellExtension\pip-packages
"@

$iniPath = Join-Path $OUT_DIR "UsdShellExtension.ini"
Set-Content -Path $iniPath -Value $iniContent -Encoding UTF8
Write-Item "UsdShellExtension.ini"

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host "    Build complete" -ForegroundColor Green
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""

Write-Detail "Output" $OUT_DIR
Write-Host ""

$binaries = @(
    Get-ChildItem $OUT_DIR -Filter "*.exe" | Select-Object -ExpandProperty Name
    Get-ChildItem $OUT_DIR -Filter "*.dll" | Where-Object { $_.Name -notlike "usd_*" } | Select-Object -ExpandProperty Name
    Get-ChildItem $OUT_DIR -Filter "*.pyd" | Select-Object -ExpandProperty Name
) | Sort-Object

Write-Host "  Binaries:" -ForegroundColor White
$binaries | ForEach-Object { Write-Host ("    - {0}" -f $_) -ForegroundColor Gray }

Write-Host ""
Write-Host "  Next step (run as Administrator):" -ForegroundColor White
Write-Host "    .\install.ps1" -ForegroundColor Yellow
Write-Host ""
