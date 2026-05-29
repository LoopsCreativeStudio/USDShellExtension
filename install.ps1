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
function Remove-InstallDir {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Dir)

    if (-not (Test-Path $Dir)) { return }
    if (-not $PSCmdlet.ShouldProcess($Dir, 'Remove directory')) { return }

    # Kill any COM server that may have been respawned after the main process-stop phase.
    Stop-Process -Name "UsdPythonToolsLocalServer","UsdPreviewLocalServer","UsdSdkToolsLocalServer","dllhost" `
        -Force -ErrorAction SilentlyContinue

    # Give Windows Defender time to release DLL handles after the exclusion is added.
    try { Add-MpPreference -ExclusionPath $Dir -ErrorAction Stop } catch { $null = $_ }
    Start-Sleep -Seconds 5

    & takeown /f "$Dir" /r 2>&1 | Out-Null
    & icacls "$Dir" /grant "*S-1-5-32-544:(F)" /t /c /q 2>&1 | Out-Null
    Get-ChildItem $Dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { $null = $_ }
    }

    # Use Continue so a non-zero exit code from rd does not terminate the script.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & cmd /c rd /s /q "$Dir" 2>&1 | Out-Null
    $ErrorActionPreference = $savedEap

    if (-not (Test-Path $Dir)) {
        try { Remove-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue } catch { $null = $_ }
        return
    }

    # Some files are still locked; schedule them for deletion on next reboot
    # (same mechanism as NSIS Delete /REBOOTOK).
    Write-Warning "Some files are still locked. They will be removed on the next reboot."
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

    Get-ChildItem $Dir -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object { [PendingDelete]::MoveFileExW($_.FullName, $null, [PendingDelete]::MOVEFILE_DELAY_UNTIL_REBOOT) | Out-Null }
    [PendingDelete]::MoveFileExW($Dir, $null, [PendingDelete]::MOVEFILE_DELAY_UNTIL_REBOOT) | Out-Null

    try { Remove-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue } catch { $null = $_ }
}

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

function Write-Removed {
    param([string]$msg)
    Write-Host ("    - {0}" -f $msg) -ForegroundColor Yellow
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

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class NativeFileHelper {
    const uint DELETE             = 0x00010000;
    const uint FILE_SHARE_READ    = 0x00000001;
    const uint FILE_SHARE_WRITE   = 0x00000002;
    const uint FILE_SHARE_DELETE  = 0x00000004;
    const uint OPEN_EXISTING      = 3;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    const int  FileRenameInformationEx    = 65;
    const uint FLAG_REPLACE   = 0x00000001;
    const uint FLAG_POSIX     = 0x00000002;

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(
        string f, uint access, uint share, IntPtr sa,
        uint cd, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SetFileInformationByHandle(
        SafeFileHandle h, int cls, byte[] buf, uint len);

    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    // Atomically replace targetPath with newFilePath using POSIX rename semantics.
    // Works even when targetPath is loaded as a Windows image section (mapped DLL/EXE).
    // Requires Windows 10 1607+ and SeBackupPrivilege (Administrator).
    public static bool PosixReplace(string newFilePath, string targetPath) {
        using (var h = CreateFileW(newFilePath, DELETE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
        {
            if (h.IsInvalid) return false;
            // FILE_RENAME_INFORMATION layout (x64):
            //  [0..3]   ULONG Flags
            //  [4..7]   padding (union with BOOLEAN ReplaceIfExists)
            //  [8..15]  HANDLE RootDirectory (null)
            //  [16..19] ULONG FileNameLength (bytes)
            //  [20..]   WCHAR FileName[]
            byte[] name = Encoding.Unicode.GetBytes(targetPath);
            byte[] buf  = new byte[20 + name.Length];
            BitConverter.GetBytes(FLAG_REPLACE | FLAG_POSIX).CopyTo(buf,  0);
            BitConverter.GetBytes((uint)name.Length).CopyTo(buf, 16);
            name.CopyTo(buf, 20);
            return SetFileInformationByHandle(h, FileRenameInformationEx, buf, (uint)buf.Length);
        }
    }
}
"@
} catch { $null = $_ }

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

function Copy-WithRetry {
    param([string]$Source, [string]$Dest, [int]$Retries = 5, [int]$DelaySec = 2)

    # Normalize: if $Dest is an existing directory, resolve the target file path.
    if (Test-Path $Dest -PathType Container) {
        $Dest = Join-Path $Dest (Split-Path $Source -Leaf)
    }

    # Fast path: direct overwrite when the file is not locked.
    try {
        Copy-Item $Source $Dest -Force -ErrorAction Stop
        return
    } catch [System.IO.IOException] { $null = $_ }

    # The destination is locked (in-use DLL / EXE).  On NTFS, renaming a
    # file succeeds even with open handles because it only updates the
    # directory entry; existing mappings and handles remain valid.  Rename
    # the old copy aside, write the new one, then clean up the leftovers.
    if (Test-Path $Dest) {
        $oldPath = $Dest + ".old"
        try {
            if (Test-Path $oldPath) { Remove-Item $oldPath -Force -ErrorAction SilentlyContinue }
            Rename-Item $Dest $oldPath -ErrorAction Stop
            Copy-Item $Source $Dest -Force -ErrorAction Stop
            Remove-Item $oldPath -Force -ErrorAction SilentlyContinue
            return
        } catch {
            if (-not (Test-Path $Dest) -and (Test-Path $oldPath)) {
                try { Rename-Item $oldPath $Dest -ErrorAction SilentlyContinue } catch { $null = $_ }
            }
        }
    }

    # The file is loaded as a Windows image section: standard rename is blocked.
    # Use SetFileInformationByHandle with FileRenameInformationEx + POSIX_SEMANTICS,
    # which atomically replaces a mapped DLL/EXE even with active image sections
    # (Windows 10 1607+). Copy to a temp file first, then POSIX-rename it into place.
    $tempDest = $Dest + ".new"
    $posixOk  = $false
    try {
        if (Test-Path $tempDest) { Remove-Item $tempDest -Force -ErrorAction SilentlyContinue }
        Copy-Item $Source $tempDest -Force -ErrorAction Stop
        $posixOk = [NativeFileHelper]::PosixReplace($tempDest, $Dest)
    } catch { $null = $_ }
    if (-not $posixOk -and (Test-Path $tempDest)) {
        Remove-Item $tempDest -Force -ErrorAction SilentlyContinue
    }
    if ($posixOk) { return }

    # Last resort: timed retry loop.
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

function Stop-FileLockingProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return }
    try { $infos = [LockFinder]::GetLockingProcesses($FilePath) } catch { return }
    if (-not $infos -or $infos.Count -eq 0) { return }
    Write-Host ("    {0} is locked by:" -f (Split-Path $FilePath -Leaf)) -ForegroundColor DarkYellow
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
try { Stop-Transcript | Out-Null } catch { $null = $_ }
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

    Write-Step "Stopping processes"

    Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue

    Stop-Process -Name "UsdPythonToolsLocalServer","UsdPreviewLocalServer","UsdSdkToolsLocalServer" `
        -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "dllhost" -Force -ErrorAction SilentlyContinue
    Get-Process -Name "python","python3","python3.12" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$InstallDir*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Item "COM servers stopped"

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

    Invoke-Unregister $InstallDir

    Write-Step "Removing registry entries"
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension" `
        -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\SOFTWARE\UsdShellExtension" `
        -Recurse -ErrorAction SilentlyContinue
    Write-Item "Registry entries removed"

    Write-Step "Removing install directory"
    if (Test-Path $InstallDir) {
        Remove-InstallDir $InstallDir
        if (Test-Path $InstallDir) {
            Write-Host "    Locked files scheduled for deletion on next reboot." -ForegroundColor DarkYellow
        } else {
            Write-Removed $InstallDir
        }
    } else {
        Write-Host "    Nothing to remove at $InstallDir" -ForegroundColor Gray
    }

    try {
        Set-ItemProperty $winlogonKey "AutoRestartShell" $prevAutoRestart -Type DWord -ErrorAction SilentlyContinue
    } catch { $null = $_ }

    Start-Service -Name "WSearch" -ErrorAction SilentlyContinue

    Write-Step "Clearing icon and thumbnail caches"
    $explorerCache = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    $iconFiles  = Get-ChildItem $explorerCache -Filter "iconcache_*"  -ErrorAction SilentlyContinue
    $thumbFiles = Get-ChildItem $explorerCache -Filter "thumbcache_*" -ErrorAction SilentlyContinue
    $iconFiles  | Remove-Item -Force -ErrorAction SilentlyContinue
    $thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Removed ("{0} icon/thumbnail cache file(s) removed" -f ($iconFiles.Count + $thumbFiles.Count))

    Write-Step "Restarting Explorer"
    Start-Sleep -Seconds 2
    Start-Process "explorer.exe"
    Write-Item "Explorer restarted"

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
        Write-Removed ("Removing {0}" -f $oldDir)
        Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        $parent = Split-Path $oldDir -Parent
        if ((Test-Path $parent) -and (-not (Get-ChildItem $parent))) {
            Remove-Item $parent -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host $SEP -ForegroundColor DarkYellow
Write-Host "    NOTE : the screen may go black for a few seconds." -ForegroundColor Yellow
Write-Host "    This is normal. Windows Explorer must reset to update" -ForegroundColor Yellow
Write-Host "    the shell extension. Do not touch the keyboard or mouse" -ForegroundColor Yellow
Write-Host "    until Explorer restarts automatically." -ForegroundColor Yellow
Write-Host $SEP -ForegroundColor DarkYellow
Write-Host ""

do {
    $confirm = (Read-Host "  Press Enter, Y or Yes to continue (Ctrl+C to abort)").Trim().ToLower()
} while ($confirm -notin @('', 'y', 'yes'))

# ---------------------------------------------------------------------------
# Stop processes that may lock DLL/EXE files
# ---------------------------------------------------------------------------
Write-Step "Stopping processes"

# Stop the Windows Search service so SearchIndexer cannot respawn and re-lock DLLs.
Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue

Stop-Process -Name "UsdPythonToolsLocalServer","UsdPreviewLocalServer","UsdSdkToolsLocalServer" `
    -Force -ErrorAction SilentlyContinue
Stop-Process -Name "dllhost" -Force -ErrorAction SilentlyContinue
Get-Process -Name "python","python3","python3.12" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallDir*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Write-Item "COM servers stopped"

# Release Windows Defender handles on the install dir before the lock-wait loop.
# Without this, Defender re-acquires DLL handles after scanning and the loop times out.
try { Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop } catch { $null = $_ }
Start-Sleep -Seconds 2

# Disable Explorer auto-restart so Win11 does not respawn it during the
# lock-wait loop.  A restarted Explorer reloads UsdShellExtension.dll via
# its activation context and immediately re-locks python312.dll.
$winlogonKey     = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$prevAutoRestart = 1
try {
    $prevAutoRestart = [int](Get-ItemPropertyValue $winlogonKey "AutoRestartShell" -ErrorAction Stop)
    Set-ItemProperty $winlogonKey "AutoRestartShell" 0 -Type DWord -ErrorAction SilentlyContinue
} catch { $null = $_ }

@("explorer", "SearchHost", "ShellExperienceHost", "StartMenuExperienceHost",
  "SearchIndexer", "SearchProtocolHost", "SearchFilterHost") |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Write-Item "Shell processes stopped"

# Wait for python312.dll to be released.  Re-kill dllhost and Explorer on
# every iteration; with AutoRestartShell=0 Explorer will not respawn by
# itself, so only COM-triggered dllhost instances need chasing.
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
                Write-Host "    python312.dll still locked, waiting for handles to release..." `
                    -ForegroundColor DarkYellow
            }
            @("dllhost", "explorer", "SearchIndexer", "SearchProtocolHost", "SearchFilterHost") |
                ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 1
            $waited++
        }
    }
    if ($waited -ge $maxWait) {
        Write-Warning "python312.dll may still be locked after ${maxWait}s. Copy-WithRetry will keep retrying."
    } else {
        Write-Item ("File locks released (waited {0}s)" -f $waited)
    }
} else {
    Start-Sleep -Seconds 2
}

