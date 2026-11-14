# 量坐标的进程自己必须是 DPI 感知的,否则 GetWindowRect / WindowFromPoint 拿到的是
# 被系统按 96 DPI 虚拟化过的坐标(2026-11-14 实测:两个数差 1.5 倍,点击还会打到别的窗口)。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ProbeDpi {
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
if (![ProbeDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [ProbeDpi]::SetProcessDPIAware() | Out-Null }
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ClkNative {
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int hgt,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
 public static List<IntPtr> WindowsOf(uint pid) {
  var list=new List<IntPtr>();
  EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h,out p); if(p==pid){ var sb=new StringBuilder(256); GetClassName(h,sb,256); if(IsWindowVisible(h) && sb.ToString().StartsWith("WindowsForms10")) list.Add(h); } return true; }, IntPtr.Zero);
  return list;
 }
  public static uint PidOf(IntPtr h){ uint p; GetWindowThreadProcessId(h, out p); return p; }
}
"@
$adapter=(Resolve-Path 'packages/desktop-uia/adapter.ps1').Path
$overlay=(Resolve-Path 'packages/desktop-uia/overlay.ps1').Path
$out=(Resolve-Path 'acceptance/desktop-uia-2026-11-14').Path
$marker='uia-clk-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$file=Join-Path $env:TEMP ($marker+'.txt')
[IO.File]::WriteAllText($file,$marker)
$targetFile=Join-Path $out 'gaps-click-target.json'
function Windows { & powershell.exe -NoProfile -STA -File $adapter -Command list-windows | ConvertFrom-Json | ForEach-Object { $_ } }
function FindOwn { @(Windows | Where-Object { $_.title -like "*$marker*" }) | Select-Object -First 1 }
function ResolveOwn { & powershell.exe -NoProfile -STA -File $adapter -Command resolve -Target $targetFile | ConvertFrom-Json }
$orig=New-Object ClkNative+POINT; [void][ClkNative]::GetCursorPos([ref]$orig)
$result=[ordered]@{marker=$marker}
$np=$null; $ovProc=$null
try {
 Start-Process notepad.exe -ArgumentList ('"'+$file+'"') | Out-Null
 $w=$null; for($i=0;$i -lt 40 -and !$w;$i++){ Start-Sleep -Milliseconds 500; $w=FindOwn }
 if(!$w){ throw 'notepad not found' }
 $np=$w
 $hw=[IntPtr]$w.hwnd
 [void][ClkNative]::MoveWindow($hw,200,200,900,650,$true); Start-Sleep -Milliseconds 400
 # 提到最上层(TOPMOST),这样鼠标底下一定是它,而不是别人的窗口
 [void][ClkNative]::SetWindowPos($hw,[IntPtr](-1),200,200,900,650,0x0040)
 Start-Sleep -Milliseconds 800
 $nodes=@(& powershell.exe -NoProfile -STA -File $adapter -Command snapshot -Hwnd $w.hwnd | ConvertFrom-Json | ForEach-Object { $_ })
 $n=$nodes | Where-Object { $_.rect -and $_.automationId -and $_.ancestry.Count -gt 0 } | Select-Object -First 1
 if(!$n){ throw 'no target node' }
 $target=@{app=$w.process;appPath=$w.appPath;windowClass=$w.windowClass;windowTitle=$w.title;automationId=$n.automationId;controlType=$n.controlType;name=$n.name;ancestry=@($n.ancestry)}
 $target | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $targetFile

 $ovArgs=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$overlay+'"'),'-Targets',('"'+$targetFile+'"'))
 $ovProc = Start-Process powershell.exe -ArgumentList $ovArgs -PassThru -WindowStyle Hidden
 $ovH=$null
 for($i=0;$i -lt 60 -and !$ovH;$i++){ Start-Sleep -Milliseconds 500; $c=@([ClkNative]::WindowsOf([uint32]$ovProc.Id)); if($c.Count){ $ovH=$c[0] }; if($ovProc.HasExited){ break } }
 if(!$ovH){ throw 'overlay window not found' }
 Start-Sleep -Milliseconds 1000
 $r0=ResolveOwn
 $ovRect=New-Object ClkNative+RECT; [void][ClkNative]::GetWindowRect($ovH,[ref]$ovRect)
 $ex=[ClkNative]::GetWindowLong($ovH,-20)
 $npPid=[ClkNative]::PidOf($hw)
 $cx=[int]($r0.rect.left + $r0.rect.width/2); $cy=[int]($r0.rect.top + $r0.rect.height/2)
 $p=New-Object ClkNative+POINT; $p.X=$cx; $p.Y=$cy
 $hit=[ClkNative]::WindowFromPoint($p)
 $hitPid=[ClkNative]::PidOf($hit)
 $result.target=$r0.rect
 $result.overlayWindow=@{left=$ovRect.Left;top=$ovRect.Top;width=($ovRect.Right-$ovRect.Left);height=($ovRect.Bottom-$ovRect.Top);exStyle=('0x{0:X}' -f $ex);visible=[ClkNative]::IsWindowVisible($ovH)}
 $result.hitTest=@{clickPoint=@{x=$cx;y=$cy};insideOverlay=($cx -ge $ovRect.Left -and $cx -lt $ovRect.Right -and $cy -ge $ovRect.Top -and $cy -lt $ovRect.Bottom);hitHwnd=[int64]$hit;hitIsOverlay=($hit -eq $ovH);hitPid=$hitPid;notepadPid=$npPid;hitIsNotepad=($hitPid -eq $npPid)}
 if($hitPid -ne $npPid -or $hit -eq $ovH){
   $result.click=@{skipped=$true;reason="hit test did not land on our notepad (hitPid=$hitPid notepadPid=$npPid)"}
 } else {
   [void][ClkNative]::SetCursorPos($cx,$cy); Start-Sleep -Milliseconds 400
   $fgBefore=[ClkNative]::GetForegroundWindow()
   [ClkNative]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero); [ClkNative]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
   Start-Sleep -Milliseconds 700
   $fgAfter=[ClkNative]::GetForegroundWindow()
   $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
   $focusPid=0; $focusType=''; $focusName=''
   try { $focusPid=$focused.Current.ProcessId; $focusType=$focused.Current.ControlType.ProgrammaticName; $focusName=$focused.Current.Name } catch {}
   $result.click=@{
     skipped=$false
     foregroundBefore=[int64]$fgBefore
     foregroundAfter=[int64]$fgAfter
     foregroundIsNotepad=($fgAfter -eq $hw)
     overlayBecameForeground=($fgAfter -eq $ovH)
     overlayStillVisible=[ClkNative]::IsWindowVisible($ovH)
     focusPid=$focusPid
     focusControlType=$focusType
     focusName=$focusName
     focusInNotepad=($focusPid -eq $npPid)
   }
 }
} finally {
 try { if($ovProc -and !$ovProc.HasExited){ Stop-Process -Id $ovProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
 try { if($np){ $e=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$np.hwnd); $e.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } } catch {}
 Start-Sleep -Milliseconds 500
 try { Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$marker*" } | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
 [void][ClkNative]::SetCursorPos($orig.X,$orig.Y)
 Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
}
$result | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $out 'gaps-click.json')
'click done'
