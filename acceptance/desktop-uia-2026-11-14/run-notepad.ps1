$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class NpNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int hgt,bool repaint);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  public static IntPtr FindByTitle(string contains) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h,l)=> {
      if (!IsWindowVisible(h)) return true;
      StringBuilder sb = new StringBuilder(512);
      GetWindowTextW(h, sb, 512);
      if (sb.ToString().Contains(contains)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
[NpNative]::SetProcessDPIAware() | Out-Null

$out = (Resolve-Path 'acceptance/desktop-uia-2026-11-14').Path
$adapter = (Resolve-Path 'packages/desktop-uia/adapter.ps1').Path
function SaveJson($obj, $file) { ConvertTo-Json -InputObject $obj -Depth 50 | Set-Content -Encoding UTF8 (Join-Path $out $file) }
function ResolveTarget($file) { (& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $adapter -Command resolve -Target (Join-Path $out $file) | ConvertFrom-Json) }
function Crop($r, $file) {
  $bmp = New-Object Drawing.Bitmap ([int]$r.width + 60), ([int]$r.height + 60)
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen([int]$r.left - 30, [int]$r.top - 30, 0, 0, $bmp.Size)
  $bmp.Save((Join-Path $out $file), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}

$stamp = [guid]::NewGuid().ToString().Substring(0, 8)
$noteFile = Join-Path $env:TEMP ("uia-notepad-$stamp.txt")
[IO.File]::WriteAllText($noteFile, "Desktop UIA notepad acceptance $stamp")
$marker = "uia-notepad-$stamp"

$proc = Start-Process notepad.exe -ArgumentList ('"' + $noteFile + '"') -PassThru

$h = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(25)
do {
  Start-Sleep -Milliseconds 500
  $h = [NpNative]::FindByTitle($marker)
} while ($h -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
if ($h -eq [IntPtr]::Zero) { throw "notepad window for '$marker' not found" }

[NpNative]::ShowWindow($h, 9) | Out-Null
[NpNative]::MoveWindow($h, 300, 200, 1000, 700, $true) | Out-Null
[NpNative]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Seconds 2

$root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$snapshot = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $adapter -Command snapshot -Hwnd $h | ConvertFrom-Json
SaveJson $snapshot 'notepad-snapshot.json'

$node = $snapshot | Where-Object { $_.rect -and $_.automationId -and $_.rect.width -gt 20 -and $_.ancestry.Count -gt 0 -and ($_.controlType -in @('ControlType.Button','ControlType.MenuItem','ControlType.TabItem')) } | Select-Object -First 1
if (!$node) {
  $node = $snapshot | Where-Object { $_.rect -and $_.rect.width -gt 20 -and $_.ancestry.Count -gt 0 } | Select-Object -First 1
}
if (!$node) { throw 'no usable control node in notepad snapshot' }

$dpi = [NpNative]::GetDpiForWindow($h) / 96.0
$screen = [Windows.Forms.Screen]::FromHandle($h)
$target = @{
  kind = 'windows-uia'
  app = 'Notepad'
  windowTitle = $root.Current.Name
  automationId = $node.automationId
  controlType = $node.controlType
  name = $node.name
  ancestry = @($node.ancestry)
  captured = @{ left = $node.rect.left; top = $node.rect.top; width = $node.rect.width; height = $node.rect.height; dpr = $dpi }
  screen = @{ width = $screen.Bounds.Width / $dpi; height = $screen.Bounds.Height / $dpi; scale = $dpi }
}
SaveJson $target 'notepad-target.json'

$initial = ResolveTarget 'notepad-target.json'
[NpNative]::MoveWindow($h, 500, 300, 1000, 700, $true) | Out-Null
Start-Sleep -Seconds 3
$moved = ResolveTarget 'notepad-target.json'
[NpNative]::MoveWindow($h, 500, 300, 1200, 850, $true) | Out-Null
Start-Sleep -Seconds 3
$resized = ResolveTarget 'notepad-target.json'
if ($resized.ok) { Crop $resized.rect 'notepad-resized.png' }

SaveJson @{ pid = $proc.Id; hwnd = [long]$h; snapshotRect = $node.rect; initial = $initial; moved = $moved; resized = $resized } 'notepad-observations.json'

# 只关自己开的这个窗口
$root.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
Start-Sleep -Seconds 2
Remove-Item -LiteralPath $noteFile -ErrorAction SilentlyContinue
'notepad done'