# Restore Explorer auto-restart; Explorer will be launched manually below.
try {
    Set-ItemProperty $winlogonKey "AutoRestartShell" $prevAutoRestart -Type DWord -ErrorAction SilentlyContinue
} catch { $null = $_ }

# ---------------------------------------------------------------------------
# Copy files
# ---------------------------------------------------------------------------
if (-not (Test-Path $OUT_DIR)) {
    Write-Error "Build output not found at: $OUT_DIR - Run .\build.ps1 first."
}

Write-Step "Copying files to $InstallDir"

# Guard: a previous botched Copy-WithRetry may have left a FILE at $InstallDir
# (the entire directory was renamed away and a script/DLL was written in its place).
# New-Item -Force does not replace a file with a directory in PS 5.1, so remove it first.
if (Test-Path $InstallDir -PathType Leaf) {
    Write-Warning "Install path exists as a file (corrupted state) - removing it."
    Remove-Item $InstallDir -Force
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
if (-not (Test-Path $InstallDir -PathType Container)) {
    Write-Error "Failed to create install directory: $InstallDir"
}

# Remove leftover .old files from any previous rename-on-lock replacements.
Get-ChildItem $InstallDir -Filter "*.old" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    Write-Removed $_.Name
}

Get-ChildItem $OUT_DIR -File | Where-Object {
    $_.Extension -notin @('.exp', '.lib') -and
    $_.Name -notlike 'UsdShellExtension-*-setup.exe'
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
    if (Test-Path $usdPluginDst) {
        Remove-Item $usdPluginDst -Recurse -Force
        Write-Removed "usd\ (old plugin folder)"
    }
    Write-Host "    Copying usd\ ..." -ForegroundColor Gray
    $rcOut = & robocopy $usdPluginSrc $usdPluginDst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS 2>&1
    if ($LASTEXITCODE -ge 8) {
        Write-Error ("robocopy failed copying usd\ (exit $LASTEXITCODE):`n" + ($rcOut -join "`n"))
    }
    Write-Item "usd\ (plugin folder)"
}

