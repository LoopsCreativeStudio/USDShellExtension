#Requires -Version 5.1
<#
.SYNOPSIS
    Build OpenUSD from the upstream sources, with its own Python runtime.

.DESCRIPTION
    Reads configuration from .env in the repo root (do not edit this script).
    Every step is skipped when its result is already on disk, so the script
    can be run again after a failure without starting over.

    1. Checks the prerequisites: Git, CMake 4.2 or later (first version with
       the "Visual Studio 18 2026" generator) and Visual Studio 2026 with the
       C++ x64 tools.
    2. Downloads the Python runtime (NuGet package "python", a full layout
       with headers and import libraries) and installs the Python packages
       usdview needs (PySide6, PyOpenGL, Jinja2, MarkupSafe) in a separate
       pip-packages folder, as in the NVIDIA package.
    3. Clones the OpenUSD release tag.
    4. Runs build_scripts\build_usd.py with that Python, in a clean
       environment: Visual Studio x64 variables, no Strawberry Perl, no other
       Python on PATH, no PYTHONHOME, PYTHONPATH limited to pip-packages.
    5. Assembles the install folder as a drop-in replacement for the NVIDIA
       package: copies the Python runtime to python\ and the license texts
       of every bundled component to PACKAGE-LICENSES\. Point USD_SDK in .env
       to the install folder to build the extension against it.

    Folder layout under OpenUsdDir (see Get-OpenUsdLayout):
        downloads\                      downloaded packages
        python\<python version>\        Python runtime used for the build
        src\<openusd version>\          OpenUSD sources
        deps\<openusd>-py<maj><min>\    dependency sources (TBB, OIIO, MaterialX...)
        build\<openusd>-py<maj><min>\   build files
        install\<openusd>-py<maj><min>\ result (USD_SDK): bin, lib, include, plugin,
                                        python, pip-packages, PACKAGE-LICENSES

    Downloads from GitHub, NuGet and PyPI. A full build takes one to two
    hours and around 30 GB of disk.

.PARAMETER OpenUsdVersion
    OpenUSD release tag (e.g. "v26.11.1").
    Overrides OPENUSD_VERSION in .env. Default: v26.11.1.

.PARAMETER PythonVersion
    Python version of the NuGet "python" package (e.g. "3.14.10").
    Overrides PYTHON_VERSION in .env. Default: 3.14.10.

.PARAMETER OpenUsdDir
    Root folder for sources, build files and the install folder.
    Overrides OPENUSD_DIR in .env. Default: D:\OpenUSD.

.PARAMETER LogFile
    Path to write a transcript log. Default: build-openusd.log in the repo directory.

.EXAMPLE
    PS> .\build-openusd.ps1 -OpenUsdVersion v26.11.1
