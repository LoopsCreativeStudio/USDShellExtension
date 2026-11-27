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
        Run a command line as SYSTEM and return its exit code and duration.
        The command line goes through a .cmd file so that its exact text
        (quotes, spaces after _?=) reaches the program unchanged.
    #>
    param([string]$CommandLine)
    $commandFile = Join-Path $systemTemp "UsdShellExtension-deploy-test.cmd"
    Set-Content -LiteralPath $commandFile -Encoding ascii -Value @(
        "@echo off"
        $CommandLine
        "exit /b %ERRORLEVEL%"
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    # PsExec writes its progress to stderr. Windows PowerShell 5.1 turns each
    # stderr line into an error record, which "Stop" would make terminating
    # (and kill PsExec): use Continue for this call only (function scope).
    $ErrorActionPreference = "Continue"
    & psexec -accepteula -nobanner -s cmd /c $commandFile 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    $stopwatch.Stop()
    Remove-Item -LiteralPath $commandFile -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ ExitCode = $exitCode; Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) }
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
    $setupLog = Join-Path $systemTemp "UsdShellExtension_setup.log"
    Assert-Result (Test-Path $setupLog) "setup log in $systemTemp"
    if (Test-Path $setupLog) {
        Get-Content -LiteralPath $setupLog | Select-Object -Last 4 | ForEach-Object { Write-Result "    log | $_" DarkGray }
    }
}

# ---------------------------------------------------------------------------
# Setup .exe to test
# ---------------------------------------------------------------------------
if (-not $SetupPath) {
    $SetupPath = Get-ChildItem (Join-Path $repositoryRoot "bin\v145\3.12\Release") -Filter "*-setup.exe" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SetupPath -or -not (Test-Path $SetupPath)) { throw "Setup .exe not found. Run .\build.ps1 -Installer first." }
if (-not (Get-Command psexec -ErrorAction SilentlyContinue)) { throw "PsExec not found in PATH." }
$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) { throw "Run this script in an elevated PowerShell." }
Write-Result "Setup: $SetupPath"

# Start without old SYSTEM logs, so a log found later comes from this run.
Remove-Item -LiteralPath (Join-Path $systemTemp "UsdShellExtension_setup.log"),
    (Join-Path $systemTemp "UsdShellExtension_uninstall.log") -Force -ErrorAction SilentlyContinue

$previousEntry = Get-UninstallEntry
Write-Result ("Before: Uninstall key {0}" -f $(if ($previousEntry) { "present, version $($previousEntry.DisplayVersion)" } else { "absent" }))

# ---------------------------------------------------------------------------
# 1. Silent install over the current installation
# ---------------------------------------------------------------------------
Write-Result "`n[1] Silent install as SYSTEM over the current installation" Cyan
$installRun = Invoke-AsSystem "`"$SetupPath`" /S"
Test-InstalledState $installRun
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
    $uninstallRun = Invoke-AsSystem $quietProperty.Value
    Write-Result ("    exit code {0}, {1} s" -f $uninstallRun.ExitCode, $uninstallRun.Seconds)
    Assert-Result ($uninstallRun.ExitCode -in 0, 3010) "exit code 0 or 3010"
    # Checked right after the command returned: a non-waiting uninstaller
    # would still be running here.
    Assert-Result (-not (Test-Path $uninstallKey)) "Uninstall key removed when the command returns"
    Assert-Result (-not (Test-Path (Join-Path $InstallDir "UsdShellExtension.dll"))) "UsdShellExtension.dll removed when the command returns"
} else {
    Assert-Result $false "QuietUninstallString available for the uninstall step"
}

# ---------------------------------------------------------------------------
# 3. Silent install with no previous Uninstall key
# ---------------------------------------------------------------------------
Write-Result "`n[3] Silent install as SYSTEM with no previous Uninstall key" Cyan
$reinstallRun = Invoke-AsSystem "`"$SetupPath`" /S"
Test-InstalledState $reinstallRun

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($failures.Count -eq 0) {
    Write-Result "`nAll checks passed." Green
} else {
    Write-Result ("`n{0} check(s) failed:`n  {1}" -f $failures.Count, ($failures -join "`n  ")) Red
}
Write-Result "Results: $resultFile"
