#Requires -Version 5.1
<#
.SYNOPSIS
    Helpers shared by build.ps1 and install.ps1.

.DESCRIPTION
    Provides .env parsing, path assertions, the console output format used by
    the build and install scripts, and Copy-WithRetry, which replaces files
    even when they are loaded by Explorer (locked DLL / EXE).

    uninstaller.ps1 and usd-shell.ps1 deliberately do not import this module:
    they must run alone from the install directory.

.EXAMPLE
    PS> Import-Module (Join-Path $PSScriptRoot "tools\UsdShellExtension.Build.psm1") -Force
#>

# A module does not inherit the caller's preferences: set them here so every
# helper fails fast, as the calling scripts expect.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Native helper: POSIX rename used to replace image-section-mapped files.
# Add-Type registers the type for the whole session, so the calling script
# can also use [NativeFileHelper]::SHChangeNotify.
# ---------------------------------------------------------------------------
if (-not ('NativeFileHelper' -as [type])) {
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
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
function Read-DotEnv {
    <#
        Parse a .env file into a hashtable of KEY = VALUE.
        Blank lines, comments (#) and lines without a key are ignored; the
        value is everything after the first '='; a missing file gives an
        empty table.
    #>
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
    <#
        Stop the calling script when a required path does not exist.
        Uses throw so the failure is terminating whatever the caller's
        ErrorActionPreference.
    #>
    param([string]$path, [string]$label)
    if (-not (Test-Path $path)) { throw "Cannot find $label at: $path" }
}

# ---------------------------------------------------------------------------
# Console output (shared format of the build and install scripts)
# ---------------------------------------------------------------------------
function Write-Step {
    <#
        Print a step header preceded by an empty line.
    #>
    param([string]$msg)
    Write-Host ""
    Write-Host ("  >> {0}" -f $msg) -ForegroundColor Cyan
}

function Write-Detail {
    <#
        Print a "key : value" line with the key padded to 14 characters.
    #>
    param([string]$key, [string]$value)
    Write-Host ("    {0,-14} {1}" -f ($key + " :"), $value) -ForegroundColor Gray
}

function Write-Item {
    <#
        Print an added or copied item.
    #>
    param([string]$msg)
    Write-Host ("    + {0}" -f $msg) -ForegroundColor DarkGreen
}

function Write-Removed {
    <#
        Print a removed item.
    #>
    param([string]$msg)
    Write-Host ("    - {0}" -f $msg) -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Folder copy with robocopy
# ---------------------------------------------------------------------------
function Invoke-Robocopy {
    <#
        Run robocopy quietly and check its exit code.
        Robocopy codes 0-7 mean success (bit flags: copied, extra, mismatch);
        8 and above mean at least one failure. On success LASTEXITCODE is
        reset to 0 so a "files copied" code 1 never leaks to the caller's
        exit code. On failure, throw with robocopy's output.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(ValueFromRemainingArguments)][string[]]$Options
    )

    # Quiet flags: no file/dir lists, no header/summary, no class/size columns.
    $quietFlags = @('/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS')
    $robocopyArgs = @($Source, $Destination) + $quietFlags + @($Options | Where-Object { $_ })

    $output = & robocopy @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        throw ("robocopy failed (exit code {0}) copying {1} to {2}:`n{3}" -f
            $exitCode, $Source, $Destination, ($output -join "`n"))
    }
    $global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------------------
# File copy resilient to locks
# ---------------------------------------------------------------------------
function Copy-WithRetry {
    <#
        Copy Source to Dest, replacing Dest even when it is locked.
        Strategies in order: direct overwrite, rename the old file aside,
        POSIX rename of a temp copy (mapped DLL / EXE), timed retries.
    #>
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

Export-ModuleMember -Function @(
    'Read-DotEnv', 'Assert-Path',
    'Write-Step', 'Write-Detail', 'Write-Item', 'Write-Removed',
    'Copy-WithRetry', 'Invoke-Robocopy'
)
