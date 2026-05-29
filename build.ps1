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

.PARAMETER Installer
    After building, stage LICENSE.txt and run NSIS to produce the setup .exe.
    Requires NSIS installed at C:\Program Files\NSIS\makensis.exe.

.PARAMETER Release
    After building the installer, publish a GitHub release via the gh CLI.
    Implies -Installer. Requires gh installed and authenticated (gh auth login).
    The release tag is read from version.txt (e.g. "1.2.0" becomes tag "v1.2.0").

.PARAMETER LogFile
    Path to write a transcript log. Default: build.log in the repo directory.
#>
param(
    [string]$Config     = "",
    [switch]$Installer,
    [switch]$Release,
    [string]$LogFile    = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Release) { $Installer = $true }

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
# Logging
# ---------------------------------------------------------------------------
if ($LogFile -eq "") { $LogFile = Join-Path $REPO "build.log" }
try { Stop-Transcript | Out-Null } catch { $null = $_ }
Start-Transcript -Path $LogFile -Force | Out-Null

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ("    USD Shell Extension  {0}" -f $(if ($version) { "v$version" } else { "" })) -ForegroundColor White
Write-Host ("    Build  |  {0} | x64" -f $Config) -ForegroundColor DarkGray
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""
Write-Detail "Log" $LogFile

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

Write-Host "    Copying bin\ ..." -ForegroundColor Gray
$rcBinArgs = @(
    $USD_BIN, $OUT_DIR,
    '/R:3', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS',
    '/XF',
        '*.pdb',
        'exr2aces.exe', 'exrenvmap.exe', 'exrheader.exe', 'exrinfo.exe',
        'exrmakepreview.exe', 'exrmaketiled.exe', 'exrmanifest.exe',
        'exrmetrics.exe', 'exrmultipart.exe', 'exrmultiview.exe', 'exrstdattr.exe',
        'iconvert.exe', 'idiff.exe', 'igrep.exe', 'iinfo.exe',
        'maketx.exe', 'oiiotool.exe',
        'testusdview', 'testusdview.cmd',
        '__USE_scripts_FOLDER_INSTEAD_FOR_EASY_ENTRY_POINTS',
        '*.cmd'
)
$null = & robocopy @rcBinArgs
Write-Item "bin\ (USD DLLs, external libs, USD entry points)"

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

$usdLibPySrc = Join-Path $USD_SDK "lib\python"
$usdLibPyDst = Join-Path $OUT_DIR "lib\python"
if (Test-Path $usdLibPySrc) {
    if (Test-Path $usdLibPyDst) { Remove-Item $usdLibPyDst -Recurse -Force }
    $null = & robocopy $usdLibPySrc $usdLibPyDst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS /XF *.pdb
    Write-Item "lib\python\ (pxr Python bindings)"
}

$usdScriptsSrc = Join-Path $USD_SDK "scripts"
$usdScriptsDst = Join-Path $OUT_DIR "scripts"
if (Test-Path $usdScriptsSrc) {
    if (Test-Path $usdScriptsDst) { Remove-Item $usdScriptsDst -Recurse -Force }
    $null = & robocopy $usdScriptsSrc $usdScriptsDst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS /XF *.sh
    Write-Item "scripts\ (usdview, usdrecord, ...)"
}

# ---------------------------------------------------------------------------
# 4. Write UsdShellExtension.ini with the correct runtime paths
# ---------------------------------------------------------------------------
Write-Step "Writing UsdShellExtension.ini"

$iniContent = @"
; UsdShellExtension runtime configuration
; Path values are intentionally empty here: install.ps1 writes the
; correct absolute paths directly, and the NSIS installer force-writes
; them via WriteConfigFile. Do not add hardcoded paths to this template.

[USD]
; Folders added to PATH: install dir (USD DLLs) + scripts subdir (usdview, usdrecord)
PATH=
; Python module search path for pxr bindings (pxr package, usdviewq, ...)
PYTHONPATH=
; USD plugin search paths
PXR_PLUGINPATH_NAME=
; Text editor for the "Edit" context menu command (must block until file is closed)
EDITOR=

[RENDERER]
; Hydra renderer for each feature. Leave empty for the default Storm renderer.
; Examples: GL, Embree, Arnold, ...
PREVIEW=
THUMBNAIL=
VIEW=

[PYTHON]
; Path to the bundled Python runtime
PATH=
; Additional packages for the COM servers (PySide6, PyOpenGL)
PYTHONPATH=
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

