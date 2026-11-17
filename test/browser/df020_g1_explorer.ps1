<#
.SYNOPSIS
  DF-020 G-1 (Method 1): one OS-injected Explorer-origin multi-file drag.

.DESCRIPTION
  Verification support, not product code. Nothing here is imported by `lib/`.

  Locates the fixture items in a real File Explorer window through Windows UI
  Automation, selects them in the given (reversed) order, and performs ONE mouse
  drag with user32 SendInput from the last selected item to the centre of the
  target browser window. Explorer itself starts the OLE drag; the browser
  receives it through its native drop path. No DevTools-protocol drag and no
  script-built DataTransfer is involved.

  Every step is logged with a UTC millisecond timestamp, together with the UI
  Automation identity of the source window and items and of the target window,
  so the browser-side drop record can be correlated with the injected gesture.
  Requires an unlocked, interactive desktop. With -DryRun nothing is selected
  and no input is sent.
#>
param(
  [Parameter(Mandatory)] [string] $Folder,
  [Parameter(Mandatory)] [string] $Order,            # comma-separated display names, in selection order
  [Parameter(Mandatory)] [string] $TargetProcess,    # chrome | msedge | firefox
  [Parameter(Mandatory)] [string] $TargetTitle,      # substring of the browser window title
  [Parameter(Mandatory)] [string] $Log,
  [string] $Screenshot = '',
  [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
# A new, untyped variable: assigning the array back to the [string] parameter would
# re-join it into one space-separated string.
$Names = @($Order -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class G1 {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; public int pad1; public int pad2; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
  public static uint Mouse(int x, int y, uint flags) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    var i = new INPUT(); i.type = 0;
    i.mi.dx = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
    i.mi.dy = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
    i.mi.dwFlags = flags | MOVE | ABSOLUTE | VIRTUALDESK;
    return SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@
[void][G1]::SetProcessDpiAwarenessContext([IntPtr](-4))   # per-monitor v2: UIA and SendInput share physical pixels

$entries = New-Object System.Collections.ArrayList
function Note($step, $data = @{}) {
  $entry = [ordered]@{ t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); step = $step }
  foreach ($key in $data.Keys) { $entry[$key] = $data[$key] }
  [void]$entries.Add($entry)
  Write-Host ("{0} {1}" -f $entry.t, $step)
}
function Save() {
  $entries | ConvertTo-Json -Depth 6 | Set-Content -Path $Log -Encoding utf8
}
$A = [System.Windows.Automation.AutomationElement]
$T = [System.Windows.Automation.TreeScope]
function Rect($e) { $r = $e.Current.BoundingRectangle; @{ x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height } }
function Identity($e) {
  $proc = try { (Get-Process -Id $e.Current.ProcessId).ProcessName } catch { '?' }
  @{ name = $e.Current.Name; class = $e.Current.ClassName; pid = $e.Current.ProcessId; process = $proc; hwnd = $e.Current.NativeWindowHandle; rect = (Rect $e) }
}

try {
  $fg = [G1]::GetForegroundWindow()
  Note 'start' @{ folder = $Folder; order = $Names; targetProcess = $TargetProcess; targetTitle = $TargetTitle; dryRun = [bool]$DryRun; foregroundHwnd = [int64]$fg }

  # --- Source: a File Explorer window showing the fixture folder ---------------
  $leaf = Split-Path $Folder -Leaf
  $root = $A::RootElement
  $explorerCondition = New-Object System.Windows.Automation.PropertyCondition($A::ClassNameProperty, 'CabinetWClass')
  $source = $null
  foreach ($w in $root.FindAll($T::Children, $explorerCondition)) { if ($w.Current.Name -like "*$leaf*") { $source = $w; break } }
  if (-not $source) {
    Start-Process explorer.exe -ArgumentList "`"$Folder`""
    for ($i = 0; $i -lt 40 -and -not $source; $i++) {
      Start-Sleep -Milliseconds 250
      foreach ($w in $root.FindAll($T::Children, $explorerCondition)) { if ($w.Current.Name -like "*$leaf*") { $source = $w; break } }
    }
  }
  if (-not $source) { throw "no File Explorer window for $Folder" }
  $srcHwnd = [IntPtr]$source.Current.NativeWindowHandle
  [void][G1]::ShowWindow($srcHwnd, 9)
  [void][G1]::SetWindowPos($srcHwnd, [IntPtr]::Zero, 40, 80, 1100, 1000, 0x0040)
  Start-Sleep -Milliseconds 600

  # --- Target: the browser window under test -----------------------------------
  $target = $null
  foreach ($w in $root.FindAll($T::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    $proc = try { (Get-Process -Id $w.Current.ProcessId).ProcessName } catch { '' }
    if ($proc -eq $TargetProcess -and $w.Current.Name -like "*$TargetTitle*") { $target = $w; break }
  }
  if (-not $target) { throw "no $TargetProcess window titled *$TargetTitle*" }
  $tgtHwnd = [IntPtr]$target.Current.NativeWindowHandle
  [void][G1]::ShowWindow($tgtHwnd, 9)
  [void][G1]::SetWindowPos($tgtHwnd, [IntPtr]::Zero, 1180, 80, 1300, 1100, 0x0040)
  Start-Sleep -Milliseconds 800
  Note 'windows' @{ source = (Identity $source); target = (Identity $target) }

  # --- Items, selected in the given order ---------------------------------------
  [void][G1]::SetForegroundWindow($srcHwnd)
  Start-Sleep -Milliseconds 500
  $listItem = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
  $items = @{}
  foreach ($e in $source.FindAll($T::Descendants, $listItem)) { $items[$e.Current.Name] = $e }
  $chosen = foreach ($name in $Names) {
    $hit = $items[$name]; if (-not $hit) { $hit = $items["$([IO.Path]::GetFileNameWithoutExtension($name))"] }
    if (-not $hit) { throw "item $name not found; visible: $($items.Keys -join ', ')" }
    $hit
  }
  Note 'items' @{ found = @($chosen | ForEach-Object { @{ name = $_.Current.Name; rect = (Rect $_) } }) }
  if ($DryRun) { Note 'dry-run: no selection or input'; Save; return }

  $first = $true
  foreach ($e in $chosen) {
    $pattern = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if ($first) { $pattern.Select(); $first = $false } else { $pattern.AddToSelection() }
    Note 'select' @{ name = $e.Current.Name }
    Start-Sleep -Milliseconds 250
  }
  $selected = @($chosen | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } | ForEach-Object { $_.Current.Name })
  Note 'selection-verified' @{ selected = $selected }
  if ($selected.Count -ne $Names.Count) { throw "selection incomplete: $($selected -join ', ')" }

  # --- One OS-injected drag: the last selected item → the browser window centre --
  $grab = Rect $chosen[-1]
  $sx = $grab.x + [int]($grab.w / 2); $sy = $grab.y + [int]($grab.h / 2)
  $tr = Rect $target
  $tx = $tr.x + [int]($tr.w / 2); $ty = $tr.y + [int]($tr.h / 2)
  [void][G1]::Mouse($sx, $sy, 0); Start-Sleep -Milliseconds 300
  Note 'mouse-at-source' @{ x = $sx; y = $sy; item = $chosen[-1].Current.Name }
  [void][G1]::Mouse($sx, $sy, [G1]::LEFTDOWN); Note 'left-down'
  Start-Sleep -Milliseconds 200
  for ($k = 1; $k -le 6; $k++) { [void][G1]::Mouse($sx + 4 * $k, $sy + 3 * $k, 0); Start-Sleep -Milliseconds 40 }
  Note 'drag-threshold-crossed'
  $steps = 40
  for ($k = 1; $k -le $steps; $k++) {
    $x = [int]($sx + ($tx - $sx) * $k / $steps); $y = [int]($sy + ($ty - $sy) * $k / $steps)
    [void][G1]::Mouse($x, $y, 0); Start-Sleep -Milliseconds 25
  }
  Note 'over-target' @{ x = $tx; y = $ty }
  for ($k = 0; $k -lt 12; $k++) { [void][G1]::Mouse($tx + ($k % 2) * 3, $ty, 0); Start-Sleep -Milliseconds 60 }
  [void][G1]::Mouse($tx, $ty, [G1]::LEFTUP); Note 'left-up (drop)'
  Start-Sleep -Milliseconds 2500

  if ($Screenshot) {
    $vx = [G1]::GetSystemMetrics(76); $vy = [G1]::GetSystemMetrics(77); $vw = [G1]::GetSystemMetrics(78); $vh = [G1]::GetSystemMetrics(79)
    $bmp = New-Object System.Drawing.Bitmap $vw, $vh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vx, $vy, 0, 0, $bmp.Size)
    $bmp.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Note 'desktop-screenshot' @{ path = $Screenshot }
  }
  Note 'done'
} catch {
  Note 'error' @{ message = "$_" }
  Save
  exit 1
}
Save
