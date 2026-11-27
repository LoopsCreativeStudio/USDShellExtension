#Requires -Version 5.1
<#
.SYNOPSIS
    Reproduce "the preview pane turns white after a left click".

.DESCRIPTION
    Opens an Explorer window on a USD file with the preview pane, waits for
    the USD preview to load, captures it, left-clicks in its center, captures
    it again and compares the share of white pixels. Also logs the state of
    the preview window (visible, styles, parent) before and after the click.

    It drives the desktop for about 10 seconds: do not touch the mouse.
    The Explorer window it opened is closed at the end.
    Screenshots are saved to build\bench\preview\.

.PARAMETER UsdFile
    USD file to preview.

.PARAMETER LoadTimeoutSeconds
    Longest wait for the preview to appear. Default: 60.

.PARAMETER ClickX
    Horizontal click position, as a fraction of the preview width. Default: 0.5.

.PARAMETER ClickY
    Vertical click position, as a fraction of the preview height. Default: 0.5.

.PARAMETER WindowWidth
    Width of the Explorer window, in pixels. Default: 1100.

.PARAMETER WindowHeight
    Height of the Explorer window, in pixels. Default: 750.

.PARAMETER WatchSeconds
    Observation mode: no synthetic click. For this many seconds the user
    clicks in the preview; every 300 ms the script logs the preview and
    foreground windows and the share of white pixels, and saves a capture
    each time the preview turns white.

.EXAMPLE
    PS> .\tools\Test-PreviewClick.ps1 -UsdFile C:\scenes\Kitchen_set.usd
