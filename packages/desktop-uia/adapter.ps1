param([Parameter(Mandatory=$true)][ValidateSet('list-windows','snapshot','resolve')][string]$Command, [long]$Hwnd, [string]$Target)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DesktopDpi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder name, int max);
}
"@
try { if (![DesktopDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [DesktopDpi]::SetProcessDPIAware() | Out-Null } } catch { [DesktopDpi]::SetProcessDPIAware() | Out-Null }
$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
function Rect($r) {
 if ($r.IsEmpty) { return $null }
 return @{left=$r.X;top=$r.Y;width=$r.Width;height=$r.Height}
}
function Identity($e) {
 $c=$e.Current
 return @{controlType=$c.ControlType.ProgrammaticName;name=$c.Name;automationId=$c.AutomationId}
}
function Windows {
 $root=[System.Windows.Automation.AutomationElement]::RootElement
 foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)) {
  try {
   $c=$e.Current
   if ($c.NativeWindowHandle -eq 0 -or !$c.Name) { continue }
   $p=Get-Process -Id $c.ProcessId -ErrorAction Stop
   $class=New-Object System.Text.StringBuilder 256
   [void][DesktopDpi]::GetClassName([IntPtr]$c.NativeWindowHandle,$class,$class.Capacity)
   $path=$null; try { $path=$p.Path } catch { }
   [pscustomobject]@{element=$e;hwnd=$c.NativeWindowHandle;title=$c.Name;process=$p.ProcessName;appPath=$path;windowClass=$class.ToString();minimized=[DesktopDpi]::IsIconic([IntPtr]$c.NativeWindowHandle);rect=(Rect $c.BoundingRectangle)}
  } catch { }
 }
}
function PathTo($node,$root) {
 $parts=New-Object System.Collections.ArrayList
 $cur=$walker.GetParent($node)
 while ($cur) {
  [void]$parts.Insert(0,(Identity $cur))
  if ([System.Windows.Automation.Automation]::Compare($cur,$root)) { return ,@($parts.ToArray()) }
  $cur=$walker.GetParent($cur)
 }
 return $null
}
function SamePath($a,$b) {
 if ($null -eq $a -or @($a).Count -ne @($b).Count) { return $false }
 for($i=0;$i -lt @($a).Count;$i++) {
  foreach($key in @('controlType','name','automationId')) { if ($a[$i].$key -cne $b[$i].$key) { return $false } }
 }
 return $true
}
if ($Command -eq 'list-windows') {
 $result=@(Windows | ForEach-Object { @{hwnd=$_.hwnd;title=$_.title;process=$_.process;appPath=$_.appPath;windowClass=$_.windowClass;minimized=$_.minimized;rect=$_.rect} })
 ConvertTo-Json -InputObject $result -Depth 12
} elseif ($Command -eq 'snapshot') {
 $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
 if (!$root) { throw 'Window not found' }
 $nodes=@($root)+@($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_ })
 $items=@(foreach ($node in $nodes) {
  try {
   $c=$node.Current; $parent=$walker.GetParent($node)
   @{runtimeId=($node.GetRuntimeId() -join '.');parentRuntimeId=$(if ($parent) { $parent.GetRuntimeId() -join '.' } else { $null });controlType=$c.ControlType.ProgrammaticName;name=$c.Name;automationId=$c.AutomationId;rect=(Rect $c.BoundingRectangle);enabled=$c.IsEnabled;keyboardFocusable=$c.IsKeyboardFocusable;ancestry=$(if ($node -eq $root) { @() } else { PathTo $node $root })}
  } catch { }
 })
 ConvertTo-Json -InputObject $items -Depth 30
} else {
 $t=Get-Content -LiteralPath $Target -Raw -Encoding UTF8 | ConvertFrom-Json
 $windows=@(Windows | Where-Object { $_.process -ieq $t.app })
 if (!$windows.Count) { @{ok=$false;reason='app_not_found'} | ConvertTo-Json; exit }
 if ($t.appPath) { $windows=@($windows | Where-Object { $_.appPath -and $_.appPath -ieq $t.appPath }); if (!$windows.Count) { @{ok=$false;reason='app_path_not_found'} | ConvertTo-Json; exit } }
 if ($t.windowClass) { $windows=@($windows | Where-Object { $_.windowClass -ceq $t.windowClass }); if (!$windows.Count) { @{ok=$false;reason='window_class_not_found'} | ConvertTo-Json; exit } }
 $windows=@($windows | Where-Object { $_.title -ceq $t.windowTitle })
 if (!$windows.Count) { @{ok=$false;reason='window_title_not_found'} | ConvertTo-Json; exit }
 if ($windows.Count -eq 1 -and $windows[0].minimized) { @{ok=$true;minimized=$true;hwnd=$windows[0].hwnd;rect=$null} | ConvertTo-Json; exit }
 $matches=@(foreach ($w in $windows) {
  $nodes=@($w.element)+@($w.element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_ })
  foreach ($node in $nodes) {
   try {
    $c=$node.Current
    if ($c.AutomationId -cne $t.automationId -or $c.ControlType.ProgrammaticName -cne $t.controlType -or $c.Name -cne $t.name) { continue }
    $path=if ([System.Windows.Automation.Automation]::Compare($node,$w.element)) { @() } else { PathTo $node $w.element }
    if ((SamePath $path $t.ancestry) -and !$c.BoundingRectangle.IsEmpty) { @{hwnd=$w.hwnd;rect=(Rect $c.BoundingRectangle)} }
   } catch { }
  }
 })
 if ($matches.Count -eq 0) { @{ok=$false;reason='not_found'} | ConvertTo-Json }
 elseif ($matches.Count -gt 1) { @{ok=$false;reason="ambiguous:$($matches.Count)"} | ConvertTo-Json }
 else { @{ok=$true;minimized=$false;hwnd=$matches[0].hwnd;rect=$matches[0].rect} | ConvertTo-Json -Depth 10 }
}
