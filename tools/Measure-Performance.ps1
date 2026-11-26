#Requires -Version 5.1
<#
.SYNOPSIS
    Measure the run time of the Python tools as launched by the COM servers.

.DESCRIPTION
    Rebuilds the environment that SetupPythonEnvironment gives the python.exe
    subprocesses (PATH, PYTHONHOME, PYTHONPATH, PXR_PLUGINPATH_NAME), read
    from the installed UsdShellExtension.ini, then times:

      - fixed costs of a python.exe: bare start, pxr / PySide6 / imaging imports;
      - a full thumbnail (UsdThumbnail.py) on generated scenes;
      - a burst of thumbnails, 3 in parallel like the COM server throttle;
      - the console tools UsdValidate.py and UsdStageStats.py.

    Each case runs several times; min / median / max are reported and saved
    as JSON in build\bench\ to compare before and after an optimization.
    Scripts are taken from the repository, the runtime from the install dir.

.PARAMETER InstallDir
    Installed UsdShellExtension folder. Default: C:\Program Files\UsdShellExtension

.PARAMETER Runs
    Number of runs per case. Default: 5.

.PARAMETER Label
    Name of the result file (build\bench\<Label>.json). Default: baseline.

.EXAMPLE
    PS> .\tools\Measure-Performance.ps1 -Label baseline
#>
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles "UsdShellExtension"),
    [int]$Runs          = 5,
    [string]$Label      = "baseline"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot "UsdShellExtension.Build.psm1") -Force

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Read-IniValue {
    <#
        Read one KEY from a [SECTION] of an INI file, expanding %VARIABLES%.
    #>
    param([string]$Path, [string]$Section, [string]$Key)
    $inSection = $false
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $inSection = ($Matches[1] -eq $Section); continue }
        if ($inSection -and $line -match "^\s*$([regex]::Escape($Key))\s*=(.*)$") {
            return [Environment]::ExpandEnvironmentVariables($Matches[1].Trim())
        }
    }
    return ""
}

function Get-Stat {
    <#
        Return min / median / max (seconds, 2 decimals) of a list of durations.
    #>
    param([double[]]$Seconds)
    $sorted = $Seconds | Sort-Object
    $median = if ($sorted.Count % 2) { $sorted[[int][math]::Floor($sorted.Count / 2)] }
              else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
    [pscustomobject]@{
        Min    = [math]::Round($sorted[0], 2)
        Median = [math]::Round($median, 2)
        Max    = [math]::Round($sorted[-1], 2)
    }
}

