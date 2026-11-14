param([Parameter(Mandatory=$true)][string]$WebView2Dir, [string]$Targets, [string]$OutboxDir, [switch]$NoCapture, [switch]$InputTest, [string]$BridgeTestTarget)
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
$form.TopMost = !$NoCapture
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta
if ($NoCapture) { $form.SetBounds(100, 100, 1000, 700) } else { $form.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen }
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
$script:inputTestFinished = $false
$script:inputTestOk = $false
$script:bridgeTestFinished = $false
$script:bridgeTestOk = $false
$inputScript = @'
(() => {
  const root = document.querySelector('mark-layer')?.shadowRoot;
  const button = root?.querySelector('[data-ml-semantic-id="toolbar.tool.comment"]');
  if (!button) { chrome.webview.postMessage({type:'input:test', error:'comment tool missing'}); return; }
  button.click();
  requestAnimationFrame(() => requestAnimationFrame(() => {
    const layer = [...root.querySelectorAll('div')].find(e => getComputedStyle(e).cursor === 'crosshair' && getComputedStyle(e).pointerEvents === 'auto');
    if (!layer) { chrome.webview.postMessage({type:'input:test', error:'comment layer missing'}); return; }
    layer.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:150, clientY:120}));
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const field = root.querySelector('textarea[aria-label^="Comment "]');
      if (!field) { chrome.webview.postMessage({type:'input:test', error:'composer field missing'}); return; }
      field.dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true, data:''}));
      field.value = '\u4e2d\u6587\u8f93\u5165\u9a8c\u8bc1';
      field.dispatchEvent(new CompositionEvent('compositionupdate', {bubbles:true, data:field.value}));
      field.dispatchEvent(new InputEvent('input', {bubbles:true, data:field.value, inputType:'insertCompositionText', isComposing:true}));
      field.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true, data:field.value}));
      field.dispatchEvent(new InputEvent('input', {bubbles:true, data:field.value, inputType:'insertText'}));
      chrome.webview.postMessage({type:'input:test', value:field.value, expected:'\u4e2d\u6587\u8f93\u5165\u9a8c\u8bc1'});
    }));
  }));
})();
'@
$wv.CoreWebView2.add_WebMessageReceived({
  param($sender, $eventArgs)
  try {
    $msg = $eventArgs.WebMessageAsJson | ConvertFrom-Json
    if ($msg.type -eq 'page:ready') { $script:lastTrack = '' }
    if ($msg.type -eq 'page:ready' -and $BridgeTestTarget) {
      $targetJson = Get-Content -Raw -Encoding UTF8 -LiteralPath $BridgeTestTarget
      $bridgeScript = @"
(async () => {
  try {
    const target = $targetJson;
    const tracked = await window.marklayerDesktopTrack(target);
    const crop = await window.marklayerDesktopCapture({x:10,y:10,width:32,height:24});
    const rect = tracked.rect;
    chrome.webview.postMessage({type:'annotate:submit', target, op:{tool:'comment', text:'bridge-test'}});
    chrome.webview.postMessage({type:'bridge:test', tracked, png:crop.dataUrl.startsWith('data:image/png;base64,')});
  } catch (e) { chrome.webview.postMessage({type:'bridge:test', error:String(e)}); }
})();
"@
      $sender.ExecuteScriptAsync($bridgeScript) | Out-Null
    } elseif ($msg.type -eq 'bridge:test') {
      Write-Host ("WebView2 bridge test: " + $eventArgs.WebMessageAsJson)
    $outboxWritten = $OutboxDir -and @(Get-ChildItem -LiteralPath $OutboxDir -Filter '*.json' -ErrorAction SilentlyContinue).Count -gt 0
    $script:bridgeTestOk = ($msg.png -eq $true -and $msg.tracked.ok -eq $true -and $outboxWritten)
      $script:bridgeTestFinished = $true
    } elseif ($msg.type -eq 'page:ready' -and $InputTest) {
      $sender.ExecuteScriptAsync($inputScript) | Out-Null
    } elseif ($msg.type -eq 'input:test') {
      Write-Host ("WebView2 input test: " + $eventArgs.WebMessageAsJson)
      $expectedText = -join @(0x4e2d,0x6587,0x8f93,0x5165,0x9a8c,0x8bc1 | ForEach-Object { [char]$_ })
      $script:inputTestOk = ($msg.value -ceq $expectedText)
      $script:inputTestFinished = $true
    } elseif ($msg.type -eq 'window:activate') {
      $style = [DesktopWebViewForm]::GetWindowLong($form.Handle, -20)
      [void][DesktopWebViewForm]::SetWindowLong($form.Handle, -20, ($style -band (-bnot 0x08000000)))
      [void][DesktopWebViewForm]::SetForegroundWindow($form.Handle)
    } elseif ($msg.type -eq 'window:deactivate') {
      $style = [DesktopWebViewForm]::GetWindowLong($form.Handle, -20)
      [void][DesktopWebViewForm]::SetWindowLong($form.Handle, -20, ($style -bor 0x08000000))
    } elseif ($msg.type -eq 'capture:target') {
      $scale = [double]$msg.dpr
      $rect = $msg.rect
      $left = [int]($form.Left + $rect.left * $scale); $top = [int]($form.Top + $rect.top * $scale)
      $width = [int]($rect.width * $scale); $height = [int]($rect.height * $scale)
      $drag = if ($width -ge 6 -and $height -ge 6) { @{ left=$left; top=$top; width=$width; height=$height } } else { $null }
      $x = [int]($left + $width / 2); $y = [int]($top + $height / 2)
      $form.Hide()
      [Windows.Forms.Application]::DoEvents()
      try { $target = Get-TargetAtPoint $x $y $drag } finally { $form.Show() }
      if ($null -eq $target) { throw 'UIA target capture failed' }
      $sender.PostWebMessageAsJson((@{ requestId=$msg.requestId; result=$target } | ConvertTo-Json -Depth 30 -Compress))
    } elseif ($msg.type -eq 'capture:element') {
      $scale = [double]$msg.dpr
      $crop = $msg.crop
      $x = [int]($form.Left + $crop.x * $scale); $y = [int]($form.Top + $crop.y * $scale)
      $width = [int]($crop.width * $scale); $height = [int]($crop.height * $scale)
      if ($width -le 0 -or $height -le 0 -or $width -gt 8192 -or $height -gt 8192) { throw 'Invalid capture rectangle' }
      $form.Hide()
      [Windows.Forms.Application]::DoEvents()
      try {
        $bitmap = New-Object Drawing.Bitmap($width, $height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
          $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
          $memory = New-Object IO.MemoryStream
          try {
            $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
            $dataUrl = 'data:image/png;base64,' + [Convert]::ToBase64String($memory.ToArray())
          } finally { $memory.Dispose() }
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
      } finally { $form.Show() }
      $response = @{ requestId=$msg.requestId; result=@{ dataUrl=$dataUrl } } | ConvertTo-Json -Depth 5 -Compress
      $sender.PostWebMessageAsJson($response)
    } elseif ($msg.type -eq 'window:track') {
      $resolved = Resolve-DesktopTarget $msg.target
      $response = @{ requestId=$msg.requestId; result=$resolved } | ConvertTo-Json -Depth 20 -Compress
      $sender.PostWebMessageAsJson($response)
    } elseif ($msg.type -eq 'annotate:submit' -and $OutboxDir -and $msg.op.tool -in @('area', 'comment')) {
      $op = $msg.op
      $target = $msg.target
      $text = if ($op.tool -eq 'area') { [string]$op.comment } else { [string]$op.text }
      if ([string]::IsNullOrWhiteSpace($text)) { return }
      if ($null -eq $target) { throw 'UIA target capture failed' }
      $resolved = Resolve-DesktopTarget $target
      if (!$resolved.ok -or $resolved.minimized) { throw 'Captured UIA target no longer resolves' }
      [void](New-Item -ItemType Directory -Force -Path $OutboxDir)
      $id = [guid]::NewGuid().ToString('N')
      $tmp = Join-Path $OutboxDir ($id + '.tmp')
      ConvertTo-Json -Depth 30 -InputObject ([ordered]@{ type='create'; text=$text; desktopTarget=$target }) | Set-Content -Encoding UTF8 -LiteralPath $tmp
      Move-Item -LiteralPath $tmp -Destination (Join-Path $OutboxDir ($id + '.json'))
    } else { Write-Host ("WebView2 message: " + $eventArgs.WebMessageAsJson) }
  } catch {
    Write-Error "WebView2 bridge: $($_.Exception.Message)" -ErrorAction Continue
    if ($null -ne $msg.requestId) {
      $response = @{ requestId=$msg.requestId; error=$_.Exception.Message } | ConvertTo-Json -Compress
      $sender.PostWebMessageAsJson($response)
    }
  }
})
$wv.CoreWebView2.add_NavigationCompleted({ param($sender, $eventArgs) Write-Host ("WebView2 navigation: success=" + $eventArgs.IsSuccess + " error=" + $eventArgs.WebErrorStatus) })
$wv.CoreWebView2.Navigate(([Uri](Join-Path $PSScriptRoot 'web/index.html')).AbsoluteUri)
Write-Host 'WebView2: navigation started'
$lastTrack = ''
$trackTicks = 0
while (!$form.IsDisposed -and $form.Visible) {
  [System.Windows.Forms.Application]::DoEvents()
  if ($BridgeTestTarget -and $script:bridgeTestFinished) {
    if (!$script:bridgeTestOk) { throw 'WebView2 bridge test failed' }
    for ($i = 0; $i -lt 60; $i++) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 50
    }
    break
  }
  if ($InputTest -and $script:inputTestFinished) {
    $shotPath = Join-Path $PSScriptRoot '../../acceptance/desktop-annotation-2026-11-14/webview2-chinese-input.png'
    $stream = [IO.File]::Create([IO.Path]::GetFullPath($shotPath))
    $shotTask = $wv.CoreWebView2.CapturePreviewAsync([Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png, $stream)
    for ($i = 0; $i -lt 200 -and !$shotTask.IsCompleted; $i++) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 50
    }
    $stream.Dispose()
    if (!$shotTask.IsCompleted -or $shotTask.IsFaulted -or !$script:inputTestOk) { throw 'WebView2 input test failed' }
    Write-Host "WebView2 input screenshot: $shotPath"
    break
  }
  if (!$InputTest -and $Targets -and (Test-Path -LiteralPath $Targets) -and ($trackTicks++ % 5 -eq 0)) {
    try {
      $tracked = @()
      foreach ($item in @(Get-Content -Raw -Encoding UTF8 -LiteralPath $Targets | ConvertFrom-Json)) {
        $target = if ($item.desktopTarget) { $item.desktopTarget } else { $item }
        if ($target.kind -ne 'windows-uia') { continue }
        $resolved = Resolve-DesktopTarget $target
        if (!$resolved.ok -or $resolved.minimized -or !$resolved.rect) { continue }
        $x = [double]$resolved.rect.left; $y = [double]$resolved.rect.top
        if ($target.relativeRect) { $x += [double]$target.relativeRect.left; $y += [double]$target.relativeRect.top }
        $tracked += @{ id=$item.id; num=$item.num; text=$item.text; status=$item.status; color=$item.color; x=$x; y=$y }
      }
      $update = @{ type='window:track'; items=@($tracked); origin=@{x=$form.Left; y=$form.Top} } | ConvertTo-Json -Depth 15 -Compress
      if ($update -ne $lastTrack) {
        $lastTrack = $update
        $wv.CoreWebView2.PostWebMessageAsJson($update)
        Write-Host ("WebView2 tracking: " + $update)
      }
    } catch { Write-Error "WebView2 tracking: $($_.Exception.Message)" -ErrorAction Continue }
  }
  Start-Sleep -Milliseconds 50
}
$form.Dispose()
