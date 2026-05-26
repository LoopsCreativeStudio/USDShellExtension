#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall UsdShellExtension.

.DESCRIPTION
    Unregisters COM servers and removes the installation directory.
    Must be run as Administrator. If not elevated, re-launches automatically.

.PARAMETER LogFile
    Path to write a transcript log.
    Default: %TEMP%\UsdShellExtension_uninstall.log
#>
param(
    [string]$LogFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$InstallDir = $PSScriptRoot
$SEP        = "  " + ("=" * 52)

# ---------------------------------------------------------------------------
# Auto-elevate if not already running as Administrator
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    Start-Process powershell.exe -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if ($LogFile -eq "") {
    $LogFile = Join-Path $env:TEMP "UsdShellExtension_uninstall.log"
}
try { Stop-Transcript | Out-Null } catch { $null = $_ }
Start-Transcript -Path $LogFile -Force | Out-Null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host "    USD Shell Extension" -ForegroundColor White
Write-Host "    Uninstaller" -ForegroundColor DarkGray
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""

Write-Detail "InstallDir" $InstallDir
Write-Detail "Log"        $LogFile
Write-Detail "Date"       (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# ---------------------------------------------------------------------------
# Stop processes that may lock DLL/EXE files
# ---------------------------------------------------------------------------
Write-Step "Stopping processes"

Stop-Process -Name "UsdPythonToolsLocalServer","UsdPreviewLocalServer","UsdSdkToolsLocalServer" `
    -Force -ErrorAction SilentlyContinue
Stop-Process -Name "dllhost" -Force -ErrorAction SilentlyContinue
Write-Item "COM servers stopped"

$winlogonKey     = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$prevAutoRestart = 1
try {
    $prevAutoRestart = [int](Get-ItemPropertyValue $winlogonKey "AutoRestartShell" -ErrorAction Stop)
    Set-ItemProperty $winlogonKey "AutoRestartShell" 0 -Type DWord -ErrorAction SilentlyContinue
} catch { $null = $_ }

@("explorer","SearchHost","ShellExperienceHost","StartMenuExperienceHost") |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 4
Write-Item "Shell processes stopped"

# ---------------------------------------------------------------------------
# Unregister COM servers and shell extension
# ---------------------------------------------------------------------------
Write-Step "Unregistering COM servers"

$unreg = Join-Path $InstallDir "unregister.bat"
if (Test-Path $unreg) {
    $ErrorActionPreference = "Continue"
    & cmd /c $unreg
    $ErrorActionPreference = "Stop"
    Write-Item "COM servers unregistered"
} else {
    Write-Warning "unregister.bat not found in $InstallDir - skipping."
}

# ---------------------------------------------------------------------------
# Remove Windows Apps registry entries
# ---------------------------------------------------------------------------
Write-Step "Removing registry entries"
Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" `
    -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\SOFTWARE\UsdShellExtension" `
    -Recurse -ErrorAction SilentlyContinue
Write-Item "Registry entries removed"

# ---------------------------------------------------------------------------
# Clear icon and thumbnail caches
# ---------------------------------------------------------------------------
Write-Step "Clearing icon and thumbnail caches"

$explorerCache = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
$iconFiles  = Get-ChildItem $explorerCache -Filter "iconcache_*"  -ErrorAction SilentlyContinue
$thumbFiles = Get-ChildItem $explorerCache -Filter "thumbcache_*" -ErrorAction SilentlyContinue
$iconFiles  | Remove-Item -Force -ErrorAction SilentlyContinue
$thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Item ("{0} cache file(s) removed" -f ($iconFiles.Count + $thumbFiles.Count))

# ---------------------------------------------------------------------------
# Remove install directory
# Stop transcript before deleting so the log file is not held open.
# ---------------------------------------------------------------------------
Write-Step "Removing install directory"
Write-Host ("    {0}" -f $InstallDir) -ForegroundColor Gray

Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host "    Uninstall complete" -ForegroundColor Green
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""
Write-Detail "Log" $LogFile
Write-Host ""

Stop-Transcript | Out-Null

Set-Location $env:TEMP

Get-ChildItem $InstallDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { $null = $_ }
}
Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Restart Explorer
# ---------------------------------------------------------------------------
try {
    Set-ItemProperty $winlogonKey "AutoRestartShell" $prevAutoRestart -Type DWord -ErrorAction SilentlyContinue
} catch { $null = $_ }

Start-Sleep -Seconds 2
Start-Process "explorer.exe"
