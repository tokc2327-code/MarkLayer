# Shared DPI-aware Windows UIA core helpers.
# Must be dot-sourced BEFORE loading System.Windows.Forms so WinForms does not
# cache an unaware 96-DPI context at assembly load time.

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('DesktopUiaNative' -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DesktopUiaNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
  [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
  public struct MONITORINFO {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
  }
}
"@
}

function Enable-DesktopPerMonitorDpi {
  try {
    if (![DesktopUiaNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
      [DesktopUiaNative]::SetProcessDPIAware() | Out-Null
    }
  } catch {
    [DesktopUiaNative]::SetProcessDPIAware() | Out-Null
  }
  $threadCtx = [DesktopUiaNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
  $currentCtx = [DesktopUiaNative]::GetThreadDpiAwarenessContext()
  if ([DesktopUiaNative]::GetAwarenessFromDpiAwarenessContext($currentCtx) -eq 0) {
    throw 'Process/thread is DPI-unaware: coordinates would be virtualized at 96 DPI'
  }
}

Enable-DesktopPerMonitorDpi

$script:UiaWalker = [System.Windows.Automation.TreeWalker]::RawViewWalker

function ConvertTo-RectMap($r) {
  if ($null -eq $r -or $r.IsEmpty) { return $null }
  return [ordered]@{
    left   = [double]$r.X
    top    = [double]$r.Y
    width  = [double]$r.Width
    height = [double]$r.Height
  }
}

function Get-DpiScale([IntPtr]$hwnd) {
  $dpi = 0
  if ($hwnd -ne [IntPtr]::Zero) {
    try { $dpi = [DesktopUiaNative]::GetDpiForWindow($hwnd) } catch { $dpi = 0 }
  }
  if ($dpi -eq 0) {
    try { $dpi = [DesktopUiaNative]::GetDpiForSystem() } catch { $dpi = 96 }
  }
  if ($dpi -le 0) { $dpi = 96 }
  return [Math]::Round($dpi / 96.0, 4)
}

function Get-ScreenInfo([IntPtr]$hwnd) {
  $scale = Get-DpiScale $hwnd
  $width = [DesktopUiaNative]::GetSystemMetrics(0)
  $height = [DesktopUiaNative]::GetSystemMetrics(1)
  if ($hwnd -ne [IntPtr]::Zero) {
    $mon = [DesktopUiaNative]::MonitorFromWindow($hwnd, 2)
    if ($mon -ne [IntPtr]::Zero) {
      $mi = New-Object DesktopUiaNative+MONITORINFO
      $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][DesktopUiaNative+MONITORINFO])
      if ([DesktopUiaNative]::GetMonitorInfo($mon, [ref]$mi)) {
        $width = $mi.rcMonitor.Right - $mi.rcMonitor.Left
        $height = $mi.rcMonitor.Bottom - $mi.rcMonitor.Top
      }
    }
  }
  return [ordered]@{
    width  = [int]$width
    height = [int]$height
    scale  = [double]$scale
  }
}

function Get-ElementIdentity($e) {
  $c = $e.Current
  return [ordered]@{
    controlType  = [string]$c.ControlType.ProgrammaticName
    name         = [string]$c.Name
    automationId = [string]$c.AutomationId
  }
}

function Get-DesktopWindows {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    try {
      $c = $e.Current
      if ($c.NativeWindowHandle -eq 0 -or !$c.Name) { continue }
      $p = Get-Process -Id $c.ProcessId -ErrorAction Stop
      $class = New-Object System.Text.StringBuilder 256
      [void][DesktopUiaNative]::GetClassName([IntPtr]$c.NativeWindowHandle, $class, $class.Capacity)
      $path = $null
      try { $path = $p.Path } catch { }
      [pscustomobject]@{
        element     = $e
        hwnd        = [long]$c.NativeWindowHandle
        pid         = [int]$c.ProcessId
        title       = [string]$c.Name
        process     = [string]$p.ProcessName
        appPath     = $path
        windowClass = $class.ToString()
        minimized   = [bool][DesktopUiaNative]::IsIconic([IntPtr]$c.NativeWindowHandle)
        rect        = (ConvertTo-RectMap $c.BoundingRectangle)
      }
    } catch { }
  }
}

function Get-ElementAncestry($node, $root) {
  $parts = New-Object System.Collections.ArrayList
  $cur = $script:UiaWalker.GetParent($node)
  while ($cur) {
    [void]$parts.Insert(0, (Get-ElementIdentity $cur))
    if ([System.Windows.Automation.Automation]::Compare($cur, $root)) {
      return ,@($parts.ToArray())
    }
    $cur = $script:UiaWalker.GetParent($cur)
  }
  return $null
}

function Test-SamePath($a, $b) {
  if ($null -eq $a -or $null -eq $b) { return $false }
  $arrA = @($a)
  $arrB = @($b)
  if ($arrA.Count -ne $arrB.Count) { return $false }
  for ($i = 0; $i -lt $arrA.Count; $i++) {
    foreach ($key in @('controlType', 'name', 'automationId')) {
      if ($arrA[$i].$key -cne $arrB[$i].$key) { return $false }
    }
  }
  return $true
}

