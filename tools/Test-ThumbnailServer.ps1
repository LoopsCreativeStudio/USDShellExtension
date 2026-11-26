#Requires -Version 5.1
<#
.SYNOPSIS
    Integration test of the installed thumbnail COM server under load.

.DESCRIPTION
    Calls IUsdPythonTools::Record through COM, exactly like the shell
    extension does for Explorer, many times in parallel. Checks that:

      - every call returns a valid PNG (signature, non-empty);
      - every call gets its own image file;
      - no per-call script or log is left behind in %TEMP%.

    Needs the build installed (.\install.ps1) and the benchmark scenes
    (.\tools\Measure-Performance.ps1 generates them in build\bench\scenes).

.PARAMETER Count
    Number of thumbnails to request. Default: 12.

.PARAMETER Parallel
    Number of concurrent COM callers. Default: 6 (above the server limit of
    3, so the render throttle is exercised).

.EXAMPLE
    PS> .\tools\Test-ThumbnailServer.ps1
#>
param(
    [int]$Count    = 12,
    [int]$Parallel = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot "UsdShellExtension.Build.psm1") -Force

# CLSID of the UsdPythonTools coclass (UsdPythonToolsLocalServer.idl).
$clsid = [guid]"67F43831-59C3-450E-8956-AA76273F3E9F"

$sceneDir = Join-Path $REPO "build\bench\scenes"
$scenes = @("small.usda", "lights.usda", "medium.usdc") | ForEach-Object { Join-Path $sceneDir $_ }
$scenes | ForEach-Object { Assert-Path $_ "benchmark scene (run tools\Measure-Performance.ps1 once)" }

Write-Step "Thumbnail server: $Count renders, $Parallel concurrent callers"

# Per-call files created during the test must all be gone at the end.
$tempDir  = [IO.Path]::GetTempPath()
$started  = Get-Date

# One COM call per job: create the server object, render, inspect the PNG.
$renderJob = {
    param($Clsid, $Scene)
    $tools = [Activator]::CreateInstance([Type]::GetTypeFromCLSID($Clsid))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $png = $tools.Record($Scene, 256, "")
        $error_ = $null
    } catch {
        $png = $null
        $error_ = $_.Exception.Message
    }
    $watch.Stop()

    # A PNG starts with 0x89 'P' 'N' 'G'.
    $valid = $false
    if ($png -and (Test-Path $png)) {
        $bytes = [IO.File]::ReadAllBytes($png)
        $valid = ($bytes.Length -gt 8) -and ($bytes[0] -eq 0x89) -and ($bytes[1] -eq 0x50) -and
                 ($bytes[2] -eq 0x4E) -and ($bytes[3] -eq 0x47)
    }
    [pscustomobject]@{ Scene = (Split-Path $Scene -Leaf); Png = $png; Valid = $valid
                       Seconds = $watch.Elapsed.TotalSeconds; Error = $error_ }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $Parallel)
$pool.Open()
$watchAll = [Diagnostics.Stopwatch]::StartNew()
$jobs = for ($index = 0; $index -lt $Count; $index++) {
    $shell = [PowerShell]::Create()
    $shell.RunspacePool = $pool
    [void]$shell.AddScript($renderJob).AddArgument($clsid).AddArgument($scenes[$index % $scenes.Count])
    [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
}
$results = foreach ($job in $jobs) {
    $job.Shell.EndInvoke($job.Handle)
    $job.Shell.Dispose()
}
$watchAll.Stop()
$pool.Close()

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
$failures = @()

foreach ($result in $results) {
    $status = if ($result.Valid) { "ok" } else { "FAILED $($result.Error)" }
    Write-Host ("    {0,-12} {1,5:N2}s  {2}" -f $result.Scene, $result.Seconds, $status)
    if (-not $result.Valid) { $failures += "$($result.Scene): $($result.Error)" }
}

$distinct = @($results | Where-Object { $_.Png } | Select-Object -ExpandProperty Png -Unique).Count
if ($distinct -ne $Count) { $failures += "only $distinct distinct images for $Count calls" }

$leftovers = @(Get-ChildItem $tempDir -File -Filter "UsdThumbnail_*" -ErrorAction SilentlyContinue |
               Where-Object { $_.CreationTime -ge $started })
if ($leftovers.Count) { $failures += "leftover temp files: $($leftovers.Name -join ', ')" }

# The images belong to the caller (the shell extension deletes them).
$results | Where-Object { $_.Png -and (Test-Path $_.Png) } | ForEach-Object { Remove-Item $_.Png -Force }

Write-Detail "Wall time" ("{0:N2}s" -f $watchAll.Elapsed.TotalSeconds)
if ($failures) {
    $failures | ForEach-Object { Write-Host "    ! $_" -ForegroundColor Red }
    throw "Thumbnail server test failed ($($failures.Count) problem(s))"
}
Write-Item "All $Count thumbnails valid, distinct, no temp leftovers"