$usdExtPluginSrc = Join-Path $OUT_DIR "plugin\usd"
if (Test-Path $usdExtPluginSrc) {
    $usdExtPluginDst = Join-Path $InstallDir "plugin\usd"
    if (Test-Path $usdExtPluginDst) { Remove-Item $usdExtPluginDst -Recurse -Force }
    Write-Host "    Copying plugin\usd\ ..." -ForegroundColor Gray
    & robocopy $usdExtPluginSrc $usdExtPluginDst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed copying plugin\usd\ (exit $LASTEXITCODE)" }
    Write-Item "plugin\usd\ (hdStorm, usdAbc, ...)"
}

$usdLibPySrc = Join-Path $OUT_DIR "lib\python"
if (Test-Path $usdLibPySrc) {
    $usdLibPyDst = Join-Path $InstallDir "lib\python"
    if (Test-Path $usdLibPyDst) { Remove-Item $usdLibPyDst -Recurse -Force }
    Write-Host "    Copying lib\python\ ..." -ForegroundColor Gray
    & robocopy $usdLibPySrc $usdLibPyDst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed copying lib\python\ (exit $LASTEXITCODE)" }
    Write-Item "lib\python\ (pxr Python bindings)"
}

$usdScriptsSrc = Join-Path $OUT_DIR "scripts"
if (Test-Path $usdScriptsSrc) {
    $usdScriptsDst = Join-Path $InstallDir "scripts"
    if (Test-Path $usdScriptsDst) { Remove-Item $usdScriptsDst -Recurse -Force }
    Write-Host "    Copying scripts\ ..." -ForegroundColor Gray
    & robocopy $usdScriptsSrc $usdScriptsDst /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NC /NS /XF *.sh | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed copying scripts\ (exit $LASTEXITCODE)" }
    Write-Item "scripts\ (usdview, usdrecord, ...)"
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
        "/E", "/R:3", "/W:1",
        "/NFL", "/NDL", "/NJH", "/NJS",
        "/XD", "include", "libs", "MaterialX", "Tools", "test", "idlelib", "ensurepip",
        "/XF", "*.pdb", "*.lib"
    )
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed copying python\ (exit $LASTEXITCODE)" }
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
    $rcArgs = @(
        $pipSrc, $pipDst,
        "/E", "/PURGE", "/R:3", "/W:1",
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
    # Exit code 8 means some files could not be copied (locked DLLs still mapped
    # as image sections); those files are the same version and safe to skip.
    if ($LASTEXITCODE -ge 16) { Write-Error "robocopy failed copying pip-packages\ (exit $LASTEXITCODE)" }
    elseif ($LASTEXITCODE -ge 8) { Write-Warning "pip-packages\: some locked files skipped (exit $LASTEXITCODE) - harmless if version unchanged." }
    Write-Item "pip-packages\ (PySide6, PyOpenGL, trimmed)"
}

