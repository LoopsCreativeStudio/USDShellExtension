#Requires -Version 5.1
<#
.SYNOPSIS
    Check the setup .exe in unattended deployment conditions (SYSTEM, /S).

.DESCRIPTION
    Runs the setup .exe and the uninstaller as SYSTEM through PsExec, as a
    deployment tool would (Intune, SCCM, GPO startup script, Chocolatey), and
    checks after each step:

      1. Silent install over the current installation (/S): exit code, log,
         Uninstall registry values (InstallLocation, QuietUninstallString).
      2. Silent uninstall with the QuietUninstallString command: it must only
         return once the uninstall is done (_?= keeps it in place), so the
         install folder and the Uninstall key are already gone.
      3. Silent install again, with no previous Uninstall key: the previous
         uninstall step is skipped without failing.

    The extension ends installed. Explorer is stopped and restarted at each
    step when a user is logged in. Results are written to the console and to
    build\bench\deploy\result.txt.

    Run from the repository root, in an elevated PowerShell (PsExec -s needs
    administrator rights). Requires PsExec (Sysinternals) in PATH.

.PARAMETER SetupPath
    Setup .exe to test. Defaults to the newest *-setup.exe of the Release
    build output.

.PARAMETER InstallDir
    Default install folder of the setup .exe.

.EXAMPLE
    .\tools\Test-SilentDeployment.ps1
#>
[CmdletBinding()]
param(
    [string]$SetupPath,
    [string]$InstallDir = "C:\Program Files\UsdShellExtension"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$resultDir = Join-Path $repositoryRoot "build\bench\deploy"
New-Item -ItemType Directory -Force $resultDir | Out-Null
$resultFile = Join-Path $resultDir "result.txt"
Set-Content -LiteralPath $resultFile -Value "Silent deployment test - $(Get-Date -Format s)"

$uninstallKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\UsdShellExtension"
# Logs written by the installer and the uninstaller under SYSTEM (%TEMP%).
$systemTemp = Join-Path $env:SystemRoot "Temp"
$failures = [System.Collections.Generic.List[string]]::new()

function Write-Result {
    <#
        Print a result line and append it to the result file.
    #>
    param([string]$Text, [string]$Color = "Gray")
    Write-Host $Text -ForegroundColor $Color
    Add-Content -LiteralPath $resultFile -Value $Text
}

function Assert-Result {
    <#
        Record a check: green when true, red and counted as a failure otherwise.
    #>
    param([bool]$Condition, [string]$Label)
    if ($Condition) { Write-Result "    + $Label" Green }
    else { Write-Result "    - FAILED: $Label" Red; $failures.Add($Label) }
}

function Get-UninstallEntry {
    <#
        Return the Uninstall registry values, or $null without a key.
    #>
    if (-not (Test-Path $uninstallKey)) { return $null }
    Get-ItemProperty $uninstallKey
}

function Invoke-AsSystem {
    <#
        Run a command line as SYSTEM and return its exit code and duration,
        showing the elapsed seconds while it runs (a silent install shows
        nothing for up to two minutes). The command line goes through a .cmd
        file so that its exact text (quotes, spaces after _?=) reaches the
        program unchanged.
    #>
    param([string]$CommandLine)
    $commandFile = Join-Path $systemTemp "UsdShellExtension-deploy-test.cmd"
    Set-Content -LiteralPath $commandFile -Encoding ascii -Value @(
        "@echo off"
        $CommandLine
        "exit /b %ERRORLEVEL%"
    )

    # PsExec started directly (no PowerShell stderr handling to trip on), its
    # console output discarded; the exit code is the one of the command.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command psexec).Source
    $startInfo.Arguments = "-accepteula -nobanner -s cmd /c `"$commandFile`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Elapsed time on one line, refreshed every second.
    while (-not $process.WaitForExit(1000)) {
        Write-Host ("`r    running as SYSTEM... {0,4} s" -f [int]$stopwatch.Elapsed.TotalSeconds) -NoNewline -ForegroundColor DarkGray
    }
    $process.WaitForExit()
    $stopwatch.Stop()
    Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline
    Remove-Item -LiteralPath $commandFile -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ ExitCode = $process.ExitCode; Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) }
}

function Get-UserSessionWithExplorer {
    <#
        Return the session ids (> 0, i.e. user sessions) where Explorer runs.
    #>
    @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
        Where-Object { $_.SessionId -gt 0 } | ForEach-Object { $_.SessionId } | Sort-Object -Unique)
}

