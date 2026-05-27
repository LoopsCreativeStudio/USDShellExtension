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

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct RM_UNIQUE_PROCESS {
    public int dwProcessId;
    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
    public string strServiceShortName;
    public int ApplicationType;
    public uint AppStatus;
    public int TSSessionId;
    [MarshalAs(UnmanagedType.Bool)]
    public bool bRestartable;
}

public static class LockFinder {
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint dwSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint dwSessionHandle);

    public static RM_PROCESS_INFO[] GetLockingProcesses(string filePath) {
        uint session = 0;
        var key = new StringBuilder(33);
        if (RmStartSession(out session, 0, key) != 0) return new RM_PROCESS_INFO[0];
        try {
            RmRegisterResources(session, 1, new[] { filePath }, 0, IntPtr.Zero, 0, null);
            uint needed = 0, count = 0, reasons = 0;
            RmGetList(session, out needed, ref count, null, ref reasons);
            if (needed == 0) return new RM_PROCESS_INFO[0];
            var infos = new RM_PROCESS_INFO[needed];
            count = needed;
            RmGetList(session, out needed, ref count, infos, ref reasons);
            return infos;
        } finally {
            RmEndSession(session);
        }
    }
}
"@ -ErrorAction SilentlyContinue
} catch { $null = $_ }

function Stop-FileLockingProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return }
    try { $infos = [LockFinder]::GetLockingProcesses($FilePath) } catch { return }
    if (-not $infos -or $infos.Count -eq 0) { return }
    $leaf = Split-Path $FilePath -Leaf
    Write-Host ("    {0} is locked by:" -f $leaf) -ForegroundColor DarkYellow
    foreach ($lk in $infos) {
        $line = "      PID {0,5}  {1}" -f $lk.Process.dwProcessId,
            $(if ($lk.strAppName) { $lk.strAppName } else { '(unknown)' })
        if ($lk.strServiceShortName) { $line += "  [service: $($lk.strServiceShortName)]" }
        Write-Host $line -ForegroundColor DarkYellow
        if ($lk.strServiceShortName -and $PSCmdlet.ShouldProcess($lk.strServiceShortName, 'Stop service')) {
            Stop-Service -Name $lk.strServiceShortName -Force -ErrorAction SilentlyContinue
        }
        if ($lk.Process.dwProcessId -gt 0 -and $PSCmdlet.ShouldProcess($lk.Process.dwProcessId, 'Stop process')) {
            Stop-Process -Id $lk.Process.dwProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
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

Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Write-Item "Windows Search service stopped"

Stop-Process -Name "UsdPythonToolsLocalServer","UsdPreviewLocalServer","UsdSdkToolsLocalServer" `
    -Force -ErrorAction SilentlyContinue
Stop-Process -Name "dllhost" -Force -ErrorAction SilentlyContinue
Write-Item "COM servers stopped"

# Add Defender exclusion now so it releases DLL handles before the wait loop.
try { Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop } catch { $null = $_ }
Start-Sleep -Seconds 2

$winlogonKey     = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$prevAutoRestart = 1
try {
    $prevAutoRestart = [int](Get-ItemPropertyValue $winlogonKey "AutoRestartShell" -ErrorAction Stop)
    Set-ItemProperty $winlogonKey "AutoRestartShell" 0 -Type DWord -ErrorAction SilentlyContinue
} catch { $null = $_ }

@("explorer","SearchHost","ShellExperienceHost","StartMenuExperienceHost",
  "SearchIndexer","SearchProtocolHost","SearchFilterHost") |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Write-Item "Shell processes stopped"

$lockedFile = Join-Path $InstallDir "python312.dll"
Stop-FileLockingProcess $lockedFile
if (Test-Path $lockedFile) {
    $waited  = 0
    $maxWait = 30
    while ($waited -lt $maxWait) {
        try {
            $fs = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $fs.Close()
            $fs.Dispose()
            break
        } catch {
            if ($waited -eq 0) {
                Write-Host "    python312.dll still locked, waiting..." -ForegroundColor DarkYellow
            }
            @("dllhost","explorer","SearchIndexer","SearchProtocolHost","SearchFilterHost") |
                ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 1
            $waited++
        }
    }
    if ($waited -ge $maxWait) {
        Write-Warning "python312.dll may still be locked after ${maxWait}s."
    } else {
        Write-Item ("File locks released (waited {0}s)" -f $waited)
    }
} else {
    Start-Sleep -Seconds 2
}

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
# ---------------------------------------------------------------------------
Write-Step "Removing install directory"
Write-Host ("    {0}" -f $InstallDir) -ForegroundColor Gray

# Leave the install dir as CWD would block rd /s /q on Windows.
Set-Location $env:TEMP

& takeown /f "$InstallDir" /r 2>&1 | Out-Null
& icacls "$InstallDir" /grant "*S-1-5-32-544:(F)" /t /c /q 2>&1 | Out-Null
Get-ChildItem $InstallDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { $null = $_ }
}
$savedEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& cmd /c rd /s /q "$InstallDir" 2>&1 | Out-Null
$ErrorActionPreference = $savedEap

if (Test-Path $InstallDir) {
    Write-Warning "Some files are still locked. Scheduling deletion on next reboot."
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PendingDelete {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool MoveFileExW(string src, string dst, uint flags);
    public const uint MOVEFILE_DELAY_UNTIL_REBOOT = 4;
}
"@ -ErrorAction SilentlyContinue
    } catch { $null = $_ }

    $failCount = 0
    Get-ChildItem $InstallDir -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object {
            if (-not [PendingDelete]::MoveFileExW(
                    $_.FullName, $null, [PendingDelete]::MOVEFILE_DELAY_UNTIL_REBOOT)) {
                $failCount++
                Write-Warning ("Could not schedule: {0}" -f $_.FullName)
            }
        }
    if (-not [PendingDelete]::MoveFileExW(
            $InstallDir, $null, [PendingDelete]::MOVEFILE_DELAY_UNTIL_REBOOT)) {
        $failCount++
        Write-Warning ("Could not schedule: {0}" -f $InstallDir)
    }

    if ($failCount -eq 0) {
        Write-Host "    Files scheduled for deletion on next reboot." -ForegroundColor DarkYellow
    } else {
        Write-Host ("    {0} item(s) could not be scheduled. Manual cleanup may be needed." `
            -f $failCount) -ForegroundColor Red
    }
} else {
    Write-Item "Install directory removed"
}

try { Remove-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue } catch { $null = $_ }

# ---------------------------------------------------------------------------
# Restart services and Explorer
# ---------------------------------------------------------------------------
try {
    Set-ItemProperty $winlogonKey "AutoRestartShell" $prevAutoRestart -Type DWord -ErrorAction SilentlyContinue
} catch { $null = $_ }

Start-Service -Name "WSearch" -ErrorAction SilentlyContinue
Write-Item "Windows Search service restarted"

Start-Sleep -Seconds 2
Start-Process "explorer.exe"
Write-Item "Explorer restarted"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host "    Uninstall complete" -ForegroundColor Green
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ""
Write-Detail "Log" $LogFile
Write-Host ""

Stop-Transcript | Out-Null