#>
param(
    [Parameter(Mandatory)][string]$UsdFile,
    [int]$LoadTimeoutSeconds = 60,
    [double]$ClickX = 0.5,
    [double]$ClickY = 0.5,
    [int]$WatchSeconds = 0,
    [int]$WindowWidth = 1100,
    [int]$WindowHeight = 750
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot "UsdShellExtension.Build.psm1") -Force
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PreviewWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }

    public static List<IntPtr> TopWindowsOfClass(string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { if (ClassOf(h) == cls) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    // Child windows of 'parent' that belong to process 'pid'.
    public static List<IntPtr> ChildrenOfProcess(IntPtr parent, uint pid) {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, (h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
}
"@

$GWL_STYLE = -16; $GWL_EXSTYLE = -20
$MOUSEEVENTF_LEFTDOWN = 0x0002; $MOUSEEVENTF_LEFTUP = 0x0004; $WM_CLOSE = 0x0010

$UsdFile = (Resolve-Path $UsdFile).Path
$outDir = Join-Path $REPO "build\bench\preview"
New-Item -ItemType Directory -Force $outDir | Out-Null

function Get-WindowState {
    <#
        Describe a window: visible, styles, parent, rectangle.
    #>
    param([IntPtr]$Handle)
    $rect = New-Object PreviewWin+RECT
    [void][PreviewWin]::GetWindowRect($Handle, [ref]$rect)
    $style = [PreviewWin]::GetWindowLong($Handle, $GWL_STYLE)
    [pscustomobject]@{
        Visible = [PreviewWin]::IsWindowVisible($Handle)
        Style   = '0x{0:X8} (WS_CHILD={1} WS_POPUP={2} WS_VISIBLE={3})' -f $style, [bool]($style -band 0x40000000), [bool]($style -band 0x80000000), [bool]($style -band 0x10000000)
        ExStyle = '0x{0:X8}' -f [PreviewWin]::GetWindowLong($Handle, $GWL_EXSTYLE)
        Parent  = '0x{0:X} ({1})' -f [PreviewWin]::GetParent($Handle).ToInt64(), [PreviewWin]::ClassOf([PreviewWin]::GetParent($Handle))
        Rect    = "$($rect.Left),$($rect.Top) $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top)"
        RawRect = $rect
    }
}

function Save-Capture {
    <#
        Capture a screen rectangle to a PNG; return the share of white pixels.
    #>
    param($Rect, [string]$Path)
    $width = $Rect.Right - $Rect.Left; $height = $Rect.Bottom - $Rect.Top
    # A hidden or destroyed preview has no size: nothing drawn, count as white.
    if ($width -le 0 -or $height -le 0) { return 1.0 }
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $white = 0; $total = 0
    for ($y = 0; $y -lt $height; $y += 4) {
        for ($x = 0; $x -lt $width; $x += 4) {
            $pixel = $bitmap.GetPixel($x, $y); $total++
            if ($pixel.R -gt 240 -and $pixel.G -gt 240 -and $pixel.B -gt 240) { $white++ }
        }
    }
    $graphics.Dispose(); $bitmap.Dispose()
    return [math]::Round($white / [math]::Max(1, $total), 3)
}

function Compare-Capture {
    <#
        Share of sampled pixels that differ between two captures: proves the
        click had a visible effect (selection highlight, prim path label).
    #>
    param([string]$First, [string]$Second)
    $a = New-Object System.Drawing.Bitmap $First; $b = New-Object System.Drawing.Bitmap $Second
    $changed = 0; $total = 0
    for ($y = 0; $y -lt $a.Height; $y += 4) {
        for ($x = 0; $x -lt $a.Width; $x += 4) {
            $total++
            if ($a.GetPixel($x, $y).ToArgb() -ne $b.GetPixel($x, $y).ToArgb()) { $changed++ }
        }
    }
    $a.Dispose(); $b.Dispose()
    return [math]::Round($changed / [math]::Max(1, $total), 3)
}

# ---------------------------------------------------------------------------
# 1. Open Explorer on the file (preview pane: Alt+P if it is closed)
# ---------------------------------------------------------------------------
Write-Step "Preview click test: $(Split-Path $UsdFile -Leaf)"
$before = [PreviewWin]::TopWindowsOfClass("CabinetWClass")
Start-Process explorer.exe "/select,`"$UsdFile`""

$explorer = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(15)
while ($explorer -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $explorer = [PreviewWin]::TopWindowsOfClass("CabinetWClass") | Where-Object { $before -notcontains $_ } | Select-Object -First 1
    if (-not $explorer) { $explorer = [IntPtr]::Zero }
}
if ($explorer -eq [IntPtr]::Zero) { throw "Explorer window did not open" }
# Small, fixed window on the primary screen: never maximized.
[void][PreviewWin]::ShowWindow($explorer, 1)	# SW_SHOWNORMAL
[void][PreviewWin]::MoveWindow($explorer, 100, 100, $WindowWidth, $WindowHeight, $true)
[void][PreviewWin]::SetForegroundWindow($explorer)

try {
    # -----------------------------------------------------------------------
    # 2. Wait for the USD preview window (owned by UsdPreviewLocalServer)
    # -----------------------------------------------------------------------
    $preview = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds($LoadTimeoutSeconds)
    # No Alt+P here: it toggles the preview pane, and would close a pane that
    # is open but still loading. A closed pane is reported instead.
    while ($preview -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        foreach ($server in @(Get-Process UsdPreviewLocalServer -ErrorAction SilentlyContinue)) {
            # The server owns several windows: keep the largest visible one
            # (the preview itself), never a zero-sized helper window.
            $largest = [PreviewWin]::ChildrenOfProcess($explorer, [uint32]$server.Id) |
                Where-Object { [PreviewWin]::IsWindowVisible($_) } |
                ForEach-Object { $r = (Get-WindowState $_).RawRect; [pscustomobject]@{ Handle = $_; Area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top) } } |
                Where-Object { $_.Area -gt 10000 } |
                Sort-Object Area -Descending | Select-Object -First 1
            if ($largest) { $preview = $largest.Handle; break }
        }
    }
    if ($preview -eq [IntPtr]::Zero) {
        throw "USD preview window did not appear within $LoadTimeoutSeconds s (is the Explorer preview pane open? Alt+P)"
    }
    Start-Sleep -Seconds 5	# let Explorer finish its layout and the first frames render
    [void][PreviewWin]::SetForegroundWindow($explorer)
    Start-Sleep -Milliseconds 500

    # -----------------------------------------------------------------------
    # 3a. Observation mode: the user clicks, the script records
    # -----------------------------------------------------------------------
    if ($WatchSeconds -gt 0) {
        Write-Host ""
        Write-Host "    >>> Click in the USD preview now, as usual ($WatchSeconds s) <<<" -ForegroundColor Yellow
        $watchStart = Get-Date; $wasWhite = $false; $last = ""; $captureIndex = 0
        while (((Get-Date) - $watchStart).TotalSeconds -lt $WatchSeconds) {
            $state = Get-WindowState $preview
            $foreground = [PreviewWin]::GetForegroundWindow()
            $foregroundPid = [uint32]0; [void][PreviewWin]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
            $white = Save-Capture $state.RawRect (Join-Path $outDir "watch_last.png")
            $isWhite = $white -ge 0.5
            if ($isWhite -and -not $wasWhite) {
                $captureIndex++
                Copy-Item (Join-Path $outDir "watch_last.png") (Join-Path $outDir ("watch_white_{0}.png" -f $captureIndex)) -Force
            }
            $wasWhite = $isWhite
            $foregroundProcess = Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
            $foregroundName = if ($foregroundProcess) { $foregroundProcess.ProcessName } else { "?" }
            $line = "visible={0} style={1} rect={2} white={3} foreground=0x{4:X} {5} ({6})" -f $state.Visible, ($state.Style -split ' ')[0], $state.Rect, $white, $foreground.ToInt64(), [PreviewWin]::ClassOf($foreground), $foregroundName
            # Log changes only, with the elapsed time.
            $key = $line -replace 'white=[0-9.,]+', ('white=' + $(if ($isWhite) { 'WHITE' } else { 'ok' }))
            if ($key -ne $last) { Write-Host ("    +{0,5:N1}s  {1}" -f ((Get-Date) - $watchStart).TotalSeconds, $line); $last = $key }
            Start-Sleep -Milliseconds 300
        }
        Write-Detail "White captures" $captureIndex
        Write-Detail "Screenshots" $outDir
        $script:failed = $captureIndex -gt 0
        return
    }

    # -----------------------------------------------------------------------
    # 3. Capture, click in the center, capture again
    # -----------------------------------------------------------------------
    $stateBefore = Get-WindowState $preview
    $whiteBefore = Save-Capture $stateBefore.RawRect (Join-Path $outDir "before.png")

    $centerX = [int]($stateBefore.RawRect.Left + ($stateBefore.RawRect.Right - $stateBefore.RawRect.Left) * $ClickX)
    $centerY = [int]($stateBefore.RawRect.Top + ($stateBefore.RawRect.Bottom - $stateBefore.RawRect.Top) * $ClickY)
    [void][PreviewWin]::SetCursorPos($centerX, $centerY)
    Start-Sleep -Milliseconds 200
    [PreviewWin]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [PreviewWin]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1500

    # Which window the click brought to the foreground (the bug: a hidden
    # window of the preview server instead of Explorer).
    $foreground = [PreviewWin]::GetForegroundWindow()
    $foregroundPid = [uint32]0; [void][PreviewWin]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)

    # A real click activates the preview window (seen in observation mode);
    # a synthetic click does not always: activate it explicitly, then the
    # user goes back to Explorer, the step that hid the Qt "popup".
    [void][PreviewWin]::SetForegroundWindow($preview)
    Start-Sleep -Milliseconds 700
    # Back to Explorer with a real click on its title bar: Windows often
    # refuses SetForegroundWindow from a background process, a click never.
    $explorerRect = New-Object PreviewWin+RECT
    [void][PreviewWin]::GetWindowRect($explorer, [ref]$explorerRect)
    [void][PreviewWin]::SetCursorPos([int]($explorerRect.Left + ($explorerRect.Right - $explorerRect.Left) / 3), $explorerRect.Top + 12)
    Start-Sleep -Milliseconds 150
    [PreviewWin]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [PreviewWin]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1500

    $stateAfter = Get-WindowState $preview
    $whiteAfter = Save-Capture $stateBefore.RawRect (Join-Path $outDir "after.png")

    # -----------------------------------------------------------------------
    # 4. Report
    # -----------------------------------------------------------------------
    Write-Detail "Window" ('0x{0:X} ({1})' -f $preview.ToInt64(), [PreviewWin]::ClassOf($preview))
    foreach ($name in "Visible", "Style", "ExStyle", "Parent", "Rect") {
        Write-Host ("    {0,-8} before: {1}" -f $name, $stateBefore.$name)
        Write-Host ("    {0,-8} after : {1}" -f "", $stateAfter.$name)
    }
    $foregroundProcess = Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
    $foregroundName = if ($foregroundProcess) { $foregroundProcess.ProcessName } else { "?" }
    Write-Detail "Foreground" ('0x{0:X} ({1}, pid {2}: {3})' -f $foreground.ToInt64(), [PreviewWin]::ClassOf($foreground), $foregroundPid, $foregroundName)
    Write-Detail "Click at" "$centerX,$centerY ($ClickX, $ClickY)"
    Write-Detail "White before" $whiteBefore
    Write-Detail "White after" $whiteAfter
    Write-Detail "Changed px" (Compare-Capture (Join-Path $outDir "before.png") (Join-Path $outDir "after.png"))
    Write-Detail "Screenshots" $outDir

    # The preview must stay where it was: Qt used to move it on activation.
    $moved = [math]::Abs($stateAfter.RawRect.Left - $stateBefore.RawRect.Left) -gt 4 -or
             [math]::Abs($stateAfter.RawRect.Top - $stateBefore.RawRect.Top) -gt 4
    if (-not $stateAfter.Visible -or $moved -or ($whiteBefore -lt 0.5 -and $whiteAfter -ge 0.5)) {
        Write-Host ("    ! preview hidden, moved ({0}) or white after click + back to Explorer" -f $moved) -ForegroundColor Red
        $script:failed = $true
    } else {
        Write-Item "preview still drawn after the click"
        $script:failed = $false
    }
}
finally {
    [void][PreviewWin]::PostMessage($explorer, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}

if ($script:failed) { throw "Preview click test failed" }
