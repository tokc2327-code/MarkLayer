param([Parameter(Mandatory=$true)][string]$WebView2Dir, [string]$OutboxDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'uia-core.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $WebView2Dir 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $WebView2Dir 'Microsoft.Web.WebView2.WinForms.dll')
Add-Type -ReferencedAssemblies System.Windows.Forms @'
using System.Windows.Forms;
using System;
using System.Runtime.InteropServices;
public class DesktopWebViewForm : Form {
  [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr h, int index);
  [DllImport("user32.dll", EntryPoint="SetWindowLongW")] public static extern int SetWindowLong(IntPtr h, int index, int value);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get { var p = base.CreateParams; p.ExStyle |= 0x80 | 0x08000000; return p; }
  }
}
'@
$form = New-Object DesktopWebViewForm
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta
$form.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
$wv.DefaultBackgroundColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($wv)
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP 'marklayer-desktop-webview2'
$form.Show()
Write-Host 'WebView2: window shown'
$wv.EnsureCoreWebView2Async($null) | Out-Null
for ($i = 0; $i -lt 400 -and $null -eq $wv.CoreWebView2; $i++) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 50
}
if ($null -eq $wv.CoreWebView2) { throw 'WebView2 initialization timed out' }
Write-Host 'WebView2: core ready'
$wv.CoreWebView2.add_WebMessageReceived({
  param($sender, $eventArgs)
  try {
    $msg = $eventArgs.WebMessageAsJson | ConvertFrom-Json
    if ($msg.type -eq 'window:activate') {
      $style = [DesktopWebViewForm]::GetWindowLong($form.Handle, -20)
      [void][DesktopWebViewForm]::SetWindowLong($form.Handle, -20, ($style -band (-bnot 0x08000000)))
      [void][DesktopWebViewForm]::SetForegroundWindow($form.Handle)
    } elseif ($msg.type -eq 'window:deactivate') {
      $style = [DesktopWebViewForm]::GetWindowLong($form.Handle, -20)
      [void][DesktopWebViewForm]::SetWindowLong($form.Handle, -20, ($style -bor 0x08000000))
    } elseif ($msg.type -eq 'annotate:submit' -and $OutboxDir -and $msg.op.tool -in @('area', 'comment')) {
      $scale = [double]$msg.dpr
      $op = $msg.op
      $drag = $null
      if ($op.tool -eq 'area') {
        $left = [int]($form.Left + $op.startX * $scale); $top = [int]($form.Top + $op.startY * $scale)
        $width = [int](($op.endX - $op.startX) * $scale); $height = [int](($op.endY - $op.startY) * $scale)
        $x = [int]($left + $width / 2); $y = [int]($top + $height / 2)
        $drag = @{ left = $left; top = $top; width = $width; height = $height }
        $text = [string]$op.comment
      } else {
        $x = [int]($form.Left + $op.x * $scale); $y = [int]($form.Top + $op.y * $scale)
        $text = [string]$op.text
      }
      if ([string]::IsNullOrWhiteSpace($text)) { return }
      $form.Hide()
      [Windows.Forms.Application]::DoEvents()
      $target = Get-TargetAtPoint $x $y $drag
      $form.Show()
      if ($null -eq $target) { throw 'UIA target capture failed' }
      [void](New-Item -ItemType Directory -Force -Path $OutboxDir)
      $id = [guid]::NewGuid().ToString('N')
      $tmp = Join-Path $OutboxDir ($id + '.tmp')
      ConvertTo-Json -Depth 30 -InputObject ([ordered]@{ type='create'; text=$text; desktopTarget=$target }) | Set-Content -Encoding UTF8 -LiteralPath $tmp
      Move-Item -LiteralPath $tmp -Destination (Join-Path $OutboxDir ($id + '.json'))
    } else { Write-Host ("WebView2 message: " + $eventArgs.WebMessageAsJson) }
  } catch { Write-Error "WebView2 bridge: $($_.Exception.Message)" -ErrorAction Continue }
})
$wv.CoreWebView2.add_NavigationCompleted({ param($sender, $eventArgs) Write-Host ("WebView2 navigation: success=" + $eventArgs.IsSuccess + " error=" + $eventArgs.WebErrorStatus) })
$wv.CoreWebView2.Navigate(([Uri](Join-Path $PSScriptRoot 'web/index.html')).AbsoluteUri)
Write-Host 'WebView2: navigation started'
while (!$form.IsDisposed -and $form.Visible) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 50
}
$form.Dispose()
