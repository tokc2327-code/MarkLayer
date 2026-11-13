param([string]$OutDir = $PSScriptRoot)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeSpike {
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
}
"@
$ErrorActionPreference = 'Stop'
$apps = @(@{ name='notepad'; exe='notepad.exe' }, @{ name='mspaint'; exe='mspaint.exe' })
$started = @()
try {
 foreach ($app in $apps) {
  $p = Start-Process $app.exe -WindowStyle Normal -PassThru
  $started += $p
  $deadline = (Get-Date).AddSeconds(20)
  do { Start-Sleep -Milliseconds 500; $p = Get-Process $app.name -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -Last 1 } while (!$p -and (Get-Date) -lt $deadline)
  if ($p.MainWindowHandle -eq 0) { throw "No main window: $($app.name)" }
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
  $nodes = @($root) + @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_ })
  $items = foreach ($node in $nodes) {
   try {
    $parent = if ($node -eq $root) { $null } else { [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($node) }; $parentId = if ($parent) { ($parent.GetRuntimeId() -join '.') } else { $null }; $id = $node.GetRuntimeId() -join '.'; $c = $node.Current; $r = $c.BoundingRectangle; $rect = if ($r.IsEmpty) { $null } else { @{x=$r.X;y=$r.Y;width=$r.Width;height=$r.Height} }
    [ordered]@{ runtimeId=$id; parentRuntimeId=$parentId; name=$c.Name; type=$c.ControlType.ProgrammaticName; automationId=$c.AutomationId; rect=$rect; enabled=$c.IsEnabled; keyboardFocusable=$c.IsKeyboardFocusable; interactive=($c.IsEnabled -and $c.IsKeyboardFocusable) }
   } catch { }
  }
  [ordered]@{app=$app.name; title=$root.Current.Name; capturedAt=(Get-Date).ToString('o'); note='interactive is an enabled-and-focusable heuristic, not a guarantee'; elements=@($items)} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutDir "$($app.name).json")
  if ($app.name -eq 'mspaint') { $target = $root; $handle = $p.MainWindowHandle }
 }
 [NativeSpike]::ShowWindow($handle, 9) | Out-Null
 [NativeSpike]::MoveWindow($handle, 100, 100, 700, 500, $true) | Out-Null
 [NativeSpike]::SetForegroundWindow($handle) | Out-Null
 $form = New-Object Windows.Forms.Form
 $form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.TopMost = $true
 $form.BackColor = [Drawing.Color]::Lime; $form.TransparencyKey = [Drawing.Color]::Lime
 $form.add_Paint({ param($sender,$e) $pen = New-Object Drawing.Pen([Drawing.Color]::Red, 5); $e.Graphics.DrawRectangle($pen, 3, 3, $sender.ClientSize.Width-7, $sender.ClientSize.Height-7); $pen.Dispose() })
 $target = $target.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { try { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -and !$_.Current.BoundingRectangle.IsEmpty -and $_.Current.BoundingRectangle.Width -gt 20 } catch { $false } } | Select-Object -First 1
 if (!$target) { throw 'No visible button in Paint' }
 $form.Show()
 $observations = @()
 foreach ($step in 0,1) {
  if ($step -eq 1) { [NativeSpike]::MoveWindow($handle, 300, 200, 700, 500, $true) | Out-Null }
  # Poll repeatedly, independently of the two sample captures.
  for ($tick = 0; $tick -lt 10; $tick++) {
   $r = $target.Current.BoundingRectangle
   $form.SetBounds([int]$r.X,[int]$r.Y,[int]$r.Width,[int]$r.Height); $form.Refresh(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
  }
  $bmp = New-Object Drawing.Bitmap (([int]$r.Width + 80), ([int]$r.Height + 80))
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen([int]$r.X - 40,[int]$r.Y - 40,0,0,$bmp.Size)
  $bmp.Save((Join-Path $OutDir "overlay-$step.png"),[Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
  $observations += @{step=$step; targetName=$target.Current.Name; target=@{x=$r.X;y=$r.Y;width=$r.Width;height=$r.Height}; overlay=@{x=$form.Left;y=$form.Top;width=$form.Width;height=$form.Height}}
 }
 $observations | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $OutDir 'movement.json')
 $form.Close()
} finally { foreach ($p in $started) { if (!$p.HasExited) { $p.CloseMainWindow() | Out-Null } } }
