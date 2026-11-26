#Requires -Version 5.1
<#
.SYNOPSIS
    Set up the USD environment for running USD command-line tools.

.DESCRIPTION
    Dot-source this script to configure PATH, PYTHONHOME and PYTHONPATH
    in the current PowerShell session:

        . .\usd-shell.ps1

    After sourcing, the full USD toolset is available directly:

        usdchecker        scene.usd
        usdview           scene.usd
        usdcat            scene.usd
        usdfixbrokenpixarschemas scene.usd
        usdrecord         --imageWidth 512 scene.usd thumb.png
        usdzip  / usdunzip
        usdgenschemafromsdr
        sdfdump

    When run directly (not dot-sourced), the script opens a new
    PowerShell window with the USD environment already active.
#>

# ---------------------------------------------------------------------------
# Locate UsdShellExtension.ini
# ---------------------------------------------------------------------------
$_candidates = @(
    (Join-Path $PSScriptRoot   "UsdShellExtension.ini"),
    (Join-Path $PSScriptRoot   "bin\v145\3.12\Release\UsdShellExtension.ini"),
    "C:\Program Files\UsdShellExtension\UsdShellExtension.ini",
    (Join-Path $env:LOCALAPPDATA "UsdShellExtension\UsdShellExtension.ini"),
    (Join-Path $env:PROGRAMDATA  "UsdShellExtension\UsdShellExtension.ini")
)
$_ini = $_candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $_ini) {
    Write-Error ("UsdShellExtension.ini not found. " +
                 "Run .\build.ps1 (and .\install.ps1 as Administrator) first.")
    return
}

# ---------------------------------------------------------------------------
# Parse helpers
# ---------------------------------------------------------------------------
function _USD_ReadIni {
    param([string]$Path, [string]$Section, [string]$Key)
    $inSect = $false
    foreach ($line in (Get-Content $Path -ErrorAction Stop)) {
        if ($line -match "^\[$([regex]::Escape($Section))\]") { $inSect = $true;  continue }
        if ($line -match "^\[")                               { $inSect = $false; continue }
        if ($inSect -and $line -match "^$([regex]::Escape($Key))\s*=\s*(.+)") {
            return [Environment]::ExpandEnvironmentVariables($Matches[1].Trim())
        }
    }
    return ""
}

$_usdBin    = _USD_ReadIni $_ini "USD"    "PATH"
$_pyHome    = _USD_ReadIni $_ini "PYTHON" "PATH"
$_pythonPath = _USD_ReadIni $_ini "USD"    "PYTHONPATH"
# Strip trailing separators from PYTHONHOME
$_pyHomeClean = $_pyHome.TrimEnd('\', ';', '/')

if (-not $_usdBin -and -not $_pyHome) {
    Write-Error "Could not read [USD] PATH from $_ini"
    return
}

# ---------------------------------------------------------------------------
# Command wrappers for the USD Python tools
# ---------------------------------------------------------------------------
# The Pixar entry points (usdview, usdrecord, usddiff, ...) are Python files
# without extension: Windows cannot run them by name. Each one gets a
# function running it with the bundled Python. (The SDK scripts\*.bat
# wrappers are NVIDIA proprietary and are not shipped.)
$_pythonExe = Join-Path $_pyHomeClean "python.exe"
$_tools = @(foreach ($_dir in ($_usdBin -split ';' | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
    Get-ChildItem -LiteralPath $_dir -File | Where-Object {
        -not $_.Extension -and ((Get-Content -LiteralPath $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue) -match '^#!.*python')
    }
})
$_toolDefinitions = ($_tools | ForEach-Object {
    "function global:$($_.Name) { & '$_pythonExe' '$($_.FullName)' @args }"
}) -join "`n"

# ---------------------------------------------------------------------------
# Detect dot-source vs direct invocation
# ---------------------------------------------------------------------------
$_dotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $_dotSourced) {
    # Launched directly: open a new PowerShell window pre-configured.
    $cmd = @"
`$env:PATH              = '$_pyHome;$_usdBin;' + `$env:PATH
`$env:PYTHONHOME        = '$_pyHomeClean'
`$env:PYTHONPATH        = '$_pythonPath'
`$env:PXR_PLUGINPATH_NAME = ''
$_toolDefinitions
Write-Host ''
Write-Host '  USD Shell' -ForegroundColor Cyan
Write-Host '  INI: $_ini' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Tools: usdchecker, usdview, usdcat, usdrecord, usdfixbrokenpixarschemas, ...' -ForegroundColor Green
Write-Host ''
"@
    $pwsh = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Start-Process $pwsh -ArgumentList "-NoExit", "-Command", $cmd
    return
}

# ---------------------------------------------------------------------------
# Dot-sourced: configure the current session
# ---------------------------------------------------------------------------
$env:PATH              = "$_pyHome;$_usdBin;" + $env:PATH
$env:PYTHONHOME        = $_pyHomeClean
$env:PYTHONPATH        = $_pythonPath
$env:PXR_PLUGINPATH_NAME = ""

foreach ($_tool in $_tools) {
    Set-Item -Path "Function:global:$($_tool.Name)" `
             -Value ([scriptblock]::Create("& '$_pythonExe' '$($_tool.FullName)' @args"))
}

Write-Host ""
Write-Host "  USD Shell" -ForegroundColor Cyan
Write-Host ("  INI         : {0}" -f $_ini)         -ForegroundColor DarkGray
Write-Host ("  PATH +      : {0}" -f $_usdBin)      -ForegroundColor DarkGray
Write-Host ("  PYTHONHOME  : {0}" -f $_pyHomeClean) -ForegroundColor DarkGray
Write-Host ("  PYTHONPATH  : {0}" -f $_pythonPath)  -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Tools: usdchecker, usdview, usdcat, usdrecord, usdfixbrokenpixarschemas, ..." `
    -ForegroundColor Green
Write-Host ""

# Clean up private variables and helpers from the caller's scope.
Remove-Variable _candidates, _ini, _usdBin, _pyHome, _pyHomeClean, `
                _pythonPath, _dotSourced, _pythonExe, _tools, _tool, _dir, `
                _toolDefinitions `
                -ErrorAction SilentlyContinue
Remove-Item Function:_USD_ReadIni -ErrorAction SilentlyContinue
