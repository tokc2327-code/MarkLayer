$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class GapNative {
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int hgt,bool repaint);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
}
"@
$adapter=(Resolve-Path 'packages/desktop-uia/adapter.ps1').Path
$out=(Resolve-Path 'acceptance/desktop-uia-2026-11-14').Path
$marker='uia-gap-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$file=Join-Path $env:TEMP ($marker+'.txt')
[IO.File]::WriteAllText($file,$marker)
$targetFile=Join-Path $out 'gaps-target.json'
$handles=New-Object System.Collections.ArrayList
function Windows { & powershell.exe -NoProfile -STA -File $adapter -Command list-windows | ConvertFrom-Json | ForEach-Object { $_ } }
function FindOwn { @(Windows | Where-Object { $_.title -like "*$marker*" }) | Select-Object -First 1 }
function StartOwn {
 Start-Process notepad.exe -ArgumentList ('"'+$file+'"') | Out-Null
 $w=$null; for($i=0;$i -lt 30 -and !$w;$i++){ Start-Sleep -Milliseconds 500; $w=FindOwn }
 if(!$w){throw 'own notepad window not found'}
 [void]$handles.Add($w.hwnd); return $w
}
function ResolveOwn { & powershell.exe -NoProfile -STA -File $adapter -Command resolve -Target $targetFile | ConvertFrom-Json }
function CloseOwn($w) { if($w) { try { $e=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd); $e.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch {} } }
try {
 $w=StartOwn
 $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd)
 $pid1=$root.Current.ProcessId
 $nodes=@(& powershell.exe -NoProfile -STA -File $adapter -Command snapshot -Hwnd $w.hwnd | ConvertFrom-Json | ForEach-Object { $_ })
 $n=$nodes | Where-Object { $_.rect -and $_.automationId -and $_.ancestry.Count -gt 0 } | Select-Object -First 1
 if(!$n){throw 'no target node'}
 $target=@{app=$w.process;appPath=$w.appPath;windowClass=$w.windowClass;windowTitle=$w.title;automationId=$n.automationId;controlType=$n.controlType;name=$n.name;ancestry=@($n.ancestry)}
 $target | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $targetFile
 $initial=ResolveOwn
 [void][GapNative]::ShowWindow([IntPtr]$w.hwnd,6); Start-Sleep -Milliseconds 500
 $min=ResolveOwn
 [void][GapNative]::ShowWindow([IntPtr]$w.hwnd,9); Start-Sleep -Milliseconds 500
 $restored=ResolveOwn
 [void][GapNative]::MoveWindow([IntPtr]$w.hwnd,-100,-100,900,650,$true); Start-Sleep -Milliseconds 500
 $negative=ResolveOwn
 $v=[Windows.Forms.SystemInformation]::VirtualScreen
 [void][GapNative]::MoveWindow([IntPtr]$w.hwnd,($v.Right-200),($v.Bottom-200),900,650,$true); Start-Sleep -Milliseconds 500
 $edge=ResolveOwn
 $dpi=[GapNative]::GetDpiForWindow([IntPtr]$w.hwnd)
 CloseOwn $w; Start-Sleep -Seconds 2; $w=$null
 $w=StartOwn; $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd); $pid2=$root.Current.ProcessId
 $restarted=ResolveOwn
 @{marker=$marker;initial=$initial;minimized=$min;restored=$restored;negative=$negative;edge=$edge;restart=$restarted;pid1=$pid1;pid2=$pid2;dpi=$dpi;virtualScreen=@{left=$v.Left;top=$v.Top;right=$v.Right;bottom=$v.Bottom}} | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $out 'gaps-observations.json')
} finally {
 CloseOwn $w
 Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
}
