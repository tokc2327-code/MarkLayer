$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AcceptNative {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int hgt,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 public static IntPtr OwnedWindow(uint pid) { IntPtr result=IntPtr.Zero; EnumWindows((h,l)=> { uint p; GetWindowThreadProcessId(h,out p); if (p==pid && IsWindowVisible(h)) { result=h; return false; } return true; },IntPtr.Zero); return result; }
}
"@
[AcceptNative]::SetProcessDPIAware() | Out-Null
$out=(Resolve-Path 'acceptance/desktop-uia-2026-11-14').Path
$adapter=(Resolve-Path 'packages/desktop-uia/adapter.ps1').Path
$overlay=(Resolve-Path 'packages/desktop-uia/overlay.ps1').Path
function SaveJson($obj,$file) { ConvertTo-Json -InputObject $obj -Depth 50 | Set-Content -Encoding UTF8 (Join-Path $out $file) }
function ResolveTarget($file) { (& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $adapter -Command resolve -Target (Join-Path $out $file) | ConvertFrom-Json) }
function Crop($r,$file) {
 $bmp=New-Object Drawing.Bitmap ([int]$r.width+60),([int]$r.height+60)
 $g=[Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen([int]$r.left-30,[int]$r.top-30,0,0,$bmp.Size)
 $bmp.Save((Join-Path $out $file),[Drawing.Imaging.ImageFormat]::Png); $g.Dispose();$bmp.Dispose()
}
function StartOwned($exe) {
 if ($exe -eq 'notepad.exe') {
  $script:noteFile=Join-Path $env:TEMP ('desktop-uia-'+[guid]::NewGuid()+'.txt')
  [IO.File]::WriteAllText($script:noteFile,'Desktop UIA test')
  $p=Start-Process $exe -ArgumentList ('"'+$script:noteFile+'"') -PassThru
 } else { $p=Start-Process $exe -PassThru }
 $script:started+= $p
 $deadline=(Get-Date).AddSeconds(15)
 do { Start-Sleep -Milliseconds 500; $p.Refresh(); $h=[AcceptNative]::OwnedWindow([uint32]$p.Id) } while (!$p.HasExited -and $h -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
 if ($p.HasExited -or $h -eq [IntPtr]::Zero) { throw "No owned window for started PID $($p.Id)" }
 return @{process=$p;hwnd=$h}
}
$started=@(); $op=$null
try {
 foreach($app in @('mspaint','notepad')) {
  $owned=StartOwned "$app.exe"; $p=$owned.process; $h=$owned.hwnd
  [AcceptNative]::ShowWindow($h,9) | Out-Null
  [AcceptNative]::MoveWindow($h,100,100,1000,700,$true) | Out-Null
  [AcceptNative]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Seconds 2
  $root=[System.Windows.Automation.AutomationElement]::FromHandle($h)
  $snapshot=& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $adapter -Command snapshot -Hwnd $h | ConvertFrom-Json
  SaveJson $snapshot "$app-snapshot.json"
  $node=$snapshot | Where-Object { $_.controlType -eq 'ControlType.Button' -and $_.rect -and $_.automationId -and $_.ancestry.Count -gt 0 -and $_.rect.width -gt 20 } | Select-Object -First 1
  if (!$node) { throw "No button: $app" }
  $dpi=[AcceptNative]::GetDpiForWindow($h)/96.0
  $screen=[Windows.Forms.Screen]::FromHandle($h)
  $target=@{kind='windows-uia';app=$p.ProcessName;windowTitle=$root.Current.Name;automationId=$node.automationId;controlType=$node.controlType;name=$node.name;ancestry=@($node.ancestry);captured=@{left=$node.rect.left;top=$node.rect.top;width=$node.rect.width;height=$node.rect.height;dpr=$dpi};screen=@{width=$screen.Bounds.Width/$dpi;height=$screen.Bounds.Height/$dpi;scale=$dpi}}
  SaveJson $target "$app-target.json"
  $initial=ResolveTarget "$app-target.json"
  if ($app -eq 'mspaint') {
   SaveJson @($target) 'overlay-targets.json'
   $op=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$overlay+'"'),'-Targets',('"'+(Join-Path $out 'overlay-targets.json')+'"'))
   Start-Sleep -Seconds 4
  }
  [AcceptNative]::MoveWindow($h,300,200,1000,700,$true) | Out-Null; Start-Sleep -Seconds 4
  $moved=ResolveTarget "$app-target.json"
  if ($app -eq 'mspaint' -and $moved.ok) { Crop $moved.rect 'paint-moved.png' }
  [AcceptNative]::MoveWindow($h,300,200,1200,850,$true) | Out-Null; Start-Sleep -Seconds 4
  $resized=ResolveTarget "$app-target.json"
  if ($app -eq 'mspaint' -and $resized.ok) { Crop $resized.rect 'paint-resized.png' }
  SaveJson @{pid=$p.Id;hwnd=[long]$h;snapshotRect=$node.rect;initial=$initial;moved=$moved;resized=$resized} "$app-observations.json"
  if ($app -eq 'mspaint') {
   $visibleBefore=([AcceptNative]::OwnedWindow([uint32]$op.Id) -ne [IntPtr]::Zero)
   $p.CloseMainWindow() | Out-Null; $p.WaitForExit(10000) | Out-Null
   Start-Sleep -Seconds 4
   $visibleAfter=([AcceptNative]::OwnedWindow([uint32]$op.Id) -ne [IntPtr]::Zero)
   SaveJson @{visibleBeforeClose=$visibleBefore;visibleAfterClose=$visibleAfter;overlayExited=$op.HasExited} 'overlay-disappearance.json'
   if ($op -and !$op.HasExited) { Stop-Process -Id $op.Id; $op=$null }
   $owned2=StartOwned 'mspaint.exe'; $p2=$owned2.process; Start-Sleep -Seconds 2
   $reopened=ResolveTarget "$app-target.json"; SaveJson @{oldHwnd=[long]$h;newHwnd=[long]$owned2.hwnd;result=$reopened} 'paint-reopened.json'
  }
 }
} finally {
 if ($op -and !$op.HasExited) { Stop-Process -Id $op.Id }
 foreach($p in $started) { $p.Refresh(); if (!$p.HasExited) { $h=[AcceptNative]::OwnedWindow([uint32]$p.Id); if ($h -ne [IntPtr]::Zero) { $p.CloseMainWindow() | Out-Null } else { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue } } }
 if ($noteFile) { Remove-Item -LiteralPath $noteFile -ErrorAction SilentlyContinue }
}