function Invoke-Timed {
    <#
        Run python.exe with the given arguments Runs times and return the
        durations. A non-zero exit code stops the measurement: a broken case
        must never be reported as a fast one.
    #>
    param([string]$Name, [string[]]$Arguments)
    $durations = @()
    for ($run = 1; $run -le $Runs; $run++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $output = & $script:pythonExe @Arguments 2>&1
        $watch.Stop()
        if ($LASTEXITCODE -ne 0) {
            throw "$Name failed (exit code $LASTEXITCODE):`n$($output -join "`n")"
        }
        $durations += $watch.Elapsed.TotalSeconds
    }
    return ,$durations
}

function Invoke-ThumbnailBurst {
    <#
        Render Count thumbnails with at most Parallel processes at once
        (same limit as the COM server semaphore) and return the wall time.
    #>
    param([string]$Scene, [int]$Count, [int]$Parallel)
    $pending = 1..$Count
    $running = @()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($index in $pending) {
        # Wait for a free slot before starting the next render.
        while (@($running | Where-Object { -not $_.HasExited }).Count -ge $Parallel) {
            Start-Sleep -Milliseconds 20
        }
        $png = Join-Path $script:outDir ("burst_{0}.png" -f $index)
        $running += Start-Process -FilePath $script:pythonExe -PassThru -WindowStyle Hidden `
            -ArgumentList @("`"$script:thumbnailScript`"", "--imageWidth", "256", "`"$Scene`"", "`"$png`"")
    }
    $running | ForEach-Object { $_.WaitForExit() }
    $watch.Stop()
    $failed = @($running | Where-Object { $_.ExitCode -ne 0 }).Count
    if ($failed) { throw "Thumbnail burst: $failed render(s) failed" }
    return $watch.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Environment of the COM server subprocesses (see SetupPythonEnvironment)
# ---------------------------------------------------------------------------
$ini = Join-Path $InstallDir "UsdShellExtension.ini"
Assert-Path $ini "installed UsdShellExtension.ini"

$usdPath        = Read-IniValue $ini "USD"    "PATH"
$usdPythonPath  = Read-IniValue $ini "USD"    "PYTHONPATH"
$usdPluginPath  = Read-IniValue $ini "USD"    "PXR_PLUGINPATH_NAME"
$pythonHome     = Read-IniValue $ini "PYTHON" "PATH"
$pipPackages    = Read-IniValue $ini "PYTHON" "PYTHONPATH"

$env:PATH                = "$pythonHome;$usdPath;$env:PATH"
$env:PYTHONHOME          = $pythonHome
$env:PYTHONPATH          = "$usdPythonPath;$pipPackages"
$env:PXR_PLUGINPATH_NAME = $usdPluginPath

$script:pythonExe       = Join-Path $pythonHome "python.exe"
$script:thumbnailScript = Join-Path $REPO "UsdPythonToolsServer\UsdThumbnail.py"
$validateScript         = Join-Path $REPO "UsdPythonToolsServer\UsdValidate.py"
$statsScript            = Join-Path $REPO "UsdPythonToolsServer\UsdStageStats.py"
Assert-Path $script:pythonExe "python.exe"

$benchDir      = Join-Path $REPO "build\bench"
$sceneDir      = Join-Path $benchDir "scenes"
$script:outDir = Join-Path $benchDir "out"
New-Item -ItemType Directory -Force $sceneDir, $script:outDir | Out-Null

Write-Step "Benchmark '$Label' ($Runs runs per case)"
Write-Detail "Install" $InstallDir
Write-Detail "Python"  $script:pythonExe

& $script:pythonExe (Join-Path $PSScriptRoot "benchmark_scenes.py") $sceneDir
if ($LASTEXITCODE -ne 0) { throw "Scene generation failed (exit code $LASTEXITCODE)" }
$global:LASTEXITCODE = 0

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
$cases = [ordered]@{
    "python: bare start"          = @("-c", "pass")
    "python: import pxr.Usd"      = @("-c", "from pxr import Usd")
    "python: import PySide6"      = @("-c", "from PySide6 import QtWidgets, QtOpenGL")
    "python: import imaging"      = @("-c", "from pxr import UsdAppUtils, UsdImagingGL")
    "thumbnail: small.usda"       = @($script:thumbnailScript, "--imageWidth", "256", (Join-Path $sceneDir "small.usda"),  (Join-Path $script:outDir "small.png"))
    "thumbnail: lights.usda"      = @($script:thumbnailScript, "--imageWidth", "256", (Join-Path $sceneDir "lights.usda"), (Join-Path $script:outDir "lights.png"))
    "thumbnail: medium.usdc"      = @($script:thumbnailScript, "--imageWidth", "256", (Join-Path $sceneDir "medium.usdc"), (Join-Path $script:outDir "medium.png"))
    "validate: medium.usdc"       = @($validateScript, (Join-Path $sceneDir "medium.usdc"))
    "stage stats: medium.usdc"    = @($statsScript,    (Join-Path $sceneDir "medium.usdc"))
}

$results = [ordered]@{}
foreach ($name in $cases.Keys) {
    Write-Host ("    {0,-28} ..." -f $name) -NoNewline -ForegroundColor Gray
    $stat = Get-Stat (Invoke-Timed $name $cases[$name])
    $results[$name] = $stat
    Write-Host ("`r    {0,-28} min {1,6:N2}s  median {2,6:N2}s  max {3,6:N2}s" -f $name, $stat.Min, $stat.Median, $stat.Max)
}

$burstName = "burst: 6 x small, 3 parallel"
Write-Host ("    {0,-28} ..." -f $burstName) -NoNewline -ForegroundColor Gray
$burstTimes = @()
for ($run = 1; $run -le $Runs; $run++) {
    $burstTimes += Invoke-ThumbnailBurst (Join-Path $sceneDir "small.usda") 6 3
}
$results[$burstName] = Get-Stat $burstTimes
$stat = $results[$burstName]
Write-Host ("`r    {0,-28} min {1,6:N2}s  median {2,6:N2}s  max {3,6:N2}s" -f $burstName, $stat.Min, $stat.Median, $stat.Max)

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------
$report = [ordered]@{
    label   = $Label
    date    = (Get-Date).ToString("s")
    machine = [ordered]@{
        cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        gpu = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name
    }
    runs    = $Runs
    results = $results
}
$reportPath = Join-Path $benchDir "$Label.json"
$report | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8
Write-Item "Saved $reportPath"