# ---------------------------------------------------------------------------
# 6. (Optional) Build NSIS installer
# ---------------------------------------------------------------------------
$installerExe = $null
if ($Installer) {
    Write-Step "Building installer"

    $nsisExe = @(
        "C:\Program Files\NSIS\makensis.exe",
        "C:\Program Files (x86)\NSIS\makensis.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $nsisExe) {
        Write-Error "NSIS not found. Install NSIS from https://nsis.sourceforge.io"
    }

    # Stage LICENSE.txt
    $licenseSrc = Join-Path $REPO "LICENSE.txt"
    if (Test-Path $licenseSrc) {
        Copy-Item $licenseSrc $OUT_DIR -Force
        Write-Item "LICENSE.txt"
    } else {
        Write-Warning "LICENSE.txt not found in repo root, installer may fail."
    }

    # Stage python\ (trimmed; same exclusions as install.ps1)
    $pythonDst = Join-Path $OUT_DIR "python"
    if (Test-Path $USD_PY) {
        if (Test-Path $pythonDst) { Remove-Item $pythonDst -Recurse -Force }
        $rcPythonArgs = @(
            $USD_PY, $pythonDst,
            '/E', '/R:3', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS',
            '/XD', 'include', 'libs', 'MaterialX', 'Tools', 'test', 'idlelib', 'ensurepip',
            '/XF', '*.pdb', '*.lib'
        )
        $null = & robocopy @rcPythonArgs
        Write-Item "python\ (staged for installer)"
    } else {
        Write-Warning "python\ not found at '$USD_PY'; installer will not bundle Python."
    }

    # Stage pip-packages\ (trimmed; same exclusions as install.ps1)
    $pipDst = Join-Path $OUT_DIR "pip-packages"
    if (Test-Path $USD_PKGS) {
        if (Test-Path $pipDst) { Remove-Item $pipDst -Recurse -Force }
        $rcPipArgs = @(
            $USD_PKGS, $pipDst,
            '/E', '/PURGE', '/R:3', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS',
            '/XD', 'qml', 'metatypes', 'typesystems', 'include', 'translations',
            '/XF',
            'Qt6WebEngine*.dll', 'Qt6WebEngine*.pyd',
            'Qt6Designer*.dll', 'Qt6Designer*.pyd',
            'Qt6Qml*.dll', 'Qt6Qml*.pyd',
            'Qt6Quick*.dll', 'Qt6Quick*.pyd',
            'Qt63D*.dll', 'Qt63D*.pyd',
            'Qt6Charts*.dll', 'Qt6Charts*.pyd',
            'Qt6Graphs*.dll', 'Qt6Graphs*.pyd',
            'Qt6ShaderTools*.dll', 'Qt6ShaderTools*.pyd',
            'Qt6Pdf*.dll', 'Qt6Pdf*.pyd',
            'Qt6Multimedia*.dll', 'Qt6Multimedia*.pyd',
            'Qt6RemoteObjects*.dll', 'Qt6RemoteObjects*.pyd',
            'Qt6DataVisualization*.dll', 'Qt6DataVisualization*.pyd',
            '*.pdb'
        )
        $null = & robocopy @rcPipArgs
        Write-Item "pip-packages\ (staged for installer)"
    } else {
        Write-Warning "pip-packages\ not found at '$USD_PKGS'; installer will not bundle pip packages."
    }

    $installerVcxproj = Join-Path $REPO "UsdShellExtensionInstaller\UsdShellExtensionInstaller.vcxproj"
    $msbuildInstallerArgs = @(
        $installerVcxproj,
        "/p:Configuration=Release",
        "/p:Platform=x64",
        "/p:VCToolsVersion=$vcToolsVersion",
        "/p:PythonHome=$PythonHome",
        "/p:MAKENSIS=$nsisExe",
        "/p:SolutionDir=$REPO\",
        "/nologo",
        "/verbosity:minimal",
        "/clp:Summary"
    )

    $prevOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $env:VSLANG = "1033"
    & $msbuild @msbuildInstallerArgs
    [Console]::OutputEncoding = $prevOutputEncoding

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Installer build failed with exit code $LASTEXITCODE"
    }

    $installerExe = Get-ChildItem $OUT_DIR -Filter "UsdShellExtension-*-setup.exe" |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1

    Write-Host ""
    Write-Host $SEP -ForegroundColor DarkGray
    Write-Host "    Installer ready" -ForegroundColor Green
    Write-Host $SEP -ForegroundColor DarkGray
    if ($installerExe) {
        Write-Detail "Installer" $installerExe.FullName
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 7. (Optional) Publish GitHub release
# ---------------------------------------------------------------------------
if ($Release) {
    Write-Step "Publishing GitHub release"

    if (-not $version) {
        Write-Error "version.txt not found or empty. Cannot create a release without a version number."
    }

    $tag = "v$version"

    if (-not $installerExe -or -not (Test-Path $installerExe.FullName)) {
        Write-Error "Installer .exe not found in '$OUT_DIR'. The -Installer step must succeed before publishing."
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "gh CLI not found. Install from https://cli.github.com/ then run 'gh auth login'."
    }

    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh is not authenticated. Run 'gh auth login' first."
    }

    Write-Detail "Tag"   $tag
    Write-Detail "Asset" $installerExe.Name

    & gh release create $tag $installerExe.FullName --title $tag --generate-notes

    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh release create failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor DarkGray
    Write-Host "    Release published" -ForegroundColor Green
    Write-Host $SEP -ForegroundColor DarkGray
    Write-Host ""
}

Stop-Transcript | Out-Null
