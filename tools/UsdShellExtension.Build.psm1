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
# Redistribution check
# ---------------------------------------------------------------------------
function Find-NonRedistributableFile {
    <#
        Return the files under Path that must not be shipped:
          - files carrying the NVIDIA proprietary license tag
            (SPDX "LicenseRef-NvidiaProprietary": distribution prohibited
            without an agreement), e.g. the SDK scripts\*.bat wrappers;
          - NVIDIA packman metadata (.packman*).
        NVIDIA files released under the OpenUSD license are not reported.
        Binary files are scanned too.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)

    $packman = $files | Where-Object { $_.Name -like '.packman*' }

    # -List stops at the first match in each file; ASCII reads binaries too.
    $proprietary = $files |
        Select-String -SimpleMatch -List -Encoding ascii -Pattern 'LicenseRef-NvidiaProprietary' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Item -LiteralPath $_.Path }

    @($packman) + @($proprietary) | Where-Object { $_ } |
        Sort-Object FullName -Unique |
        ForEach-Object { $_.FullName }
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

# ---------------------------------------------------------------------------
# Third-party license texts
# ---------------------------------------------------------------------------
function Copy-ThirdPartyLicense {
    <#
        Mirror the SDK PACKAGE-LICENSES folder to Destination, so the license
        text of every bundled component (OpenUSD, TBB, OpenEXR, ...) ships with
        it. Licenses of components that are not shipped are left out:
        repo_nv-LICENSE.txt covers the NVIDIA repo tooling (scripts\, packman),
        which is proprietary and excluded from the payload. The mirror also
        removes texts that a newer SDK no longer provides.
        AdditionalSource adds the texts kept in the repository for bundled
        components the SDK does not cover (LGPL / GPL v3 for PySide6 and Qt);
        they are copied after the mirror so it does not remove them.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$AdditionalSource
    )

    $notShippedLicenses = @('repo_nv-LICENSE.txt')
    Invoke-Robocopy $Source $Destination '/MIR' '/R:3' '/W:1' '/XF' @notShippedLicenses

    if ($AdditionalSource) {
        Invoke-Robocopy $AdditionalSource $Destination '/R:3' '/W:1'
    }
}

# ---------------------------------------------------------------------------
# Release checksum
# ---------------------------------------------------------------------------
function Write-Sha256File {
    <#
        Write "<Path>.sha256" next to a release file, in the sha256sum format
        (lower-case hash, two spaces, file name), and return its path and the
        hash. Published with the installer so anyone can check the download
        (Get-FileHash, sha256sum -c, Chocolatey -Checksum64) while the setup
        is not code-signed. An existing checksum file is replaced.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $fileHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumPath = "$Path.sha256"
    $checksumLine = "{0}  {1}`n" -f $fileHash, (Split-Path $Path -Leaf)
    # ASCII, LF line ending: readable by sha256sum on any platform.
    [System.IO.File]::WriteAllText($checksumPath, $checksumLine, [System.Text.Encoding]::ASCII)

    [pscustomobject]@{ Path = $checksumPath; Hash = $fileHash }
}

# ---------------------------------------------------------------------------
# OpenUSD source build (build-openusd.ps1)
# ---------------------------------------------------------------------------
function Get-OpenUsdLayout {
    <#
        Return the folders used to build OpenUSD under one root folder.
        Sources are shared per OpenUSD version and the Python runtime per
        Python version. Dependencies, build files and the install folder also
        carry the Python minor version (e.g. "v26.11.1-py312"), because the
        Python bindings only load in the Python they were built against.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OpenUsdVersion,
        [Parameter(Mandatory)][string]$PythonVersion
    )

    # "3.12.10" gives "py312".
    $pythonParts = $PythonVersion.Split('.')
    $buildName   = "{0}-py{1}{2}" -f $OpenUsdVersion, $pythonParts[0], $pythonParts[1]

    $installDir = Join-Path $Root "install\$buildName"

    [pscustomobject]@{
        Root         = $Root
        Downloads    = Join-Path $Root "downloads"
        Python       = Join-Path $Root "python\$PythonVersion"
        Source       = Join-Path $Root "src\$OpenUsdVersion"
        Dependencies = Join-Path $Root "deps\$buildName"
        Build        = Join-Path $Root "build\$buildName"
        Install      = $installDir
        # Folders that make the install folder a drop-in replacement for the
        # NVIDIA package (USD_SDK in .env): build.ps1 reads them there.
        SdkPython    = Join-Path $installDir "python"
        PipPackages  = Join-Path $installDir "pip-packages"
        Licenses     = Join-Path $installDir "PACKAGE-LICENSES"
    }
}

function Get-LicenseComponentName {
    <#
        Return the component name used to prefix its license files: the
        folder name without its version suffix, in lower case
        ("OpenImageIO-3.1.8.0" gives "openimageio", "libtiff-v4.7.1" gives
        "libtiff", "OpenSubdiv-3_6_1" gives "opensubdiv").
    #>
    param([Parameter(Mandatory)][string]$FolderName)

    $nameWithoutVersion = $FolderName -replace '-v?\d[\d._]*$', ''
    return $nameWithoutVersion.ToLowerInvariant()
}