function Test-ExplorerBack {
    <#
        After a step, check that Explorer runs again in every user session
        where it ran before (Windows restarts it when AutoRestartShell is 1).
        Waits up to 30 s.
    #>
    param([int[]]$SessionsBefore)
    # An empty list arrives as $null (StrictMode: no .Count on $null).
    $SessionsBefore = @($SessionsBefore | Where-Object { $null -ne $_ })
    if ($SessionsBefore.Count -eq 0) {
        Write-Result "    (no user session with Explorer: nothing to check)" DarkGray
        return
    }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $missingSessions = @($SessionsBefore | Where-Object { $_ -notin (Get-UserSessionWithExplorer) })
        if ($missingSessions.Count -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    Assert-Result ($missingSessions.Count -eq 0) ("Explorer running again in session(s) {0}" -f ($SessionsBefore -join ', '))
}

function Get-PendingDeleteCount {
    <#
        Number of reboot-time deletions scheduled in the install folder
        (PendingFileRenameOperations), counted with the installer's own
        filter (Clear-PendingDelete.ps1).
    #>
    $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if (-not $sessionManager) { return 0 }
    $operations = @($sessionManager.PendingFileRenameOperations)
    $remainingOperations = @(Get-PendingOperationWithoutDelete $operations $InstallDir)
    ($operations.Count - $remainingOperations.Count) / 2
}

function Test-InstalledState {
    <#
        Check the state after a silent install.
    #>
    param($Run)
    Write-Result ("    exit code {0}, {1} s" -f $Run.ExitCode, $Run.Seconds)
    Assert-Result ($Run.ExitCode -in 0, 3010) "exit code 0 or 3010"
    $entry = Get-UninstallEntry
    Assert-Result ($null -ne $entry) "Uninstall key present"
    if ($entry) {
        Write-Result "    DisplayVersion       : $($entry.DisplayVersion)"
        Write-Result "    InstallLocation      : $($entry.InstallLocation)"
        $quiet = $entry.PSObject.Properties['QuietUninstallString']
        Write-Result "    QuietUninstallString : $(if ($quiet) { $quiet.Value })"
        $expectedQuiet = "`"$InstallDir\uninstall.exe`" /S _?=$InstallDir"
        Assert-Result ($quiet -and $quiet.Value -eq $expectedQuiet) "QuietUninstallString built from the install folder"
    }
    Assert-Result (Test-Path (Join-Path $InstallDir "UsdPreviewLocalServer.exe")) "UsdPreviewLocalServer.exe at the install folder root"
    Assert-Result (Test-Path (Join-Path $InstallDir "licenses\LGPL-3.0.txt")) "licenses folder installed"
    $pendingDeleteCount = Get-PendingDeleteCount
    Assert-Result ($pendingDeleteCount -eq 0) ("no reboot-time deletion left in the install folder ({0})" -f $pendingDeleteCount)
    # The files of the build output must be the installed ones: a file still
    # in use that setup could not overwrite would stay at its old version.
    $buildOutput = Split-Path $SetupPath -Parent
    # Top-level files only: "-Include" with "-Recurse -Depth 0" still walks
    # sub folders in Windows PowerShell 5.1 (pip-packages has other DLLs
    # with the same names, e.g. vcruntime140.dll from PySide6).
    $staleFiles = @(Get-ChildItem -Path (Join-Path $buildOutput '*') -File -Include *.dll, *.exe, *.pyd |
        Where-Object { $_.Name -notlike '*-setup.exe' } |
        Where-Object {
            $installedFile = Join-Path $InstallDir $_.Name
            (Test-Path $installedFile) -and
                ((Get-FileHash $installedFile).Hash -ne (Get-FileHash $_.FullName).Hash)
        } | ForEach-Object { $_.Name })
    Assert-Result ($staleFiles.Count -eq 0) ("installed binaries identical to the build output{0}" -f
        $(if ($staleFiles.Count) { ": differ " + ($staleFiles -join ', ') } else { "" }))

    $setupLog = Join-Path $systemTemp "UsdShellExtension_setup.log"
    Assert-Result (Test-Path $setupLog) "setup log in $systemTemp"
    if (Test-Path $setupLog) { Show-LogTail $setupLog }
}

function Show-LogTail {
    <#
        Print the first bytes (to check the encoding) and the last lines of
        an installer log, decoded as UTF-16 when it starts with its BOM.
    #>
    param([string]$LogPath)
    $logBytes = [IO.File]::ReadAllBytes($LogPath)
    $firstBytes = ($logBytes | Select-Object -First 8 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    Write-Result "    log first bytes: $firstBytes" DarkGray
    $logText = if ($logBytes.Length -ge 2 -and $logBytes[0] -eq 0xFF -and $logBytes[1] -eq 0xFE) {
        [Text.Encoding]::Unicode.GetString($logBytes, 2, $logBytes.Length - 2)
    } else {
        [Text.Encoding]::Default.GetString($logBytes)
    }
    $logText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5 |
        ForEach-Object { Write-Result "    log | $_" DarkGray }
}

# ---------------------------------------------------------------------------
# Setup .exe to test
# ---------------------------------------------------------------------------
if (-not $SetupPath) {
    # Build outputs are named after the Python version (bin\v145\<3.x>\Release).
    $SetupPath = Get-ChildItem -Path (Join-Path $repositoryRoot "bin\v145\*\Release\*-setup.exe") |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SetupPath -or -not (Test-Path $SetupPath)) { throw "Setup .exe not found. Run .\build.ps1 -Installer first." }
if (-not (Get-Command psexec -ErrorAction SilentlyContinue)) { throw "PsExec not found in PATH." }
$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) { throw "Run this script in an elevated PowerShell." }
Write-Result "Setup: $SetupPath"

# Filter of the reboot-time deletions, shared with the installer. Only its
# functions are loaded (from the AST): dot-sourcing the whole script would
# bind its -InstallDir parameter over this script's $InstallDir.
$pendingDeleteScript = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repositoryRoot "UsdShellExtensionInstaller\Clear-PendingDelete.ps1"), [ref]$null, [ref]$null)
foreach ($scriptFunction in $pendingDeleteScript.FindAll({
        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($scriptFunction.Extent.Text))
}

# Windows restarts a stopped Explorer only when AutoRestartShell is 1.
$autoRestartShell = Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoRestartShell" -ErrorAction SilentlyContinue
Assert-Result ($autoRestartShell -eq 1) "Winlogon AutoRestartShell is 1 ($autoRestartShell)"

# Start without old SYSTEM logs, so a log found later comes from this run.
Remove-Item -LiteralPath (Join-Path $systemTemp "UsdShellExtension_setup.log"),
    (Join-Path $systemTemp "UsdShellExtension_uninstall.log") -Force -ErrorAction SilentlyContinue

$previousEntry = Get-UninstallEntry
Write-Result ("Before: Uninstall key {0}" -f $(if ($previousEntry) { "present, version $($previousEntry.DisplayVersion)" } else { "absent" }))

# ---------------------------------------------------------------------------
# 1. Silent install over the current installation
# ---------------------------------------------------------------------------
Write-Result "`n[1] Silent install as SYSTEM over the current installation" Cyan
$explorerSessions = Get-UserSessionWithExplorer
$installRun = Invoke-AsSystem "`"$SetupPath`" /S"
Test-InstalledState $installRun
Test-ExplorerBack $explorerSessions
$previousUninstallLog = Join-Path $systemTemp "UsdShellExtension_uninstall.log"
if ($previousEntry) {
    Assert-Result (Test-Path $previousUninstallLog) "previous version uninstalled by its own uninstaller (uninstall log present)"
}

# ---------------------------------------------------------------------------
# 2. Silent uninstall with QuietUninstallString: must wait for the end
# ---------------------------------------------------------------------------
Write-Result "`n[2] Silent uninstall as SYSTEM with QuietUninstallString" Cyan
$entry = Get-UninstallEntry
$quietProperty = if ($entry) { $entry.PSObject.Properties['QuietUninstallString'] }
if ($quietProperty) {
    $explorerSessions = Get-UserSessionWithExplorer
    $uninstallRun = Invoke-AsSystem $quietProperty.Value
    Write-Result ("    exit code {0}, {1} s" -f $uninstallRun.ExitCode, $uninstallRun.Seconds)
    Assert-Result ($uninstallRun.ExitCode -in 0, 3010) "exit code 0 or 3010"
    # Checked right after the command returned: a non-waiting uninstaller
    # would still be running here.
    Assert-Result (-not (Test-Path $uninstallKey)) "Uninstall key removed when the command returns"
    # A DLL still loaded by the user's Explorer (left running when setup runs
    # as SYSTEM) cannot be deleted now: it must then be scheduled for
    # deletion at reboot, with exit code 3010. The reinstall below must
    # cancel those deletions.
    $pendingAfterUninstall = Get-PendingDeleteCount
    Write-Result ("    reboot-time deletions scheduled in the install folder: {0}" -f $pendingAfterUninstall)
    $dllLeft = Test-Path (Join-Path $InstallDir "UsdShellExtension.dll")
    Assert-Result ((-not $dllLeft) -or ($pendingAfterUninstall -gt 0 -and $uninstallRun.ExitCode -eq 3010)) `
        "UsdShellExtension.dll removed, or scheduled for deletion at reboot with exit code 3010"
    Test-ExplorerBack $explorerSessions
} else {
    Assert-Result $false "QuietUninstallString available for the uninstall step"
}

# ---------------------------------------------------------------------------
# 3. Silent install with no previous Uninstall key
# ---------------------------------------------------------------------------
Write-Result "`n[3] Silent install as SYSTEM with no previous Uninstall key" Cyan
$explorerSessions = Get-UserSessionWithExplorer
$reinstallRun = Invoke-AsSystem "`"$SetupPath`" /S"
Test-InstalledState $reinstallRun
Test-ExplorerBack $explorerSessions

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($failures.Count -eq 0) {
    Write-Result "`nAll checks passed." Green
} else {
    Write-Result ("`n{0} check(s) failed:`n  {1}" -f $failures.Count, ($failures -join "`n  ")) Red
}
Write-Result "Results: $resultFile"
