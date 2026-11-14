# WebView2 透明置顶壳 —— 可行性探针 v3(不阻塞等初始化,自己泵消息)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$addin = 'C:\Users\xxc\AppData\Local\Programs\Coopanion\data\home\companion\workspace\workspace\scripts\wv2'
Add-Type -Path (Join-Path $addin 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $addin 'Microsoft.Web.WebView2.WinForms.dll')

$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP 'wv2-probe'

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Bounds = New-Object System.Drawing.Rectangle(160, 160, 900, 520)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
$form.Controls.Add($wv)

$html = @'
<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;height:100%;background:transparent;font:14px/1.5 "Segoe UI",sans-serif}
.card{position:absolute;left:40px;top:40px;background:#fff;border-radius:12px;box-shadow:0 8px 24px rgba(0,0,0,.25);padding:16px 20px}
.b{position:absolute;right:40px;bottom:40px;background:#1f6feb;color:#fff;border-radius:10px;padding:10px 16px}
</style>
<div class="card">WebView2 shell: transparent + topmost + borderless</div>
<div class="b">+ Annotate</div>
'@

$state = @{ core = $false; err = $null; navigated = $false; source = '' }
$form.add_Shown({
  try { $wv.EnsureCoreWebView2Async($null) | Out-Null } catch { $state.err = "ensure: $($_.Exception.Message)" }
})

$form.Show()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# 泵消息直到 core 就绪(最多 20 秒)
while ($sw.Elapsed.TotalSeconds -lt 20) {
  [System.Windows.Forms.Application]::DoEvents()
  if ($null -ne $wv.CoreWebView2) { break }
  Start-Sleep -Milliseconds 50
}
$state.core = ($null -ne $wv.CoreWebView2)
if ($state.core) {
  try {
    $wv.NavigateToString($html)
    $state.navigated = $true
  } catch { $state.err = "nav: $($_.Exception.Message)" }
}
# 再泵 4 秒让它真画出来
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw2.Elapsed.TotalSeconds -lt 4) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 50
}
if ($state.core) { try { $state.source = $wv.CoreWebView2.Source } catch { } }

$bmp = New-Object System.Drawing.Bitmap(1280, 800)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size(1280, 800)))
$out = Join-Path $env:TEMP 'wv2-probe.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$form.Close()

"core_ready = " + $state.core
"navigated = " + $state.navigated
"source = " + $state.source
"error = " + $state.err
"shot = $out"