#>
param(
    [string]$OpenUsdVersion = "",
    [string]$PythonVersion  = "",
    [string]$OpenUsdDir     = "",
    [string]$LogFile        = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO = $PSScriptRoot
$SEP  = "  " + ("=" * 52)

# Python packages usdview needs, pinned to their latest versions (#20).
# Only PySide6-Essentials (with shiboken6): usdview and the preview use
# QtCore, QtGui, QtWidgets, QtOpenGL and QtOpenGLWidgets, and Essentials
# provides pyside6-uic. The PySide6 meta package would add Addons, WebEngine
# and Pdf (about 300 MB) that nothing loads.
$PYTHON_PACKAGES = @('PySide6-Essentials==6.12.0', 'PyOpenGL==3.1.10', 'Jinja2==3.1.6', 'MarkupSafe==3.0.4')

# PATH entries removed for the build: Strawberry Perl ships its own CMake,
# compilers and libraries, and any other Python (including the WindowsApps
# store aliases) could be picked up instead of the build Python.
$EXCLUDED_PATH_PATTERNS = @('\\Strawberry\\', '\\Python\d+(\\|$)', '\\WindowsApps$')

$MINIMUM_CMAKE_VERSION = [version]'4.2'

# ---------------------------------------------------------------------------
# Helpers (Read-DotEnv, Get-OpenUsdLayout, Write-Step/Detail/Item, ...)
# ---------------------------------------------------------------------------
Import-Module (Join-Path $REPO "tools\UsdShellExtension.Build.psm1") -Force

# ---------------------------------------------------------------------------
# Load .env and resolve configuration (command line first, then .env, then default)
# ---------------------------------------------------------------------------
$cfg = Read-DotEnv (Join-Path $REPO ".env")

if (-not $OpenUsdVersion) { $OpenUsdVersion = if ($cfg['OPENUSD_VERSION']) { $cfg['OPENUSD_VERSION'] } else { "v26.11.1" } }
if (-not $PythonVersion)  { $PythonVersion  = if ($cfg['PYTHON_VERSION'])  { $cfg['PYTHON_VERSION'] }  else { "3.14.10" } }
if (-not $OpenUsdDir)     { $OpenUsdDir     = if ($cfg['OPENUSD_DIR'])     { $cfg['OPENUSD_DIR'] }     else { "D:\OpenUSD" } }

$layout = Get-OpenUsdLayout -Root $OpenUsdDir -OpenUsdVersion $OpenUsdVersion -PythonVersion $PythonVersion

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if ($LogFile -eq "") { $LogFile = Join-Path $REPO "build-openusd.log" }
try { Stop-Transcript | Out-Null } catch { $null = $_ }
Start-Transcript -Path $LogFile -Force | Out-Null

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ("    OpenUSD {0}  |  Python {1}" -f $OpenUsdVersion, $PythonVersion) -ForegroundColor White
Write-Host "    Build from source  |  Release | x64" -ForegroundColor DarkGray
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""
Write-Detail "Log"     $LogFile
Write-Detail "Root"    $layout.Root
Write-Detail "Install" $layout.Install

# ---------------------------------------------------------------------------
# 1. Build environment and prerequisites
# ---------------------------------------------------------------------------
Write-Step "Preparing the build environment"

# Visual Studio x64 variables (cl.exe, link.exe, INCLUDE, LIB...): run
# vcvars64.bat and copy the environment it leaves into this process.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Assert-Path $vswhere "vswhere.exe"
$vsInstallPath = & $vswhere -latest -products * `
                 -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                 -property installationPath 2>$null | Select-Object -First 1
if (-not $vsInstallPath) {
    throw "Visual Studio with the C++ x64 tools not found. Install the 'Desktop development with C++' workload."
}
$vcvars = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvars64.bat"
Assert-Path $vcvars "vcvars64.bat"

# vcvars64.bat calls vswhere.exe itself and expects it on PATH.
$env:Path = "{0};{1}" -f (Split-Path $vswhere -Parent), $env:Path
$vcvarsEnvironment = & cmd.exe /c "`"$vcvars`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed with exit code $LASTEXITCODE" }
foreach ($line in $vcvarsEnvironment) {
    $separatorIndex = $line.IndexOf('=')
    if ($separatorIndex -gt 0) {
        [Environment]::SetEnvironmentVariable($line.Substring(0, $separatorIndex), $line.Substring($separatorIndex + 1), 'Process')
    }
}
Write-Detail "Visual Studio" $vsInstallPath
Write-Detail "MSVC"          $env:VCToolsVersion

# Clean PATH, with the build Python, its Scripts folder and the pip-packages
# scripts (pyside6-uic, needed by usdview) first. PySide6 and the other
# packages live in pip-packages, which is the only PYTHONPATH entry.
# Only this process is changed; the user and machine PATH stay as they are.
$pythonExe  = Join-Path $layout.Python "python.exe"
$cleanPath  = Get-PathWithoutEntry -Path $env:Path -Pattern $EXCLUDED_PATH_PATTERNS
$env:Path   = "{0};{1};{2};{3}" -f $layout.Python, (Join-Path $layout.Python "Scripts"), (Join-Path $layout.PipPackages "bin"), $cleanPath
$env:PYTHONHOME = $null
$env:PYTHONPATH = $layout.PipPackages
$env:PYTHONNOUSERSITE = "1"   # never pick packages from the user site-packages

# CMake 4 refuses projects that declare cmake_minimum_required below 3.5.
# build_usd.py passes -DCMAKE_POLICY_VERSION_MINIMUM=3.5 to some dependencies,
# but not to the ones OpenColorIO downloads itself (yaml-cpp, expat); the
# environment variable reaches every nested CMake run.
$env:CMAKE_POLICY_VERSION_MINIMUM = "3.5"

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw "git not found on PATH. Install Git for Windows." }
Write-Detail "Git" $git.Source

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) { throw "cmake not found on PATH. Install CMake $MINIMUM_CMAKE_VERSION or later (cmake.org)." }
$cmakeVersionText = (& $cmake.Source --version | Select-Object -First 1)
if ($cmakeVersionText -notmatch '(\d+\.\d+(\.\d+)?)') { throw "Cannot read the CMake version from '$cmakeVersionText'." }
$cmakeVersion = [version]$Matches[1]
if ($cmakeVersion -lt $MINIMUM_CMAKE_VERSION) {
    throw "CMake $cmakeVersion found at $($cmake.Source); $MINIMUM_CMAKE_VERSION or later is required for the Visual Studio 2026 generator."
}
Write-Detail "CMake" ("{0} ({1})" -f $cmakeVersion, $cmake.Source)

$nasm = Get-Command nasm -ErrorAction SilentlyContinue
if ($nasm) { Write-Detail "NASM" $nasm.Source }
else       { Write-Item "NASM not found: libjpeg-turbo is built without SIMD (slower JPEG decoding)" }

# ---------------------------------------------------------------------------
# 2. Python runtime
# ---------------------------------------------------------------------------
Write-Step "Python $PythonVersion"