function Copy-OpenUsdLicense {
    <#
        Collect the license texts of everything the OpenUSD build ships into
        Layout.Licenses, replacing its previous content. Each file is renamed
        "<component>-<file name>" (e.g. "openexr-LICENSE.md"), the layout of
        the NVIDIA PACKAGE-LICENSES folder that build.ps1 mirrors:
          - OpenUSD: LICENSE.txt and NOTICE.txt of the sources;
          - each dependency folder build_usd.py extracted (TBB, OpenEXR, ...);
          - libraries a dependency fetches itself during its own build:
            CMake FetchContent ("<build>\*\_deps\<name>-src", e.g. Imath) and
            OpenColorIO external projects ("<build>\*\ext\build\*\src\<name>_install");
          - the Python runtime.
    #>
    param([Parameter(Mandatory)][pscustomobject]$Layout)

    # License, copying, notice and third-party files, top level only.
    $licenseFilePattern = '^(LICEN[CS]E|COPYING|NOTICE|THIRD-PARTY)'

    function Copy-LicenseFileFrom([string]$folder, [string]$componentName) {
        Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $licenseFilePattern } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Layout.Licenses ("{0}-{1}" -f $componentName, $_.Name))
            }
    }

    if (Test-Path $Layout.Licenses) { Remove-Item $Layout.Licenses -Recurse -Force }
    New-Item -ItemType Directory -Force $Layout.Licenses | Out-Null

    Copy-LicenseFileFrom $Layout.Source "openusd"

    foreach ($dependencyFolder in Get-ChildItem -LiteralPath $Layout.Dependencies -Directory -ErrorAction SilentlyContinue) {
        Copy-LicenseFileFrom $dependencyFolder.FullName (Get-LicenseComponentName $dependencyFolder.Name)
    }

    foreach ($fetchedFolder in Get-ChildItem -Path (Join-Path $Layout.Build "*\_deps\*-src") -Directory -ErrorAction SilentlyContinue) {
        Copy-LicenseFileFrom $fetchedFolder.FullName ($fetchedFolder.Name -replace '-src$', '')
    }
    foreach ($externalFolder in Get-ChildItem -Path (Join-Path $Layout.Build "*\ext\build\*\src\*_install") -Directory -ErrorAction SilentlyContinue) {
        Copy-LicenseFileFrom $externalFolder.FullName ($externalFolder.Name -replace '_install$', '')
    }

    Copy-LicenseFileFrom $Layout.Python "python"
}

function Get-OpenUsdBuildArgument {
    <#
        Return the arguments for "python build_usd.py": a release build with
        the features the extension uses (Storm imaging with OpenSubdiv,
        usdview, Python bindings, MaterialX, OpenImageIO with OpenEXR,
        OpenColorIO, Ptex, Alembic), without Embree, tests, examples,
        tutorials or documentation. OpenSubdiv and OpenEXR have no option of
        their own: build_usd.py adds them with imaging and OpenImageIO.
    #>
    param([Parameter(Mandatory)][pscustomobject]$Layout)

    @(
        (Join-Path $Layout.Source "build_scripts\build_usd.py"),
        $Layout.Install,
        '--src',           $Layout.Dependencies,
        '--build',         $Layout.Build,
        '--build-variant', 'release',
        '--onetbb',
        '--python',
        # "--imaging" builds Hydra only; usdview needs usdImaging as well.
        '--usd-imaging',
        '--usdview',
        '--materialx',
        '--openimageio',
        '--opencolorio',
        '--ptex',
        '--alembic',
        '--no-embree',
        '--no-tests',
        '--no-examples',
        '--no-tutorials',
        '--no-docs',
        '--no-python-docs'
    )
}

function Get-PathWithoutEntry {
    <#
        Return a PATH string without the entries that match one of the
        regular expressions (case-insensitive) and without empty entries.
        The order of the remaining entries is kept.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string[]]$Pattern
    )

    $keptEntries = foreach ($entry in $Path.Split(';')) {
        if (-not $entry) { continue }
        $isExcluded = $false
        foreach ($excludedPattern in $Pattern) {
            if ($entry -match $excludedPattern) { $isExcluded = $true; break }
        }
        if (-not $isExcluded) { $entry }
    }
    return ($keptEntries -join ';')
}

# ---------------------------------------------------------------------------
# Python version of the projects
# ---------------------------------------------------------------------------
function Get-ProjectPythonVersion {
    <#
        Read <PythonVersion> (e.g. "3.14") from python.props, the single
        source of the Python version for MSBuild: the output folder
        (bin\v145\<version>\<Config>) and the bundled DLL name
        (python314.dll) both follow it.
    #>
    param([Parameter(Mandatory)][string]$PropsPath)

    [xml]$propertySheet = Get-Content -LiteralPath $PropsPath -Raw
    $namespace = @{ msb = 'http://schemas.microsoft.com/developer/msbuild/2003' }
    $versionNode = Select-Xml -Xml $propertySheet -XPath '//msb:PythonVersion' -Namespace $namespace | Select-Object -First 1
    if (-not $versionNode) { throw "No <PythonVersion> found in $PropsPath" }

    $version = $versionNode.Node.InnerText.Trim()
    [pscustomobject]@{
        Version = $version
        DllName = "python{0}.dll" -f ($version -replace '\.', '')
    }
}

Export-ModuleMember -Function @(
    'Read-DotEnv', 'Assert-Path',
    'Write-Step', 'Write-Detail', 'Write-Item', 'Write-Removed',
    'Copy-WithRetry', 'Invoke-Robocopy', 'Find-NonRedistributableFile',
    'Copy-ThirdPartyLicense', 'Write-Sha256File',
    'Get-OpenUsdLayout', 'Get-OpenUsdBuildArgument', 'Get-PathWithoutEntry',
    'Get-LicenseComponentName', 'Copy-OpenUsdLicense', 'Get-ProjectPythonVersion'
)
