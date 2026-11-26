#Requires -Version 5.1
<#
.SYNOPSIS
    Integration test of the installed USD property handler (Details tab).

.DESCRIPTION
    Writes a .usda file with metadata and custom layer data of several value
    types, then reads its properties through Shell.Application, the same path
    as the Explorer Details tab and Windows Search. Checks the comment, format,
    frame rate and that every custom layer data value is rendered (no
    "[UNKNOWN TYPE]").

    Runs the Shell part in a child PowerShell so the in-process handler DLL
    is not left loaded (and locked) in the calling session.

.EXAMPLE
    PS> .\tools\Test-PropertyHandler.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot "UsdShellExtension.Build.psm1") -Force

# ---------------------------------------------------------------------------
# Test file: one value per common custom layer data type
# ---------------------------------------------------------------------------
$propsDir = Join-Path $REPO "build\bench\props"
New-Item -ItemType Directory -Force $propsDir | Out-Null
$usdFile = Join-Path $propsDir ("props_{0}.usda" -f ([guid]::NewGuid().ToString("N").Substring(0, 8)))

Set-Content $usdFile -Encoding ASCII -Value @'
#usda 1.0
(
    "Property handler test"
    framesPerSecond = 25
    customLayerData = {
        bool approved = 1
        int version = 2
        float scale = 0.5
        string author = "jb"
        token purpose = "render"
        asset texture = @./tex.png@
        int[] frames = [1, 2, 3]
        dictionary pipeline = {
            string shot = "010"
        }
    }
)
def Cube "Cube"
{
}
'@

Write-Step "Property handler: $(Split-Path $usdFile -Leaf)"

# ---------------------------------------------------------------------------
# Read through the Shell, in a child process
# ---------------------------------------------------------------------------
$readProperties = {
    param($Path)
    $shell  = New-Object -ComObject Shell.Application
    $folder = $shell.NameSpace((Split-Path $Path -Parent))
    $item   = $folder.ParseName((Split-Path $Path -Leaf))
    $names  = @("System.Comment", "USD.Format", "USD.FrameRate", "USD.CustomLayerData")
    $result = @{}
    foreach ($name in $names) { $result[$name] = "$($item.ExtendedProperty($name))" }
    $result | ConvertTo-Json -Compress
}
$hostExe = [Diagnostics.Process]::GetCurrentProcess().Path
$json = & $hostExe -NoProfile -Command $readProperties -args $usdFile
$properties = $json | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
$failures = @()
function Test-Property {
    <#
        Record a failure when the actual value does not satisfy the check.
    #>
    param([string]$Name, [bool]$Ok, [string]$Expected)
    $status = if ($Ok) { "ok" } else { "FAILED, expected $Expected" }
    Write-Host ("    {0,-22} {1}" -f $Name, $status)
    if (-not $Ok) { $script:failures += "$Name (expected $Expected)" }
}

Test-Property "System.Comment" ($properties.'System.Comment' -eq "Property handler test") "'Property handler test'"
Test-Property "USD.Format"     ($properties.'USD.Format' -eq "USDA") "'USDA'"
Test-Property "USD.FrameRate"  ($properties.'USD.FrameRate' -eq "25") "'25'"

$customData = [string]$properties.'USD.CustomLayerData'
foreach ($expected in @("approved=true", "version=2", "scale=0.5", "author=jb", "purpose=render",
                        "texture=@./tex.png@", "frames=[1, 2, 3]", "pipeline.shot=010")) {
    Test-Property "USD.CustomLayerData" ($customData.Contains($expected)) $expected
}
Test-Property "USD.CustomLayerData" (-not $customData.Contains("[UNKNOWN TYPE]")) "no [UNKNOWN TYPE]"

Remove-Item $usdFile -Force

if ($failures) {
    $failures | ForEach-Object { Write-Host "    ! $_" -ForegroundColor Red }
    Write-Host "    Values read:" -ForegroundColor Red
    $properties.PSObject.Properties | ForEach-Object {
        Write-Host ("      {0} = {1}" -f $_.Name, ($_.Value -replace "`r?`n", " | ")) -ForegroundColor Red
    }
    throw "Property handler test failed ($($failures.Count) problem(s))"
}
Write-Item "All properties read through the Shell as expected"