if (Test-Path $pythonExe) {
    Write-Item "Already installed in $($layout.Python)"
} else {
    # The .nupkg is a zip; Expand-Archive in Windows PowerShell 5.1 needs the .zip extension.
    $packageUrl  = "https://api.nuget.org/v3-flatcontainer/python/$PythonVersion/python.$PythonVersion.nupkg"
    $packageZip  = Join-Path $layout.Downloads "python.$PythonVersion.zip"
    $packageDir  = Join-Path $layout.Downloads "python.$PythonVersion"

    New-Item -ItemType Directory -Force $layout.Downloads | Out-Null
    Write-Item "Downloading $packageUrl"
    Invoke-WebRequest -Uri $packageUrl -OutFile $packageZip -UseBasicParsing

    # Extract to a scratch folder, then move only the runtime (tools\) in place,
    # so an interrupted extraction never leaves a half-installed Python.
    if (Test-Path $packageDir) { Remove-Item $packageDir -Recurse -Force }
    Expand-Archive -Path $packageZip -DestinationPath $packageDir
    New-Item -ItemType Directory -Force (Split-Path $layout.Python -Parent) | Out-Null
    Move-Item (Join-Path $packageDir "tools") $layout.Python
    Remove-Item $packageDir -Recurse -Force
    Write-Item "Installed in $($layout.Python)"
}

& $pythonExe -m ensurepip --upgrade | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ensurepip failed with exit code $LASTEXITCODE" }

# Packages go to pip-packages (pip --target), not to the runtime's
# site-packages, so the runtime stays clean. pip --target does not check what
# is already there: the requested list is saved next to the packages and the
# folder is rebuilt only when that list changes.
$requirementsFile = Join-Path $layout.PipPackages "requirements.txt"
$requestedPackages = $PYTHON_PACKAGES -join "`n"
$installedPackages = if (Test-Path $requirementsFile) { (Get-Content $requirementsFile -Raw).Trim() } else { "" }
if ($installedPackages -eq $requestedPackages) {
    Write-Item "Packages already in $($layout.PipPackages)"
} else {
    if (Test-Path $layout.PipPackages) { Remove-Item $layout.PipPackages -Recurse -Force }
    & $pythonExe -m pip install --disable-pip-version-check --no-warn-script-location `
        --target $layout.PipPackages @PYTHON_PACKAGES
    if ($LASTEXITCODE -ne 0) { throw "pip install failed with exit code $LASTEXITCODE" }
    Set-Content -Path $requirementsFile -Value $requestedPackages
}
Write-Item ("Packages: {0}" -f ($PYTHON_PACKAGES -join ', '))

# ---------------------------------------------------------------------------
# 3. OpenUSD sources
# ---------------------------------------------------------------------------
Write-Step "OpenUSD $OpenUsdVersion sources"

if (Test-Path (Join-Path $layout.Source "build_scripts\build_usd.py")) {
    Write-Item "Already cloned in $($layout.Source)"
} else {
    if (Test-Path $layout.Source) { throw "$($layout.Source) exists but has no build_scripts\build_usd.py. Delete it and run again." }
    & $git.Source -c advice.detachedHead=false clone --depth 1 --branch $OpenUsdVersion `
        https://github.com/PixarAnimationStudios/OpenUSD.git $layout.Source
    if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }
    Write-Item "Cloned in $($layout.Source)"
}

# ---------------------------------------------------------------------------
# 4. Build (build_usd.py skips the dependencies already installed)
# ---------------------------------------------------------------------------
Write-Step "Building OpenUSD (one to two hours on a first build)"

$buildArguments = Get-OpenUsdBuildArgument -Layout $layout
Write-Item ("python {0}" -f ($buildArguments -join ' '))
& $pythonExe @buildArguments
if ($LASTEXITCODE -ne 0) {
    # build_usd.py writes one log.txt per component and prints its path on failure.
    throw "build_usd.py failed with exit code $LASTEXITCODE. See the log.txt path printed above."
}

# ---------------------------------------------------------------------------
# 5. Assemble the SDK layout build.ps1 expects (python\, PACKAGE-LICENSES\)
# ---------------------------------------------------------------------------
Write-Step "Assembling the SDK folder"

Invoke-Robocopy $layout.Python $layout.SdkPython /MIR /R:3 /W:1
Write-Item "python\ (Python $PythonVersion runtime)"

Copy-OpenUsdLicense -Layout $layout
Write-Item ("PACKAGE-LICENSES\ ({0} files)" -f @(Get-ChildItem $layout.Licenses -File).Count)
Write-Detail "USD_SDK" $layout.Install

Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host "    OpenUSD built" -ForegroundColor Green
Write-Host ("    {0}" -f $layout.Install) -ForegroundColor DarkGray
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""

Stop-Transcript | Out-Null

# Every failure above stops the script; reaching this point means success.
# Exit explicitly so a leftover native exit code never reports a failure.
exit 0
