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
[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
 int IsWindowOnCurrentVirtualDesktop(IntPtr h, out int onCurrent);
 int GetWindowDesktopId(IntPtr h, out Guid id);
 int MoveWindowToDesktop(IntPtr h, ref Guid id);
}
[ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
public class VirtualDesktopManager {}
public static class OvNative {
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int hgt,bool repaint);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool attach);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h,bool altTab);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
 [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
 public static bool BringOwn(IntPtr target) {
  IntPtr fg=GetForegroundWindow(); uint pid; uint other=GetWindowThreadProcessId(fg,out pid); uint self=GetCurrentThreadId();
  uint targetThread=GetWindowThreadProcessId(target,out pid);
  bool attached=other!=0 && other!=self && AttachThreadInput(other,self,true);
  bool targetAttached=targetThread!=0 && targetThread!=self && targetThread!=other && AttachThreadInput(targetThread,self,true);
  try { return SetForegroundWindow(target); } finally { if(targetAttached) AttachThreadInput(targetThread,self,false); if(attached) AttachThreadInput(other,self,false); }
 }
 public static bool IsAbove(IntPtr a, IntPtr b) { for(IntPtr h=GetWindow(a,3); h!=IntPtr.Zero; h=GetWindow(h,2)) if(h==b) return true; return false; }
 public static int OnCurrent(IntPtr h) { int onCurrent; ((IVirtualDesktopManager)new VirtualDesktopManager()).IsWindowOnCurrentVirtualDesktop(h,out onCurrent); return onCurrent; }
 public static List<IntPtr> WindowsOf(uint pid) {
  var list=new List<IntPtr>();
  EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h,out p); if(p==pid){ var sb=new StringBuilder(256); GetClassName(h,sb,256); if(IsWindowVisible(h) && sb.ToString().StartsWith("WindowsForms10")) list.Add(h); } return true; }, IntPtr.Zero);
  return list;
 }
}
"@
if ([OvNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) -eq [IntPtr]::Zero) { throw 'Cannot set acceptance thread to PerMonitorV2' }
$adapter=(Resolve-Path 'packages/desktop-uia/adapter.ps1').Path
$overlay=(Resolve-Path 'packages/desktop-uia/overlay.ps1').Path
$out=(Resolve-Path 'acceptance/desktop-uia-2026-11-14').Path
$marker='uia-ov-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$file=Join-Path $env:TEMP ($marker+'.txt')
[IO.File]::WriteAllText($file,$marker)
$targetFile=Join-Path $out 'gaps-overlay-target.json'
function Windows { & powershell.exe -NoProfile -STA -File $adapter -Command list-windows | ConvertFrom-Json | ForEach-Object { $_ } }
function FindOwn { @(Windows | Where-Object { $_.title -like "*$marker*" }) | Select-Object -First 1 }
function ResolveOwn { & powershell.exe -NoProfile -STA -File $adapter -Command resolve -Target $targetFile | ConvertFrom-Json }
$orig=New-Object OvNative+POINT; [void][OvNative]::GetCursorPos([ref]$orig)
$result=[ordered]@{marker=$marker}
$np=$null
$ovProc=$null
try {
 Start-Process notepad.exe -ArgumentList ('"'+$file+'"') | Out-Null
 $w=$null; for($i=0;$i -lt 40 -and !$w;$i++){ Start-Sleep -Milliseconds 500; $w=FindOwn }
 if(!$w){ throw 'notepad not found' }
 $np=$w
 [void][OvNative]::ShowWindow([IntPtr]$w.hwnd,9)
 [void][OvNative]::MoveWindow([IntPtr]$w.hwnd,120,120,900,650,$true); Start-Sleep -Milliseconds 600
 $foregroundSet=[OvNative]::BringOwn([IntPtr]$w.hwnd); Start-Sleep -Milliseconds 500
 $initialForeground=[OvNative]::GetForegroundWindow()
 $result.initialForeground=@{requested=$foregroundSet;hwnd=[int64]$initialForeground;notepadHwnd=[int64]$w.hwnd;confirmed=($initialForeground -eq [IntPtr]$w.hwnd)}
 $nodes=@(& powershell.exe -NoProfile -STA -File $adapter -Command snapshot -Hwnd $w.hwnd | ConvertFrom-Json | ForEach-Object { $_ })
 $n=$nodes | Where-Object { $_.rect -and $_.automationId -and $_.ancestry.Count -gt 0 } | Select-Object -First 1
 if(!$n){ throw 'no target node' }
 $target=@{app=$w.process;appPath=$w.appPath;windowClass=$w.windowClass;windowTitle=$w.title;automationId=$n.automationId;controlType=$n.controlType;name=$n.name;ancestry=@($n.ancestry)}
 $target | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $targetFile

 $topResult=[OvNative]::SetWindowPos([IntPtr]$w.hwnd,[IntPtr](-1),0,0,0,0,0x13)
 $ovArgs=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$overlay+'"'),'-Targets',('"'+$targetFile+'"'))
 $ovProc = Start-Process powershell.exe -ArgumentList $ovArgs -PassThru -WindowStyle Hidden
 $ovH=$null
 for($i=0;$i -lt 40 -and !$ovH;$i++){ Start-Sleep -Milliseconds 250; $c=@([OvNative]::WindowsOf([uint32]$ovProc.Id)); if($c.Count){ $ovH=$c[0] } }
 if(!$ovH){ throw 'overlay window not found' }
 Start-Sleep -Milliseconds 800
 $r0=ResolveOwn
 $ovRect=New-Object OvNative+RECT; [void][OvNative]::GetWindowRect($ovH,[ref]$ovRect)
 $result.overlayWindow=@{visible=[OvNative]::IsWindowVisible($ovH);left=$ovRect.Left;top=$ovRect.Top;width=($ovRect.Right-$ovRect.Left);height=($ovRect.Bottom-$ovRect.Top)}
 $result.targetFirst=$r0.rect

 $cx=[int]($r0.rect.left + $r0.rect.width/2); $cy=[int]($r0.rect.top + $r0.rect.height/2)
 $p=New-Object OvNative+POINT; $p.X=$cx; $p.Y=$cy
 if (!($cx -ge $ovRect.Left -and $cx -lt $ovRect.Right -and $cy -ge $ovRect.Top -and $cy -lt $ovRect.Bottom)) { throw 'Click point is outside overlay; refusing click' }
 $hitBefore=[OvNative]::WindowFromPoint($p)
 $hitPid=[uint32]0; [void][OvNative]::GetWindowThreadProcessId($hitBefore,[ref]$hitPid)
 $npPid=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd).Current.ProcessId
 $firstHit=[int64]$hitBefore; $firstHitPid=$hitPid
 if ($hitPid -ne $npPid) {
  [void][OvNative]::BringOwn([IntPtr]$w.hwnd); Start-Sleep -Milliseconds 500
  $hitBefore=[OvNative]::WindowFromPoint($p)
  $hitPid=[uint32]0; [void][OvNative]::GetWindowThreadProcessId($hitBefore,[ref]$hitPid)
 }
 $relocated=$false
 if ($hitPid -ne $npPid -or [OvNative]::GetForegroundWindow() -ne [IntPtr]$w.hwnd) {
  $screen=[Windows.Forms.SystemInformation]::VirtualScreen
  [void][OvNative]::MoveWindow([IntPtr]$w.hwnd,($screen.Right-1000),($screen.Bottom-750),900,650,$true)
  $relocated=$true; [void][OvNative]::BringOwn([IntPtr]$w.hwnd); Start-Sleep -Seconds 3
  $r0=ResolveOwn
  $ovRect=New-Object OvNative+RECT; [void][OvNative]::GetWindowRect($ovH,[ref]$ovRect)
  $cx=[int]($r0.rect.left+$r0.rect.width/2); $cy=[int]($r0.rect.top+$r0.rect.height/2); $p.X=$cx; $p.Y=$cy
  $hitBefore=[OvNative]::WindowFromPoint($p)
  $hitPid=[uint32]0; [void][OvNative]::GetWindowThreadProcessId($hitBefore,[ref]$hitPid)
 }
 $result.notepadOnCurrentDesktop=[OvNative]::OnCurrent([IntPtr]$w.hwnd)
 $fgBefore=[OvNative]::GetForegroundWindow()
 $aboveBefore=[OvNative]::IsAbove($ovH,[IntPtr]$w.hwnd)
 $safeToClick=($fgBefore -eq [IntPtr]$w.hwnd -and $hitPid -eq $npPid -and $aboveBefore -and $cx -ge $ovRect.Left -and $cx -lt $ovRect.Right -and $cy -ge $ovRect.Top -and $cy -lt $ovRect.Bottom)
 if ($safeToClick) {
  [void][OvNative]::SetCursorPos($cx,$cy); Start-Sleep -Milliseconds 200
  $hitBefore=[OvNative]::WindowFromPoint($p)
  $hitPid=[uint32]0; [void][OvNative]::GetWindowThreadProcessId($hitBefore,[ref]$hitPid)
  $fgBefore=[OvNative]::GetForegroundWindow()
  $safeToClick=($hitPid -eq $npPid -and $fgBefore -eq [IntPtr]$w.hwnd -and [OvNative]::IsAbove($ovH,[IntPtr]$w.hwnd))
  if ($safeToClick) { [OvNative]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero); [OvNative]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero) }
 }
 Start-Sleep -Milliseconds 700
 $fgAfter=[OvNative]::GetForegroundWindow()
 $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
 $focusPid=0; $focusType=$null; try { $focusPid=$focused.Current.ProcessId; $focusType=$focused.Current.ControlType.ProgrammaticName } catch {}
 $npPid=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd).Current.ProcessId
 $result.clickThrough=@{
   outcome=$(if ($safeToClick) {'clicked'} else {'abandoned'})
   clicked=$safeToClick
   relocated=$relocated
   focusControlType=$focusType
   firstHitHwnd=$firstHit; firstHitPid=$firstHitPid
   overlayAboveNotepadBefore=$aboveBefore
   overlayAboveNotepadAfter=[OvNative]::IsAbove($ovH,[IntPtr]$w.hwnd)
   clickPoint=@{x=$cx;y=$cy}
   insideOverlay=($cx -ge $ovRect.Left -and $cx -lt $ovRect.Right -and $cy -ge $ovRect.Top -and $cy -lt $ovRect.Bottom)
   windowFromPoint_isOverlay=($hitBefore -eq $ovH)
   windowFromPoint_hwnd=[int64]$hitBefore
   windowFromPoint_pid=$hitPid
   npHwnd=[int64]$w.hwnd
   foregroundBefore=[int64]$fgBefore
   foregroundAfter=[int64]$fgAfter
   foregroundIsNotepad=($fgAfter -eq [IntPtr]$w.hwnd)
   overlayStillVisible=[OvNative]::IsWindowVisible($ovH)
   overlayBecameForeground=($fgAfter -eq $ovH)
   focusPid=$focusPid
   notepadPid=$npPid
   focusInNotepad=($focusPid -eq $npPid)
 }

 $steps=New-Object System.Collections.ArrayList
 $x=120; $y=120
 for($i=0;$i -lt 30;$i++){
   $x+=10; $y+=5
   $timer=[Diagnostics.Stopwatch]::StartNew()
   [void][OvNative]::MoveWindow([IntPtr]$w.hwnd,$x,$y,900,650,$true)
   Start-Sleep -Milliseconds 120
   $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd)
   $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$n.automationId)
   $element=$root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
   $tr=$element.Current.BoundingRectangle
   $rr=@{rect=@{left=$tr.Left;top=$tr.Top;width=$tr.Width;height=$tr.Height}}
   $or=New-Object OvNative+RECT; [void][OvNative]::GetWindowRect($ovH,[ref]$or)
   $ms=$timer.ElapsedMilliseconds
   if($rr.rect){
     $dx=[Math]::Abs(($or.Left)-$rr.rect.left); $dy=[Math]::Abs(($or.Top)-$rr.rect.top)
     [void]$steps.Add(@{step=$i;dx=$dx;dy=$dy;targetLeft=$rr.rect.left;targetTop=$rr.rect.top;overlayLeft=$or.Left;overlayTop=$or.Top;visible=[OvNative]::IsWindowVisible($ovH);ms=$ms})
   } else { [void]$steps.Add(@{step=$i;dx=$null;dy=$null;visible=[OvNative]::IsWindowVisible($ovH);ms=$ms;note='no rect'}) }
 }
 $settled=@()
 foreach($wait in @(500,1500)) {
   if ($wait -eq 500) { Start-Sleep -Milliseconds 500 } else { Start-Sleep -Milliseconds 1000 }
   $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.hwnd)
   $tr=$root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition).Current.BoundingRectangle
   $or=New-Object OvNative+RECT; [void][OvNative]::GetWindowRect($ovH,[ref]$or)
   $settled+=@{waitMs=$wait;targetLeft=$tr.Left;targetTop=$tr.Top;overlayLeft=$or.Left;overlayTop=$or.Top;dx=[Math]::Abs($or.Left-$tr.Left);dy=[Math]::Abs($or.Top-$tr.Top);visible=[OvNative]::IsWindowVisible($ovH)}
 }
 $deltas=@($steps | Where-Object { $_['dx'] -ne $null } | ForEach-Object { [Math]::Max($_['dx'],$_['dy']) })
 $result.drag=@{
   settled=$settled
   steps=@($steps)
   maxOffset=($deltas | Measure-Object -Maximum).Maximum
   avgOffset=[Math]::Round((($deltas | Measure-Object -Average).Average),2)
   hiddenFrames=@($steps | Where-Object { -not $_['visible'] }).Count
   maxSampleMs=(($steps | ForEach-Object { $_['ms'] }) | Measure-Object -Maximum).Maximum
 }
} finally {
 try { if($ovProc -and !$ovProc.HasExited){ Stop-Process -Id $ovProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
 try { if($np){ $e=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$np.hwnd); $e.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } } catch {}
 Start-Sleep -Milliseconds 500
 try { Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$marker*" } | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
 [void][OvNative]::SetCursorPos($orig.X,$orig.Y)
 Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
}
$result | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $out 'gaps-overlay.json')
'overlay done'
