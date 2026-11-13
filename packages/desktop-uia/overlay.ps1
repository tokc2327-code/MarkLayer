param([Parameter(Mandatory=$true)][string]$Targets)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class PassthroughForm : Form {
 protected override CreateParams CreateParams { get { var p=base.CreateParams; p.ExStyle |= 0x20 | 0x80 | 0x08000000; return p; } }
}
public static class OverlayDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[OverlayDpi]::SetProcessDPIAware() | Out-Null
$items=Get-Content -Raw -Encoding UTF8 -LiteralPath $Targets | ConvertFrom-Json; $items=@($items)
$forms=@()
for ($i=0;$i -lt $items.Count;$i++) {
 $form=New-Object PassthroughForm
 $form.FormBorderStyle='None'; $form.ShowInTaskbar=$false; $form.TopMost=$true
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
    if ($r.ok -and $r.rect.width -gt 5 -and $r.rect.height -gt 5) {
     $forms[$i].SetBounds([int]$r.rect.left,[int]$r.rect.top,[int]$r.rect.width,[int]$r.rect.height)
     if (!$forms[$i].Visible) { $forms[$i].Show() }
     $forms[$i].Refresh()
    } else { $forms[$i].Hide() }
   } catch { $forms[$i].Hide() }
  }
  [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
 }
} finally { foreach($form in $forms) { $form.Dispose() }; Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
