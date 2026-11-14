param([Parameter(Mandatory=$true)][string]$Targets)
$ErrorActionPreference='Stop'
# 必须排在加载 WinForms 之前:WinForms 一加载就按当时的 DPI 把窗口尺寸缓存住,
# 之后再设 DPI 感知,窗口会被系统按 96 DPI 缩成 1/1.5,红框又小又偏(2026-11-14 实测)。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class OverlayDpiEarly {
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
 [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr c);
}
"@
if (![OverlayDpiEarly]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [OverlayDpiEarly]::SetProcessDPIAware() | Out-Null }
if ([OverlayDpiEarly]::GetAwarenessFromDpiAwarenessContext([OverlayDpiEarly]::GetThreadDpiAwarenessContext()) -eq 0) { throw 'overlay is DPI-unaware: the red box would be drawn at 2/3 size' }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class PassthroughForm : Form {
 protected override bool ShowWithoutActivation { get { return true; } }
 protected override CreateParams CreateParams { get { var p=base.CreateParams; p.ExStyle |= 0x20 | 0x80 | 0x80000 | 0x08000000; return p; } }
}
public static class OverlayDpi {
 [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
 [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a,IntPtr b);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
}
"@
# PowerShell host may have initialized process DPI awareness before this script runs.
# Set the UI thread context before constructing forms, so SetBounds uses physical pixels.
if ([OverlayDpi]::SetThreadDpiAwarenessContext([IntPtr](-4)) -eq [IntPtr]::Zero -or ![OverlayDpi]::AreDpiAwarenessContextsEqual([OverlayDpi]::GetThreadDpiAwarenessContext(),[IntPtr](-4))) { throw 'Cannot set overlay thread to PerMonitorV2 DPI awareness' }
$items=Get-Content -Raw -Encoding UTF8 -LiteralPath $Targets | ConvertFrom-Json; $items=@($items)
$forms=@()
for ($i=0;$i -lt $items.Count;$i++) {
 $form=New-Object PassthroughForm
 $form.FormBorderStyle='None'; $form.ShowInTaskbar=$false; $form.TopMost=$true; $form.StartPosition='Manual'
 $form.BackColor=[Drawing.Color]::Lime; $form.TransparencyKey=[Drawing.Color]::Lime
 $form.Tag=($i+1).ToString()
 $form.add_Paint({param($s,$e) $pen=New-Object Drawing.Pen([Drawing.Color]::Red,4); $e.Graphics.DrawRectangle($pen,2,2,($s.ClientSize.Width-5),($s.ClientSize.Height-5)); $e.Graphics.DrawString($s.Tag,$s.Font,[Drawing.Brushes]::Red,3,3); $pen.Dispose()})
 $forms+= $form
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('desktop-uia-'+[guid]::NewGuid().ToString()+'.json')
try {
 while ($true) {
  for ($i=0;$i -lt $items.Count;$i++) {
   ConvertTo-Json -InputObject $items[$i] -Depth 30 | Set-Content -Encoding UTF8 -LiteralPath $temp
   try {
    $output=& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'adapter.ps1') -Command resolve -Target $temp
    $r=$output | ConvertFrom-Json
    $virtual=[Windows.Forms.SystemInformation]::VirtualScreen
    $visible=$r.rect -and ($r.rect.left + $r.rect.width -gt $virtual.Left) -and ($r.rect.top + $r.rect.height -gt $virtual.Top) -and ($r.rect.left -lt $virtual.Right) -and ($r.rect.top -lt $virtual.Bottom)
    if ($r.ok -and !$r.minimized -and $visible -and $r.rect.width -gt 5 -and $r.rect.height -gt 5) {
     $forms[$i].SetBounds([int]$r.rect.left,[int]$r.rect.top,[int]$r.rect.width,[int]$r.rect.height)
     if (!$forms[$i].Visible) { $forms[$i].Show() }
     # Clicking another topmost window can place it above this overlay without hiding it.
     [void][OverlayDpi]::SetWindowPos($forms[$i].Handle,[IntPtr](-1),0,0,0,0,0x13)

    } else { $forms[$i].Hide() }
   } catch { $forms[$i].Hide() }
  }
  [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
 }
} finally { foreach($form in $forms) { $form.Dispose() }; Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
