param(
  [Parameter(Mandatory=$true)][ValidateSet('move-window','focus-window','click','drag','type-submit','inspect-point','crop-screenshot')][string]$Action,
  [int64]$Hwnd = 0,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$X1 = 0,
  [int]$Y1 = 0,
  [int]$X2 = 0,
  [int]$Y2 = 0,
  [int]$Width = 0,
  [int]$Height = 0,
  [string]$AllowedPids = '',
  [string]$CapturePids = '',
  [string]$Text = '',
  [string]$OutPath = ''
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32Driver {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

  [DllImport("user32.dll")]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

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

  [DllImport("user32.dll")]
  public static extern IntPtr WindowFromPoint(POINT pt);

  [DllImport("user32.dll")]
  public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);

  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

  [DllImport("user32.dll")]
  public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

  [DllImport("user32.dll")]
  public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

  public static System.Collections.Generic.List<IntPtr> ListChildWindows(IntPtr parent) {
    var list = new System.Collections.Generic.List<IntPtr>();
    EnumChildWindows(parent, (hwnd, _) => {
      list.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return list;
  }

  public static string GetClass(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return "";
    var sb = new StringBuilder(256);
    GetClassName(hwnd, sb, sb.Capacity);
    return sb.ToString();
  }

  public static IntPtr MakeLParam(int x, int y) {
    return new IntPtr(((y & 0xFFFF) << 16) | (x & 0xFFFF));
  }

  public static System.Collections.Generic.List<IntPtr> ListVisibleTopWindows() {
    var list = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((hwnd, _) => {
      if (IsWindowVisible(hwnd)) list.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return list;
  }

  public static uint GetPid(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return 0;
    uint pid = 0;
    GetWindowThreadProcessId(hwnd, out pid);
    return pid;
  }

  public static string GetTitle(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return "";
    var sb = new StringBuilder(512);
    GetWindowText(hwnd, sb, sb.Capacity);
    return sb.ToString();
  }
}
'@

[void][Win32Driver]::SetProcessDpiAwarenessContext([IntPtr](-4))
[void][Win32Driver]::SetThreadDpiAwarenessContext([IntPtr](-4))

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Parse-AllowedPids {
  if ([string]::IsNullOrWhiteSpace($AllowedPids)) { return @() }
  return @($AllowedPids.Split(',') | ForEach-Object { [uint32]$_.Trim() } | Where-Object { $_ -gt 0 })
}

function Get-PointOwner([int]$px, [int]$py) {
  $pt = New-Object Win32Driver+POINT
  $pt.X = $px
  $pt.Y = $py
  $raw = [Win32Driver]::WindowFromPoint($pt)
  $h = $raw
  $root = [Win32Driver]::GetAncestor($h, 2)
  if ($root -ne [IntPtr]::Zero) { $h = $root }
  $pidVal = [Win32Driver]::GetPid($h)
  $pname = ''
  if ($pidVal -gt 0) {
    try { $pname = (Get-Process -Id $pidVal -ErrorAction SilentlyContinue).ProcessName } catch { }
  }
  return [ordered]@{
    rawChildHwnd = [int64]$raw
    hwnd         = [int64]$h
    pid          = [uint32]$pidVal
    processName  = $pname
    title        = [Win32Driver]::GetTitle($h)
  }
}

function Assert-PointAllowed([int]$px, [int]$py, [uint32[]]$allowed) {
  if ($allowed.Count -eq 0) { throw "AllowedPids is required for safety before mouse interaction" }
  $owner = Get-PointOwner $px $py
  if ($allowed -notcontains $owner.pid) {
    throw "Safety abort: WindowFromPoint($px,$py) hit pid=$($owner.pid) ($($owner.processName) '$($owner.title)'), allowed=[$($allowed -join ',')]"
  }
  return $owner
}

switch ($Action) {
  'inspect-point' {
    (Get-PointOwner $X $Y) | ConvertTo-Json -Compress
  }

  'move-window' {
    if ($Hwnd -eq 0) { throw 'Hwnd required' }
    $ptr = [IntPtr]$Hwnd
    [void][Win32Driver]::SetWindowPos($ptr, [IntPtr]::Zero, $X, $Y, 0, 0, 0x0005)
    Start-Sleep -Milliseconds 60
    $r = New-Object Win32Driver+RECT
    [void][Win32Driver]::GetWindowRect($ptr, [ref]$r)
    [ordered]@{
      ok   = $true
      rect = [ordered]@{ left = $r.Left; top = $r.Top; width = ($r.Right - $r.Left); height = ($r.Bottom - $r.Top) }
    } | ConvertTo-Json -Compress
  }

  'focus-window' {
    if ($Hwnd -eq 0) { throw 'Hwnd required' }
    $ptr = [IntPtr]$Hwnd
    [void][Win32Driver]::ShowWindow($ptr, 9)
    [void][Win32Driver]::SetForegroundWindow($ptr)
    Start-Sleep -Milliseconds 60
    $fg = [Win32Driver]::GetForegroundWindow()
    [ordered]@{
      ok            = ($fg -eq $ptr)
      foregroundHwnd = [int64]$fg
      foregroundPid  = [Win32Driver]::GetPid($fg)
    } | ConvertTo-Json -Compress
  }

  'click' {
    $allowed = Parse-AllowedPids
    $owner = Assert-PointAllowed $X $Y $allowed
    $beforeFg = [Win32Driver]::GetForegroundWindow()
    $beforePid = [Win32Driver]::GetPid($beforeFg)
    $cursorMoved = [Win32Driver]::SetCursorPos($X, $Y)
    $inputMode = 'hardwareMouse'
    if ($cursorMoved) {
      Start-Sleep -Milliseconds 25
      [Win32Driver]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 20
      [Win32Driver]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    } else {
      $inputMode = 'win32MessageFallback'
      $child = [IntPtr]$owner.rawChildHwnd
      $cpt = New-Object Win32Driver+POINT
      $cpt.X = $X
      $cpt.Y = $Y
      [void][Win32Driver]::ScreenToClient($child, [ref]$cpt)
      $lp = [Win32Driver]::MakeLParam($cpt.X, $cpt.Y)
      [void][Win32Driver]::PostMessage($child, 0x0201, [IntPtr]1, $lp)
      Start-Sleep -Milliseconds 20
      [void][Win32Driver]::PostMessage($child, 0x0202, [IntPtr]0, $lp)
    }
    Start-Sleep -Milliseconds 100
    $afterFg = [Win32Driver]::GetForegroundWindow()
    $afterPid = [Win32Driver]::GetPid($afterFg)
    [ordered]@{
      ok                   = $true
      inputMode            = $inputMode
      hardwareCursorMoved  = $cursorMoved
      point                = [ordered]@{ x = $X; y = $Y }
      targetOwner          = $owner
      beforeForegroundPid  = $beforePid
      afterForegroundPid   = $afterPid
      afterForegroundTitle = [Win32Driver]::GetTitle($afterFg)
    } | ConvertTo-Json -Compress -Depth 4
  }

  'drag' {
    $allowed = Parse-AllowedPids
    $ownerStart = Assert-PointAllowed $X1 $Y1 $allowed
    $ownerEnd = Assert-PointAllowed $X2 $Y2 $allowed
    $cursorMoved = [Win32Driver]::SetCursorPos($X1, $Y1)
    $inputMode = 'hardwareMouse'
    $steps = 10
    if ($cursorMoved) {
      Start-Sleep -Milliseconds 30
      [Win32Driver]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 30
      for ($s = 1; $s -le $steps; $s++) {
        $nx = [int][Math]::Round($X1 + ($X2 - $X1) * ($s / [double]$steps))
        $ny = [int][Math]::Round($Y1 + ($Y2 - $Y1) * ($s / [double]$steps))
        [void][Win32Driver]::SetCursorPos($nx, $ny)
        Start-Sleep -Milliseconds 18
      }
      [Win32Driver]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    } else {
      $inputMode = 'win32MessageFallback'
      $child = [IntPtr]$ownerStart.rawChildHwnd
      $cpt1 = New-Object Win32Driver+POINT; $cpt1.X = $X1; $cpt1.Y = $Y1
      [void][Win32Driver]::ScreenToClient($child, [ref]$cpt1)
      [void][Win32Driver]::PostMessage($child, 0x0201, [IntPtr]1, [Win32Driver]::MakeLParam($cpt1.X, $cpt1.Y))
      Start-Sleep -Milliseconds 25
      for ($s = 1; $s -le $steps; $s++) {
        $nx = [int][Math]::Round($X1 + ($X2 - $X1) * ($s / [double]$steps))
        $ny = [int][Math]::Round($Y1 + ($Y2 - $Y1) * ($s / [double]$steps))
        $cpt = New-Object Win32Driver+POINT; $cpt.X = $nx; $cpt.Y = $ny
        [void][Win32Driver]::ScreenToClient($child, [ref]$cpt)
        [void][Win32Driver]::PostMessage($child, 0x0200, [IntPtr]1, [Win32Driver]::MakeLParam($cpt.X, $cpt.Y))
        Start-Sleep -Milliseconds 18
      }
      $cpt2 = New-Object Win32Driver+POINT; $cpt2.X = $X2; $cpt2.Y = $Y2
      [void][Win32Driver]::ScreenToClient($child, [ref]$cpt2)
      [void][Win32Driver]::PostMessage($child, 0x0202, [IntPtr]0, [Win32Driver]::MakeLParam($cpt2.X, $cpt2.Y))
    }
    Start-Sleep -Milliseconds 100
    [ordered]@{
      ok                  = $true
      inputMode           = $inputMode
      hardwareCursorMoved = $cursorMoved
      start               = [ordered]@{ x = $X1; y = $Y1; owner = $ownerStart }
      end                 = [ordered]@{ x = $X2; y = $Y2; owner = $ownerEnd }
    } | ConvertTo-Json -Compress -Depth 4
  }

  'type-submit' {
    $allowed = Parse-AllowedPids
    if ($allowed.Count -eq 0) { throw "AllowedPids is required for type-submit" }
    $probe = [Win32Driver]::SetCursorPos(10, 10)
    if ($probe) {
      $deadline = [DateTime]::UtcNow.AddMilliseconds(3000)
      $fg = [IntPtr]::Zero
      $fgPid = [uint32]0
      while ([DateTime]::UtcNow -lt $deadline) {
        $fg = [Win32Driver]::GetForegroundWindow()
        $fgPid = [Win32Driver]::GetPid($fg)
        if ($allowed -contains $fgPid) { break }
        Start-Sleep -Milliseconds 50
      }
      if ($allowed -notcontains $fgPid) {
        throw "Safety abort: foreground pid=$fgPid ('$([Win32Driver]::GetTitle($fg))') not in allowed=[$($allowed -join ',')]"
      }
      $escaped = $Text -replace '([+^%~()\[\]{}])', '{$1}'
      [System.Windows.Forms.SendKeys]::SendWait($escaped)
      Start-Sleep -Milliseconds 60
      [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
      Start-Sleep -Milliseconds 120
      [ordered]@{
        ok              = $true
        inputMode       = 'hardwareKeyboard'
        foregroundPid   = $fgPid
        foregroundTitle = [Win32Driver]::GetTitle($fg)
      } | ConvertTo-Json -Compress
    } else {
      $deadline = [DateTime]::UtcNow.AddMilliseconds(4000)
      $dlg = [IntPtr]::Zero
      $dlgPid = [uint32]0
      while ([DateTime]::UtcNow -lt $deadline) {
        foreach ($wh in [Win32Driver]::ListVisibleTopWindows()) {
          $wpid = [Win32Driver]::GetPid($wh)
          $title = [Win32Driver]::GetTitle($wh)
          if (($allowed -contains $wpid) -and $title.StartsWith('Annotate:')) {
            $dlg = $wh
            $dlgPid = $wpid
            break
          }
        }
        if ($dlg -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 50
      }
      if ($dlg -eq [IntPtr]::Zero) { throw "Timed out waiting for Annotate composer dialog in allowed=[$($allowed -join ',')]" }
      $editHwnd = [IntPtr]::Zero
      $sendHwnd = [IntPtr]::Zero
      foreach ($ch in [Win32Driver]::ListChildWindows($dlg)) {
        $cls = [Win32Driver]::GetClass($ch)
        $txt = [Win32Driver]::GetTitle($ch)
        if ($cls -like '*EDIT*' -and $editHwnd -eq [IntPtr]::Zero) { $editHwnd = $ch }
        if ($cls -like '*BUTTON*' -and $txt -eq 'Send') { $sendHwnd = $ch }
      }
      if ($editHwnd -eq [IntPtr]::Zero -or $sendHwnd -eq [IntPtr]::Zero) {
        throw "Composer dialog child controls not found (edit=$editHwnd send=$sendHwnd)"
      }
      [void][Win32Driver]::SendMessage($editHwnd, 0x000C, [IntPtr]::Zero, $Text)
      Start-Sleep -Milliseconds 40
      [void][Win32Driver]::PostMessage($sendHwnd, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 120
      [ordered]@{
        ok          = $true
        inputMode   = 'win32MessageFallback'
        dialogPid   = $dlgPid
        dialogTitle = [Win32Driver]::GetTitle($dlg)
      } | ConvertTo-Json -Compress
    }
  }

  'crop-screenshot' {
    if ([string]::IsNullOrWhiteSpace($OutPath)) { throw 'OutPath required' }
    $w = [Math]::Max(1, $Width)
    $h = [Math]::Max(1, $Height)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $mode = 'copyFromScreen'
    try {
      $g.CopyFromScreen($X, $Y, 0, 0, [System.Drawing.Size]::new($w, $h))
    } catch {
      $mode = 'printWindowComposite'
      $g.Clear([System.Drawing.Color]::FromArgb(241, 245, 249))
      $capPids = @()
      if (![string]::IsNullOrWhiteSpace($CapturePids)) {
        $capPids = @($CapturePids.Split(',') | ForEach-Object { [uint32]$_.Trim() } | Where-Object { $_ -gt 0 })
      }
      $all = [Win32Driver]::ListVisibleTopWindows()
      # EnumWindows returns top-to-bottom in Z-order; reverse to paint bottom-to-top.
      for ($idx = $all.Count - 1; $idx -ge 0; $idx--) {
        $wh = $all[$idx]
        $wpid = [Win32Driver]::GetPid($wh)
        if ($capPids.Count -gt 0 -and ($capPids -notcontains $wpid)) { continue }
        $wr = New-Object Win32Driver+RECT
        if (![Win32Driver]::GetWindowRect($wh, [ref]$wr)) { continue }
        $ww = $wr.Right - $wr.Left
        $whh = $wr.Bottom - $wr.Top
        if ($ww -le 0 -or $whh -le 0) { continue }
        $exStyle = [Win32Driver]::GetWindowLong($wh, -20)
        $pwFlags = if (($exStyle -band 0x20) -ne 0) { 0 } else { 2 }
        $wbmp = New-Object System.Drawing.Bitmap($ww, $whh)
        $wg = [System.Drawing.Graphics]::FromImage($wbmp)
        $hdc = $wg.GetHdc()
        [void][Win32Driver]::PrintWindow($wh, $hdc, $pwFlags)
        $wg.ReleaseHdc($hdc)
        $wg.Dispose()
        if (($exStyle -band 0x20) -ne 0) {
          $wbmp.MakeTransparent([System.Drawing.Color]::Lime)
        }
        $g.DrawImageUnscaled($wbmp, $wr.Left - $X, $wr.Top - $Y)
        $wbmp.Dispose()
      }
    }
    $dir = Split-Path -Parent $OutPath
    if ($dir -and !(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    [ordered]@{ ok = $true; mode = $mode; outPath = $OutPath; bounds = [ordered]@{ x = $X; y = $Y; width = $w; height = $h } } | ConvertTo-Json -Compress -Depth 4
  }
}
