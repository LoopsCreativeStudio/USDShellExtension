#Requires -Version 5.1
<#
.SYNOPSIS
    Install UsdShellExtension to Program Files and register COM servers.

.DESCRIPTION
    Reads configuration from .env in the repo root (do not edit this script).
    Copies all built files from the build output directory to the install
    directory, then registers the COM Local Servers and the shell extension DLL.
    Must be run as Administrator.

.PARAMETER Config
    Build configuration to install: Release or Debug.
    Overrides CONFIG in .env. Default: Release.

.PARAMETER InstallDir
    Destination directory.
    Overrides INSTALL_DIR in .env. Default: C:\Program Files\UsdShellExtension

.PARAMETER Uninstall
    Unregister and remove the installation.

.PARAMETER LogFile
    Path to write a transcript log. Default: install.log in the repo directory.
#>
param(
    [string]$Config     = "",
    [string]$InstallDir = "",
    [switch]$Uninstall,
    [string]$LogFile    = ""
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

function Invoke-Unregister {
    param([string]$dir)
    $unreg = Join-Path $dir "unregister.bat"
    if (Test-Path $unreg) {
        Write-Step "Unregistering from $dir"
        $ErrorActionPreference = "Continue"
        & cmd /c $unreg
        $ErrorActionPreference = "Stop"
    } else {
        Write-Warning "unregister.bat not found in $dir - skipping."
    }
}

function Copy-WithRetry {
    param([string]$Source, [string]$Dest, [int]$Retries = 6, [int]$DelaySec = 2)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Copy-Item $Source $Dest -Force -ErrorAction Stop
            return
        } catch [System.IO.IOException] {
            if ($i -lt $Retries) {
                Write-Host ("    Locked, retry {0}/{1}, waiting {2}s..." -f $i, $Retries, $DelaySec) -ForegroundColor DarkYellow
                Start-Sleep -Seconds $DelaySec
            } else {
                throw
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Load .env and resolve configuration
# ---------------------------------------------------------------------------
$cfg = Read-DotEnv (Join-Path $REPO ".env")

$USD_SDK    = if ($cfg['USD_SDK'])      { $cfg['USD_SDK'] }      else { "D:\usd.py312.windows-x86_64.usdview.release-v25.08" }
if (-not $Config)     { $Config     = if ($cfg['CONFIG'])      { $cfg['CONFIG'] }      else { "Release" } }
if (-not $InstallDir) { $InstallDir = if ($cfg['INSTALL_DIR']) { $cfg['INSTALL_DIR'] } else { "C:\Program Files\UsdShellExtension" } }
if ($Config -notin @('Release', 'Debug')) {
    Write-Error "CONFIG must be 'Release' or 'Debug' (got: '$Config'). Check .env or use -Config."
}

$OUT_DIR = Join-Path $REPO "bin\v145\3.12\$Config"

$version = if (Test-Path (Join-Path $REPO "version.txt")) {
    (Get-Content (Join-Path $REPO "version.txt")).Trim()
} else { "" }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if ($LogFile -eq "") { $LogFile = Join-Path $REPO "install.log" }
try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path $LogFile -Force | Out-Null

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
$action = if ($Uninstall) { "Uninstall" } else { "Install" }

Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ("    USD Shell Extension  {0}" -f $(if ($version) { "v$version" } else { "" })) -ForegroundColor White
Write-Host ("    {0}  |  {1} | x64" -f $action, $Config) -ForegroundColor DarkGray
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""

Write-Detail "InstallDir" $InstallDir
Write-Detail "Log"        $LogFile
Write-Detail "Date"       (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# ---------------------------------------------------------------------------
# Require Administrator
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Stop-Transcript | Out-Null
    Write-Error "This script must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
}

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Invoke-Unregister $InstallDir

    Write-Step "Removing install directory"
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Item $InstallDir
    } else {
        Write-Host "    Nothing to remove at $InstallDir" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host $SEP -ForegroundColor DarkGray
    Write-Host "    Uninstall complete" -ForegroundColor Green
    Write-Host $SEP -ForegroundColor DarkGray
    Write-Host ""
    Write-Detail "Log" $LogFile
    Write-Host ""
    Stop-Transcript | Out-Null
    return
}

# ---------------------------------------------------------------------------
# Clean up any pre-existing installations
# ---------------------------------------------------------------------------
$oldLocations = @(
    "C:\Program Files\Activision\UsdShellExtension",
    "C:\Program Files\UsdShellExtension_legacy",
    $InstallDir
)

foreach ($oldDir in $oldLocations) {
    if (-not (Test-Path $oldDir)) { continue }
    Invoke-Unregister $oldDir
    if ($oldDir -ne $InstallDir) {
        Write-Host ("    Removing {0}" -f $oldDir) -ForegroundColor Gray
        Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        $parent = Split-Path $oldDir -Parent
        if ((Test-Path $parent) -and (-not (Get-ChildItem $parent))) {
            Remove-Item $parent -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Stop processes that may lock DLL/EXE files
# ---------------------------------------------------------------------------
Write-Step "Stopping processes"

Stop-Process -Name "UsdPythonToolsLocalServer","UsdPreviewLocalServer","UsdSdkToolsLocalServer" `
    -Force -ErrorAction SilentlyContinue
Stop-Process -Name "dllhost" -Force -ErrorAction SilentlyContinue
Get-Process -Name "python","python3","python3.12" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallDir*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Write-Item "COM servers stopped"

@("explorer", "SearchHost", "ShellExperienceHost", "StartMenuExperienceHost") |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 4
Write-Item "Shell processes stopped"

# ---------------------------------------------------------------------------
# Copy files
# ---------------------------------------------------------------------------
if (-not (Test-Path $OUT_DIR)) {
    Write-Error "Build output not found at: $OUT_DIR - Run .\build.ps1 first."
}

Write-Step "Copying files to $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Get-ChildItem $OUT_DIR -File | Where-Object {
    $_.Extension -notin @('.exp', '.lib')
} | ForEach-Object {
    Copy-WithRetry $_.FullName $InstallDir
    Write-Item $_.Name
}

$uninstallerSrc = Join-Path $REPO "uninstaller.ps1"
if (Test-Path $uninstallerSrc) {
    Copy-WithRetry $uninstallerSrc $InstallDir
    Write-Item "uninstaller.ps1"
}

$usdPluginSrc = Join-Path $OUT_DIR "usd"
if (Test-Path $usdPluginSrc) {
    $usdPluginDst = Join-Path $InstallDir "usd"
    if (Test-Path $usdPluginDst) { Remove-Item $usdPluginDst -Recurse -Force }
    Copy-Item $usdPluginSrc $usdPluginDst -Recurse -Force
    Write-Item "usd\ (plugin folder)"
}

$usdExtPluginSrc = Join-Path $OUT_DIR "plugin\usd"
if (Test-Path $usdExtPluginSrc) {
    $usdExtPluginDst = Join-Path $InstallDir "plugin\usd"
    if (Test-Path $usdExtPluginDst) { Remove-Item $usdExtPluginDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "plugin") | Out-Null
    Copy-Item $usdExtPluginSrc $usdExtPluginDst -Recurse -Force
    Write-Item "plugin\usd\ (hdStorm, usdAbc, ...)"
}

# ---------------------------------------------------------------------------
# Copy Python from SDK
# ---------------------------------------------------------------------------
$pythonSrc = Join-Path $USD_SDK "python"
$pythonDst = Join-Path $InstallDir "python"
if (Test-Path $pythonSrc) {
    Write-Step "Copying Python from SDK"
    if (Test-Path $pythonDst) { Remove-Item $pythonDst -Recurse -Force }
    $rcArgs = @(
        $pythonSrc, $pythonDst,
        "/E",
        "/NFL", "/NDL", "/NJH", "/NJS",
        "/XD", "include", "libs", "MaterialX", "Tools", "test", "idlelib", "ensurepip",
        "/XF", "*.pdb", "*.lib"
    )
    & robocopy @rcArgs | Out-Null
    Write-Item "python\ (bundled Python 3.12, trimmed)"
} else {
    Write-Warning "Python folder not found at $pythonSrc - skipping."
}

# ---------------------------------------------------------------------------
# Copy pip-packages (PySide6, PyOpenGL, etc.)
# ---------------------------------------------------------------------------
$pipSrc = Join-Path $USD_SDK "pip-packages"
$pipDst = Join-Path $InstallDir "pip-packages"
if (Test-Path $pipSrc) {
    Write-Step "Copying pip-packages"
    if (Test-Path $pipDst) { Remove-Item $pipDst -Recurse -Force }
    $rcArgs = @(
        $pipSrc, $pipDst,
        "/E",
        "/NFL", "/NDL", "/NJH", "/NJS",
        "/XD", "qml", "metatypes", "typesystems", "include", "translations",
        "/XF",
            "Qt6WebEngine*.dll",   "Qt6WebEngine*.pyd",
            "Qt6Designer*.dll",    "Qt6Designer*.pyd",
            "Qt6Qml*.dll",         "Qt6Qml*.pyd",
            "Qt6Quick*.dll",       "Qt6Quick*.pyd",
            "Qt63D*.dll",          "Qt63D*.pyd",
            "Qt6Charts*.dll",      "Qt6Charts*.pyd",
            "Qt6Graphs*.dll",      "Qt6Graphs*.pyd",
            "Qt6ShaderTools*.dll", "Qt6ShaderTools*.pyd",
            "Qt6Pdf*.dll",         "Qt6Pdf*.pyd",
            "Qt6Multimedia*.dll",  "Qt6Multimedia*.pyd",
            "Qt6RemoteObjects*.dll",     "Qt6RemoteObjects*.pyd",
            "Qt6DataVisualization*.dll", "Qt6DataVisualization*.pyd",
            "*.pdb"
    )
    & robocopy @rcArgs | Out-Null
    Write-Item "pip-packages\ (PySide6, PyOpenGL, trimmed)"
}

# ---------------------------------------------------------------------------
# Register COM servers
# ---------------------------------------------------------------------------
Write-Step "Registering COM servers"

$reg = Join-Path $InstallDir "register.bat"
if (-not (Test-Path $reg)) {
    Write-Error "register.bat not found in $InstallDir"
}
& cmd /c $reg
if ($LASTEXITCODE -ne 0) {
    Write-Error "Registration failed (exit code $LASTEXITCODE)."
}
Write-Item "COM servers registered"

# ---------------------------------------------------------------------------
# Clear MuiCache
# ---------------------------------------------------------------------------
Write-Step "Clearing MuiCache"

$muiCache = "HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
if (Test-Path $muiCache) {
    Get-Item $muiCache | Select-Object -ExpandProperty Property |
        Where-Object { $_ -like "*UsdShellExtension*" -or $_ -like "*Activision*" } |
        ForEach-Object {
            Remove-ItemProperty -Path $muiCache -Name $_ -ErrorAction SilentlyContinue
            Write-Item ("Cleared: {0}" -f $_)
        }
}

# ---------------------------------------------------------------------------
# Clear icon and thumbnail caches, then restart Explorer
# ---------------------------------------------------------------------------
Write-Step "Clearing icon and thumbnail caches"

$explorerCache = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
$iconFiles  = Get-ChildItem $explorerCache -Filter "iconcache_*"  -ErrorAction SilentlyContinue
$thumbFiles = Get-ChildItem $explorerCache -Filter "thumbcache_*" -ErrorAction SilentlyContinue
$iconFiles  | Remove-Item -Force -ErrorAction SilentlyContinue
$thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Item ("{0} cache file(s) removed" -f ($iconFiles.Count + $thumbFiles.Count))

Write-Step "Restarting Explorer"
Start-Process "explorer.exe"
Start-Sleep -Seconds 3
Write-Item "Explorer restarted"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host "    Installation complete" -ForegroundColor Green
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""

Write-Detail "Installed to" $InstallDir
Write-Detail "Log"          $LogFile
Write-Host ""
Write-Host "  To uninstall (run as Administrator):" -ForegroundColor White
Write-Host "    .\install.ps1 -Uninstall" -ForegroundColor Yellow
Write-Host ""

Stop-Transcript | Out-Null