function Resolve-DesktopTarget($t) {
  $windows = @(Get-DesktopWindows | Where-Object { $_.process -ieq $t.app })
  if (!$windows.Count) { return @{ ok = $false; reason = 'app_not_found' } }
  if ($t.appPath) {
    $windows = @($windows | Where-Object { $_.appPath -and $_.appPath -ieq $t.appPath })
    if (!$windows.Count) { return @{ ok = $false; reason = 'app_path_not_found' } }
  }
  if ($t.windowClass) {
    $windows = @($windows | Where-Object { $_.windowClass -ceq $t.windowClass })
    if (!$windows.Count) { return @{ ok = $false; reason = 'window_class_not_found' } }
  }
  $windows = @($windows | Where-Object { $_.title -ceq $t.windowTitle })
  if (!$windows.Count) { return @{ ok = $false; reason = 'window_title_not_found' } }
  if ($windows.Count -eq 1 -and $windows[0].minimized) {
    return @{ ok = $true; minimized = $true; hwnd = $windows[0].hwnd; rect = $null }
  }
  $matches = @(foreach ($w in $windows) {
    $nodes = @($w.element) + @($w.element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_ })
    foreach ($node in $nodes) {
      try {
        $c = $node.Current
        if ($c.AutomationId -cne $t.automationId -or $c.ControlType.ProgrammaticName -cne $t.controlType -or $c.Name -cne $t.name) { continue }
        $path = if ([System.Windows.Automation.Automation]::Compare($node, $w.element)) { @() } else { Get-ElementAncestry $node $w.element }
        if ((Test-SamePath $path $t.ancestry) -and !$c.BoundingRectangle.IsEmpty) {
          @{ hwnd = $w.hwnd; rect = (ConvertTo-RectMap $c.BoundingRectangle) }
        }
      } catch { }
    }
  })
  if ($matches.Count -eq 0) { return @{ ok = $false; reason = 'not_found' } }
  if ($matches.Count -gt 1) { return @{ ok = $false; reason = "ambiguous:$($matches.Count)" } }
  return @{ ok = $true; minimized = $false; hwnd = $matches[0].hwnd; rect = $matches[0].rect }
}

function Build-DesktopTarget($element, $windowInfo, $dragRect = $null) {
  $c = $element.Current
  $elemRect = ConvertTo-RectMap $c.BoundingRectangle
  if ($null -eq $elemRect -or $elemRect.width -le 0 -or $elemRect.height -le 0) { return $null }

  $ancestry = if ([System.Windows.Automation.Automation]::Compare($element, $windowInfo.element)) {
    @()
  } else {
    Get-ElementAncestry $element $windowInfo.element
  }
  if ($null -eq $ancestry) { return $null }

  $hwnd = [IntPtr]$windowInfo.hwnd
  $dpr = Get-DpiScale $hwnd
  $screen = Get-ScreenInfo $hwnd

  if ($null -ne $dragRect -and $dragRect.width -ge 6 -and $dragRect.height -ge 6) {
    $relLeft = [Math]::Round($dragRect.left - $elemRect.left, 2)
    $relTop = [Math]::Round($dragRect.top - $elemRect.top, 2)
    $relW = [Math]::Round($dragRect.width, 2)
    $relH = [Math]::Round($dragRect.height, 2)
    $cap = [ordered]@{
      left   = [double]$dragRect.left
      top    = [double]$dragRect.top
      width  = [double]$dragRect.width
      height = [double]$dragRect.height
      dpr    = [double]$dpr
    }
  } else {
    $relLeft = 0
    $relTop = 0
    $relW = [double]$elemRect.width
    $relH = [double]$elemRect.height
    $cap = [ordered]@{
      left   = [double]$elemRect.left
      top    = [double]$elemRect.top
      width  = [double]$elemRect.width
      height = [double]$elemRect.height
      dpr    = [double]$dpr
    }
  }

  $target = [ordered]@{
    kind         = 'windows-uia'
    app          = [string]$windowInfo.process
    windowTitle  = [string]$windowInfo.title
    controlType  = [string]$c.ControlType.ProgrammaticName
    name         = [string]$c.Name
    automationId = [string]$c.AutomationId
    relativeRect = [ordered]@{
      left   = [double]$relLeft
      top    = [double]$relTop
      width  = [double]$relW
      height = [double]$relH
    }
    ancestry     = @($ancestry)
    captured     = $cap
    screen       = $screen
  }
  if ($windowInfo.appPath) { $target.appPath = [string]$windowInfo.appPath }
  if ($windowInfo.windowClass) { $target.windowClass = [string]$windowInfo.windowClass }
  return $target
}

function Get-WindowInfoForElement($element) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $cur = $element
  while ($cur) {
    $parent = $script:UiaWalker.GetParent($cur)
    if ($parent -and [System.Windows.Automation.Automation]::Compare($parent, $root)) {
      $c = $cur.Current
      if ($c.NativeWindowHandle -eq 0) { return $null }
      $p = Get-Process -Id $c.ProcessId -ErrorAction Stop
      $class = New-Object System.Text.StringBuilder 256
      [void][DesktopUiaNative]::GetClassName([IntPtr]$c.NativeWindowHandle, $class, $class.Capacity)
      $path = $null
      try { $path = $p.Path } catch { }
      return [pscustomobject]@{
        element     = $cur
        hwnd        = [long]$c.NativeWindowHandle
        pid         = [int]$c.ProcessId
        title       = [string]$c.Name
        process     = [string]$p.ProcessName
        appPath     = $path
        windowClass = $class.ToString()
      }
    }
    $cur = $parent
  }
  return $null
}

function Get-TargetAtPoint([int]$x, [int]$y, $dragRect = $null) {
  try {
    $pt = New-Object System.Windows.Point($x, $y)
    $el = [System.Windows.Automation.AutomationElement]::FromPoint($pt)
    if ($null -eq $el) { return $null }
    $win = Get-WindowInfoForElement $el
    if ($null -eq $win) { return $null }
    return Build-DesktopTarget $el $win $dragRect
  } catch {
    return $null
  }
}
