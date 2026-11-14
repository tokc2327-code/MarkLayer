# WebView2 透明置顶壳 —— 视觉验证(跑 12 秒,自己去截屏)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$addin = 'C:\Users\xxc\AppData\Local\Programs\Coopanion\data\home\companion\workspace\workspace\scripts\wv2'
Add-Type -Path (Join-Path $addin 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $addin 'Microsoft.Web.WebView2.WinForms.dll')
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $env:TEMP 'wv2-probe2'

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Bounds = New-Object System.Drawing.Rectangle(200, 200, 820, 460)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
# 关键:WebView2 自己也要透明背景,否则是一块白底
try { $wv.DefaultBackgroundColor = [System.Drawing.Color]::Transparent } catch { "DefaultBackgroundColor 不支持: $($_.Exception.Message)" }
$form.Controls.Add($wv)

$html = @'
<!doctype html><meta charset="utf-8">
<style>
html,body{margin:0;height:100%;background:transparent;font:16px/1.5 "Segoe UI",sans-serif}
.card{position:absolute;left:30px;top:30px;background:#fff;border-radius:14px;box-shadow:0 10px 30px rgba(0,0,0,.28);padding:18px 22px}
.btn{position:absolute;right:30px;bottom:30px;background:#1f6feb;color:#fff;border-radius:10px;padding:12px 18px}
</style>
<div class="card"><b>WebView2 shell</b><br>透明 + 置顶 + 无边框<br>uia overlay 将来就长这样</div>
<div class="btn">+ Annotate</div>
'@

$form.add_Shown({ try { $wv.EnsureCoreWebView2Async($null) | Out-Null } catch { } })
$form.Show()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 20 -and $null -eq $wv.CoreWebView2) {
  [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50
}
if ($null -ne $wv.CoreWebView2) {
  try { $wv.CoreWebView2.DefaultBackgroundColor = [System.Drawing.Color]::Transparent } catch { }
  $wv.NavigateToString($html)
}
# 亮 12 秒,等外面截屏
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw2.Elapsed.TotalSeconds -lt 12) {
  [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50
}
$form.Close()
"done core=" + ($null -ne $wv.CoreWebView2)