# Remove the temporary Defender exclusion now that all file copies are complete.
try { Remove-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue } catch { $null = $_ }

# ---------------------------------------------------------------------------
# Write system INI with correct absolute paths.
# The template shipped in OUT_DIR has empty path values so it works for any
# install location. install.ps1 fills them in here for the module-dir INI
# (lowest priority, used when no user/ProgramData INI exists).
# ---------------------------------------------------------------------------
Write-Step "Writing system configuration"

$sysIni = Join-Path $InstallDir "UsdShellExtension.ini"
if (Test-Path $sysIni) {
    $currentSection = ''
    $patched = (Get-Content $sysIni -Encoding UTF8) | ForEach-Object {
        if ($_ -match '^\[(\w+)\]') { $currentSection = $Matches[1] }
        if     ($currentSection -eq 'USD'    -and $_ -match '^PATH\s*=')              { "PATH=$InstallDir;$InstallDir\scripts" }
        elseif ($currentSection -eq 'USD'    -and $_ -match '^PYTHONPATH\s*=')        { "PYTHONPATH=$InstallDir\lib\python" }
        elseif ($currentSection -eq 'USD'    -and $_ -match '^PXR_PLUGINPATH_NAME\s*=') { "PXR_PLUGINPATH_NAME=$InstallDir\usd;$InstallDir\plugin\usd" }
        elseif ($currentSection -eq 'PYTHON' -and $_ -match '^PATH\s*=')              { "PATH=$InstallDir\python\" }
        elseif ($currentSection -eq 'PYTHON' -and $_ -match '^PYTHONPATH\s*=')        { "PYTHONPATH=$InstallDir\pip-packages" }
        else { $_ }
    }
    Set-Content $sysIni $patched -Encoding UTF8
    Write-Item "UsdShellExtension.ini -> $InstallDir"
}

# ---------------------------------------------------------------------------
# Patch user-level INI: overwrite any stale SDK paths from a previous install.
# The user INI (in %LOCALAPPDATA%) has higher priority than the system INI.
# ---------------------------------------------------------------------------
Write-Step "Patching user configuration"

$userIni = "$env:LOCALAPPDATA\UsdShellExtension\UsdShellExtension.ini"
if (Test-Path $userIni) {
    $currentSection = ''
    $patched = (Get-Content $userIni -Encoding UTF8) | ForEach-Object {
        if ($_ -match '^\[(\w+)\]') { $currentSection = $Matches[1] }
        if     ($currentSection -eq 'USD'    -and $_ -match '^PATH\s*=')       { "PATH=$InstallDir;$InstallDir\scripts" }
        elseif ($currentSection -eq 'USD'    -and $_ -match '^PYTHONPATH\s*=') { "PYTHONPATH=$InstallDir\lib\python" }
        elseif ($currentSection -eq 'PYTHON' -and $_ -match '^PATH\s*=')       { "PATH=$InstallDir\python\" }
        elseif ($currentSection -eq 'PYTHON' -and $_ -match '^PYTHONPATH\s*=') { "PYTHONPATH=$InstallDir\pip-packages" }
        else { $_ }
    }
    Set-Content $userIni $patched -Encoding UTF8
    Write-Item "Patched user INI paths -> $InstallDir"
} else {
    Write-Host "    No user INI found at $userIni, skipping." -ForegroundColor Gray
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

# Notify Explorer that file-type associations changed so it flushes its type-name cache.
try { [NativeFileHelper]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero) } catch { $null = $_ }

# Restart Windows Search service now that locked files have been replaced.
Start-Service -Name "WSearch" -ErrorAction SilentlyContinue

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
            Write-Removed ("Cleared MuiCache: {0}" -f $_)
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
Write-Removed ("{0} icon/thumbnail cache file(s) removed" -f ($iconFiles.Count + $thumbFiles.Count))

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
