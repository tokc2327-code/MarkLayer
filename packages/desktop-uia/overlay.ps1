param(
  [Parameter(Mandatory=$true)][string]$Targets,
  [switch]$Interactive,
  [string]$OutboxDir,
  [string]$StateOut,
  [switch]$WebViewPreview,
  [string]$WebView2Dir,
  [int]$BarX = -1,
  [int]$BarY = -1
)
$ErrorActionPreference = 'Stop'

if ($WebViewPreview) {
  & (Join-Path $PSScriptRoot 'webview-preview.ps1') -WebView2Dir $WebView2Dir -OutboxDir $OutboxDir
  return
}

# Must run BEFORE loading System.Windows.Forms so WinForms initializes PerMonitorV2.
. (Join-Path $PSScriptRoot 'uia-core.ps1')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('PassthroughForm' -as [type])) {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class PassthroughForm : Form {
  public PassthroughForm() {
    this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
    this.AutoScaleMode = AutoScaleMode.None;
    this.FormBorderStyle = FormBorderStyle.None;
    this.ShowInTaskbar = false;
    this.TopMost = true;
    this.StartPosition = FormStartPosition.Manual;
    this.BackColor = Color.Lime;
    this.TransparencyKey = Color.Lime;
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      var p = base.CreateParams;
      p.ExStyle |= 0x20 | 0x80 | 0x80000 | 0x08000000;
      return p;
    }
  }
}

public class NonActivatingToolForm : Form {
  public NonActivatingToolForm() {
    this.AutoScaleMode = AutoScaleMode.None;
    this.FormBorderStyle = FormBorderStyle.None;
    this.ShowInTaskbar = false;
    this.TopMost = true;
    this.StartPosition = FormStartPosition.Manual;
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      var p = base.CreateParams;
      p.ExStyle |= 0x80 | 0x08000000;
      return p;
    }
  }
}
"@
}

if ([DesktopUiaNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) -eq [IntPtr]::Zero -or
    ![DesktopUiaNative]::AreDpiAwarenessContextsEqual([DesktopUiaNative]::GetThreadDpiAwarenessContext(), [IntPtr](-4))) {
  throw 'Cannot set overlay thread to PerMonitorV2 DPI awareness'
}

$script:BadgeFont = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$script:UiFont = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$script:UiBoldFont = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

function Parse-HexColor([string]$hex, [System.Drawing.Color]$fallback) {
  if ([string]::IsNullOrWhiteSpace($hex)) { return $fallback }
  try { return [System.Drawing.ColorTranslator]::FromHtml($hex) } catch { return $fallback }
}

function Read-TargetItems([string]$path) {
  if (!(Test-Path -LiteralPath $path)) { return @() }
  $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $parsed = $raw | ConvertFrom-Json
  if ($null -eq $parsed) { return @() }
  $arr = @($parsed)
  $items = @()
  for ($i = 0; $i -lt $arr.Count; $i++) {
    $entry = $arr[$i]
    if ($null -eq $entry) { continue }
    $hasWrapper = ($null -ne $entry.desktopTarget)
    $target = if ($hasWrapper) { $entry.desktopTarget } else { $entry }
    if ($null -eq $target -or $target.kind -ne 'windows-uia') { continue }
    $num = if ($hasWrapper -and $null -ne $entry.num) { [int]$entry.num } else { $i + 1 }
    $status = if ($hasWrapper -and $entry.status) { [string]$entry.status } else { 'open' }
    $text = if ($hasWrapper -and $entry.text) { [string]$entry.text } else { '' }
    $id = if ($hasWrapper -and $entry.id) { [string]$entry.id } else { "local-$num" }
    $colorHex = if ($hasWrapper -and $entry.color) { [string]$entry.color } else { '#ef4444' }
    $replies = if ($hasWrapper -and $entry.replies) { @($entry.replies) } else { @() }
    $items += [pscustomobject]@{
      id            = $id
      num           = $num
      text          = $text
      status        = $status
      colorHex      = $colorHex
      replies       = $replies
      desktopTarget = $target
    }
  }
  return $items
}

function New-BoxForm {
  $f = New-Object PassthroughForm
  $f.Tag = @{ color = [System.Drawing.Color]::Red; key = '' }
  $f.add_Paint({
    param($s, $e)
    $col = $s.Tag.color
    $pen = New-Object System.Drawing.Pen($col, 3)
    $e.Graphics.DrawRectangle($pen, 1, 1, [Math]::Max(1, $s.ClientSize.Width - 3), [Math]::Max(1, $s.ClientSize.Height - 3))
    $pen.Dispose()
  })
  return $f
}

function New-BadgeForm {
  $f = New-Object PassthroughForm
  $f.Tag = @{ label = '#1'; color = [System.Drawing.Color]::Red; key = '' }
  $f.add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $col = $s.Tag.color
    $brush = New-Object System.Drawing.SolidBrush($col)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)
    $rect = New-Object System.Drawing.Rectangle(1, 1, [Math]::Max(2, $s.ClientSize.Width - 3), [Math]::Max(2, $s.ClientSize.Height - 3))
    $e.Graphics.FillRectangle($brush, $rect)
    $e.Graphics.DrawRectangle($borderPen, $rect)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $e.Graphics.DrawString($s.Tag.label, $script:BadgeFont, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]$rect, $sf)
    $sf.Dispose()
    $borderPen.Dispose()
    $brush.Dispose()
  })
  return $f
}

function Write-OutboxPayload($payload) {
  if ([string]::IsNullOrWhiteSpace($OutboxDir)) { return }
  if (!(Test-Path -LiteralPath $OutboxDir)) { [void](New-Item -ItemType Directory -Force -Path $OutboxDir) }
  $id = [guid]::NewGuid().ToString('N')
  $tmp = Join-Path $OutboxDir ($id + '.tmp')
  $dest = Join-Path $OutboxDir ($id + '.json')
  ConvertTo-Json -InputObject $payload -Depth 30 | Set-Content -Encoding UTF8 -LiteralPath $tmp
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}

function Capture-RegionAndTarget {
  param($hideForms)
  foreach ($hf in $hideForms) { if ($hf.Visible) { $hf.Hide() } }
  [Windows.Forms.Application]::DoEvents()

  $virtual = [Windows.Forms.SystemInformation]::VirtualScreen
  $curtain = New-Object Windows.Forms.Form
  $curtain.AutoScaleMode = 'None'
  $curtain.FormBorderStyle = 'None'
  $curtain.ShowInTaskbar = $false
  $curtain.TopMost = $true
  $curtain.StartPosition = 'Manual'
  $curtain.BackColor = [System.Drawing.Color]::Black
  $curtain.Opacity = 0.18
  $curtain.Cursor = [Windows.Forms.Cursors]::Cross
  $curtain.SetBounds($virtual.Left, $virtual.Top, $virtual.Width, $virtual.Height)

  $state = @{
    down      = $false
    cancelled = $false
    start     = $null
    end       = $null
    dragRect  = $null
  }

  $curtain.add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
      $state.cancelled = $true
      $s.Close()
    }
  })
  $curtain.add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) {
      $state.cancelled = $true
      $s.Close()
      return
    }
    $pt = $s.PointToScreen($e.Location)
    $state.down = $true
    $state.start = $pt
    $state.end = $pt
  })
  $curtain.add_MouseMove({
    param($s, $e)
    if (!$state.down) { return }
    $state.end = $s.PointToScreen($e.Location)
    $s.Invalidate()
  })
  $curtain.add_Paint({
    param($s, $e)
    if (!$state.down -or $null -eq $state.start -or $null -eq $state.end) { return }
    $x1 = [Math]::Min($state.start.X, $state.end.X) - $virtual.Left
    $y1 = [Math]::Min($state.start.Y, $state.end.Y) - $virtual.Top
    $w = [Math]::Abs($state.end.X - $state.start.X)
    $h = [Math]::Abs($state.end.Y - $state.start.Y)
    if ($w -ge 2 -and $h -ge 2) {
      $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 2)
      $e.Graphics.DrawRectangle($pen, $x1, $y1, $w, $h)
      $pen.Dispose()
    }
  })
  $curtain.add_MouseUp({
    param($s, $e)
    if (!$state.down) { return }
    $state.end = $s.PointToScreen($e.Location)
    $state.down = $false
    $s.Close()
  })

  [void]$curtain.ShowDialog()
  $curtain.Dispose()
  [Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 40

  if ($state.cancelled -or $null -eq $state.start -or $null -eq $state.end) { return $null }

  $x1 = [Math]::Min($state.start.X, $state.end.X)
  $y1 = [Math]::Min($state.start.Y, $state.end.Y)
  $w = [Math]::Abs($state.end.X - $state.start.X)
  $h = [Math]::Abs($state.end.Y - $state.start.Y)
  $cx = if ($w -ge 6) { [int]($x1 + $w / 2) } else { [int]$state.end.X }
  $cy = if ($h -ge 6) { [int]($y1 + $h / 2) } else { [int]$state.end.Y }
  $dragRect = if ($w -ge 6 -and $h -ge 6) { @{ left = $x1; top = $y1; width = $w; height = $h } } else { $null }

  return Get-TargetAtPoint $cx $cy $dragRect
}

function Show-CommentComposer {
  param($desktopTarget)
  $virtual = [Windows.Forms.SystemInformation]::VirtualScreen
  $cw = 320
  $ch = 118
  $cx = [Math]::Min([Math]::Max($virtual.Left + 12, [int]$desktopTarget.captured.left), $virtual.Right - $cw - 12)
  $cy = [int]($desktopTarget.captured.top + $desktopTarget.captured.height + 8)
  if ($cy + $ch -gt $virtual.Bottom - 12) {
    $cy = [Math]::Max($virtual.Top + 12, [int]$desktopTarget.captured.top - $ch - 8)
  }

  $dlg = New-Object Windows.Forms.Form
  $dlg.AutoScaleMode = 'None'
  $dlg.FormBorderStyle = 'FixedToolWindow'
  $dlg.Text = "Annotate: $($desktopTarget.app)"
  $dlg.TopMost = $true
  $dlg.StartPosition = 'Manual'
  $dlg.Location = [System.Drawing.Point]::new($cx, $cy)
  $dlg.ClientSize = [System.Drawing.Size]::new($cw, 86)
  $dlg.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 27)
  $dlg.ForeColor = [System.Drawing.Color]::White

  $box = New-Object Windows.Forms.TextBox
  $box.Font = $script:UiFont
  $box.SetBounds(10, 10, $cw - 20, 26)
  $box.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
  $box.ForeColor = [System.Drawing.Color]::White
  $box.BorderStyle = 'FixedSingle'

  $btnSend = New-Object Windows.Forms.Button
  $btnSend.Text = 'Send'
  $btnSend.Font = $script:UiBoldFont
  $btnSend.SetBounds($cw - 166, 46, 76, 28)
  $btnSend.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
  $btnSend.ForeColor = [System.Drawing.Color]::White
  $btnSend.FlatStyle = 'Flat'
  $btnSend.DialogResult = [System.Windows.Forms.DialogResult]::OK

  $btnCancel = New-Object Windows.Forms.Button
  $btnCancel.Text = 'Cancel'
  $btnCancel.Font = $script:UiFont
  $btnCancel.SetBounds($cw - 84, 46, 74, 28)
  $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(63, 63, 70)
  $btnCancel.ForeColor = [System.Drawing.Color]::White
  $btnCancel.FlatStyle = 'Flat'
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

  $dlg.Controls.AddRange(@($box, $btnSend, $btnCancel))
  $dlg.AcceptButton = $btnSend
  $dlg.CancelButton = $btnCancel
  $dlg.add_Shown({ $box.Focus() | Out-Null })

  $res = $dlg.ShowDialog()
  $text = $box.Text.Trim()
  $dlg.Dispose()
  if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $text.Length -gt 0) {
    return $text
  }
  return $null
}

function Show-NotesDrawer {
  param($items, [int]$anchorX, [int]$anchorY)
  $dw = 340
  $dh = 260
  $virtual = [Windows.Forms.SystemInformation]::VirtualScreen
  $dx = [Math]::Min([Math]::Max($virtual.Left + 8, $anchorX), $virtual.Right - $dw - 8)
  $dy = [Math]::Min($anchorY, $virtual.Bottom - $dh - 8)

  $drawer = New-Object Windows.Forms.Form
  $drawer.AutoScaleMode = 'None'
  $drawer.FormBorderStyle = 'FixedToolWindow'
  $drawer.Text = 'Desktop Notes'
  $drawer.TopMost = $true
  $drawer.StartPosition = 'Manual'
  $drawer.Location = [System.Drawing.Point]::new($dx, $dy)
  $drawer.ClientSize = [System.Drawing.Size]::new($dw, 186)
  $drawer.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 27)
  $drawer.ForeColor = [System.Drawing.Color]::White

  $list = New-Object Windows.Forms.ListBox
  $list.Font = $script:UiFont
  $list.SetBounds(10, 10, $dw - 20, 130)
  $list.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
  $list.ForeColor = [System.Drawing.Color]::White
  foreach ($it in $items) {
    $replyCount = @($it.replies).Count
    $suffix = if ($replyCount -gt 0) { " ($replyCount replies)" } else { '' }
    [void]$list.Items.Add("#$($it.num) [$($it.status)] $($it.text)$suffix")
  }
  if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

  $replyBox = New-Object Windows.Forms.TextBox
  $replyBox.Font = $script:UiFont
  $replyBox.SetBounds(10, 148, $dw - 102, 26)
  $replyBox.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
  $replyBox.ForeColor = [System.Drawing.Color]::White
  $replyBox.BorderStyle = 'FixedSingle'

  $btnReply = New-Object Windows.Forms.Button
  $btnReply.Text = 'Reply'
  $btnReply.Font = $script:UiBoldFont
  $btnReply.SetBounds($dw - 84, 147, 74, 28)
  $btnReply.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
  $btnReply.ForeColor = [System.Drawing.Color]::White
  $btnReply.FlatStyle = 'Flat'
  $btnReply.add_Click({
    $idx = $list.SelectedIndex
    $txt = $replyBox.Text.Trim()
    if ($idx -ge 0 -and $idx -lt $items.Count -and $txt.Length -gt 0) {
      Write-OutboxPayload ([ordered]@{
        type     = 'reply'
        parentId = $items[$idx].id
        text     = $txt
      })
      $drawer.Close()
    }
  })

  $drawer.Controls.AddRange(@($list, $replyBox, $btnReply))
  $drawer.AcceptButton = $btnReply
  [void]$drawer.ShowDialog()
  $drawer.Dispose()
}

$script:Running = $true
$script:PendingAction = $null
$boxForms = New-Object System.Collections.Generic.List[PassthroughForm]
$badgeForms = New-Object System.Collections.Generic.List[PassthroughForm]
$barForm = $null
$btnAnnotate = $null
$btnNotes = $null

if ($Interactive) {
  $virtual = [Windows.Forms.SystemInformation]::VirtualScreen
  $bw = 304
  $bh = 36
  $bx = if ($BarX -ge 0) { $BarX } else { $virtual.Right - $bw - 24 }
  $by = if ($BarY -ge 0) { $BarY } else { $virtual.Top + 16 }

  $barForm = New-Object NonActivatingToolForm
  $barForm.SetBounds($bx, $by, $bw, $bh)
  $barForm.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 27)
  $barForm.ForeColor = [System.Drawing.Color]::White

  $lbl = New-Object Windows.Forms.Label
  $lbl.Text = 'MarkLayer'
  $lbl.Font = $script:UiBoldFont
  $lbl.SetBounds(10, 10, 70, 18)
  $lbl.ForeColor = [System.Drawing.Color]::White

  $btnAnnotate = New-Object Windows.Forms.Button
  $btnAnnotate.Text = '+ Annotate'
  $btnAnnotate.Font = $script:UiBoldFont
  $btnAnnotate.SetBounds(84, 5, 92, 26)
  $btnAnnotate.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
  $btnAnnotate.ForeColor = [System.Drawing.Color]::White
  $btnAnnotate.FlatStyle = 'Flat'
  $btnAnnotate.FlatAppearance.BorderSize = 0
  $btnAnnotate.add_Click({ $script:PendingAction = 'annotate' })

  $btnNotes = New-Object Windows.Forms.Button
  $btnNotes.Text = 'Notes (0)'
  $btnNotes.Font = $script:UiFont
  $btnNotes.SetBounds(180, 5, 88, 26)
  $btnNotes.BackColor = [System.Drawing.Color]::FromArgb(63, 63, 70)
  $btnNotes.ForeColor = [System.Drawing.Color]::White
  $btnNotes.FlatStyle = 'Flat'
  $btnNotes.FlatAppearance.BorderSize = 0
  $btnNotes.add_Click({ $script:PendingAction = 'notes' })

  $btnClose = New-Object Windows.Forms.Button
  $btnClose.Text = 'X'
  $btnClose.Font = $script:UiBoldFont
  $btnClose.SetBounds(272, 5, 26, 26)
  $btnClose.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
  $btnClose.ForeColor = [System.Drawing.Color]::White
  $btnClose.FlatStyle = 'Flat'
  $btnClose.FlatAppearance.BorderSize = 0
  $btnClose.add_Click({ $script:Running = $false })

  $barForm.Controls.AddRange(@($lbl, $btnAnnotate, $btnNotes, $btnClose))
  $barForm.Show()
  [void][DesktopUiaNative]::SetWindowPos($barForm.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
}

$lastWrite = ''
$items = @()
$lastStateSignature = ''

try {
  while ($script:Running) {
    [Windows.Forms.Application]::DoEvents()

    if ($script:PendingAction -eq 'annotate') {
      $script:PendingAction = $null
      $hideList = @($boxForms.ToArray()) + @($badgeForms.ToArray())
      if ($null -ne $barForm) { $hideList += $barForm }
      $capturedTarget = Capture-RegionAndTarget -hideForms $hideList
      if ($null -ne $barForm) {
        $barForm.Show()
        [void][DesktopUiaNative]::SetWindowPos($barForm.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
      }
      if ($null -ne $capturedTarget) {
        $commentText = Show-CommentComposer -desktopTarget $capturedTarget
        if ($null -ne $commentText) {
          Write-OutboxPayload ([ordered]@{
            type          = 'create'
            text          = $commentText
            desktopTarget = $capturedTarget
          })
        }
      }
    } elseif ($script:PendingAction -eq 'notes') {
      $script:PendingAction = $null
      if ($null -ne $barForm) {
        Show-NotesDrawer -items $items -anchorX $barForm.Left -anchorY ($barForm.Bottom + 6)
      }
    }

    if (Test-Path -LiteralPath $Targets) {
      $fi = Get-Item -LiteralPath $Targets
      $wt = "$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)"
      if ($wt -ne $lastWrite) {
        try {
          $items = @(Read-TargetItems $Targets)
          $lastWrite = $wt
          if ($null -ne $btnNotes) { $btnNotes.Text = "Notes ($($items.Count))" }
        } catch { }
      }
    }

    while ($boxForms.Count -lt $items.Count) {
      $boxForms.Add((New-BoxForm))
      $badgeForms.Add((New-BadgeForm))
    }

    $virtual = [Windows.Forms.SystemInformation]::VirtualScreen
    $placedBadges = New-Object System.Collections.Generic.List[System.Drawing.Rectangle]
    $stateItems = @()

    for ($i = 0; $i -lt $boxForms.Count; $i++) {
      $bf = $boxForms[$i]
      $bg = $badgeForms[$i]
      if ($i -ge $items.Count) {
        if ($bf.Visible) { $bf.Hide() }
        if ($bg.Visible) { $bg.Hide() }
        continue
      }

      $it = $items[$i]
      $t = $it.desktopTarget
      try {
        $r = Resolve-DesktopTarget $t
        if ($r.ok -and !$r.minimized -and $null -ne $r.rect) {
          $boxL = [int][Math]::Round($r.rect.left)
          $boxT = [int][Math]::Round($r.rect.top)
          $boxW = [int][Math]::Round($r.rect.width)
          $boxH = [int][Math]::Round($r.rect.height)
          if ($null -ne $t.relativeRect -and $t.relativeRect.width -gt 5 -and $t.relativeRect.height -gt 5) {
            $boxL = [int][Math]::Round($r.rect.left + $t.relativeRect.left)
            $boxT = [int][Math]::Round($r.rect.top + $t.relativeRect.top)
            $boxW = [int][Math]::Round($t.relativeRect.width)
            $boxH = [int][Math]::Round($t.relativeRect.height)
          }

          $visible = ($boxL + $boxW -gt $virtual.Left) -and ($boxT + $boxH -gt $virtual.Top) -and ($boxL -lt $virtual.Right) -and ($boxT -lt $virtual.Bottom)
          if ($visible -and $boxW -gt 5 -and $boxH -gt 5) {
            $isDone = ($it.status -eq 'resolved' -or $it.status -eq 'approved' -or $it.status -eq 'dismissed')
            $color = if ($isDone) { [System.Drawing.Color]::FromArgb(34, 197, 94) } else { Parse-HexColor $it.colorHex ([System.Drawing.Color]::Red) }
            $label = if ($isDone) { "#$($it.num) OK" } else { "#$($it.num)" }

            $boxKey = "$($color.ToArgb())"
            if ($bf.Tag.key -ne $boxKey) {
              $bf.Tag = @{ color = $color; key = $boxKey }
              $bf.Invalidate()
            }
            if ($bf.Left -ne $boxL -or $bf.Top -ne $boxT -or $bf.Width -ne $boxW -or $bf.Height -ne $boxH) {
              $bf.SetBounds($boxL, $boxT, $boxW, $boxH)
            }
            if (!$bf.Visible) { $bf.Show() }
            [void][DesktopUiaNative]::SetWindowPos($bf.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)

            $measured = [System.Windows.Forms.TextRenderer]::MeasureText($label, $script:BadgeFont)
            $badgeW = [Math]::Max(32, $measured.Width + 10)
            $badgeH = [Math]::Max(22, $measured.Height + 6)
            $candX = $boxL
            $candY = $boxT - $badgeH - 2
            if ($candY -lt ($virtual.Top + 2)) { $candY = $boxT + 2 }

            for ($step = 0; $step -lt 50; $step++) {
              $candRect = New-Object System.Drawing.Rectangle($candX, $candY, $badgeW, $badgeH)
              $hit = $null
              foreach ($pb in $placedBadges) {
                if ($candRect.IntersectsWith($pb)) { $hit = $pb; break }
              }
              if ($null -eq $hit) { break }
              $candX = $hit.Right + 4
              if ($candX + $badgeW -gt $virtual.Right - 4) {
                $candX = $boxL
                $candY = $hit.Bottom + 4
              }
            }
            $finalBadgeRect = New-Object System.Drawing.Rectangle($candX, $candY, $badgeW, $badgeH)
            $placedBadges.Add($finalBadgeRect)

            $badgeKey = "$label|$($color.ToArgb())"
            if ($bg.Tag.key -ne $badgeKey) {
              $bg.Tag = @{ label = $label; color = $color; key = $badgeKey }
              $bg.Invalidate()
            }
            if ($bg.Left -ne $candX -or $bg.Top -ne $candY -or $bg.Width -ne $badgeW -or $bg.Height -ne $badgeH) {
              $bg.SetBounds($candX, $candY, $badgeW, $badgeH)
            }
            if (!$bg.Visible) { $bg.Show() }
            [void][DesktopUiaNative]::SetWindowPos($bg.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)

            $stateItems += [ordered]@{
              id        = $it.id
              num       = $it.num
              status    = $it.status
              visible   = $true
              boxRect   = [ordered]@{ left = $boxL; top = $boxT; width = $boxW; height = $boxH }
              badgeRect = [ordered]@{ left = $candX; top = $candY; width = $badgeW; height = $badgeH }
            }
            continue
          }
        }
      } catch { }

      if ($bf.Visible) { $bf.Hide() }
      if ($bg.Visible) { $bg.Hide() }
      $stateItems += [ordered]@{
        id      = $it.id
        num     = $it.num
        status  = $it.status
        visible = $false
      }
    }

    if ($null -ne $barForm) {
      [void][DesktopUiaNative]::SetWindowPos($barForm.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
    }

    if (![string]::IsNullOrWhiteSpace($StateOut)) {
      $barRectObj = if ($null -ne $barForm) {
        [ordered]@{ left = $barForm.Left; top = $barForm.Top; width = $barForm.Width; height = $barForm.Height }
      } else { $null }
      $payloadObj = [ordered]@{
        pid           = $PID
        interactive   = [bool]$Interactive
        barRect       = $barRectObj
        annotateRect  = if ($null -ne $btnAnnotate) {
          $pt = $btnAnnotate.PointToScreen([System.Drawing.Point]::new(0, 0))
          [ordered]@{ left = $pt.X; top = $pt.Y; width = $btnAnnotate.Width; height = $btnAnnotate.Height }
        } else { $null }
        notesRect     = if ($null -ne $btnNotes) {
          $pt = $btnNotes.PointToScreen([System.Drawing.Point]::new(0, 0))
          [ordered]@{ left = $pt.X; top = $pt.Y; width = $btnNotes.Width; height = $btnNotes.Height }
        } else { $null }
        items         = $stateItems
      }
      $sig = ConvertTo-Json -InputObject $payloadObj -Depth 10 -Compress
      if ($sig -ne $lastStateSignature) {
        $lastStateSignature = $sig
        $tmpState = $StateOut + '.tmp'
        $sig | Set-Content -Encoding UTF8 -LiteralPath $tmpState
        Move-Item -LiteralPath $tmpState -Destination $StateOut -Force
      }
    }

    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 60
  }
} finally {
  if ($null -ne $barForm) { $barForm.Dispose() }
  foreach ($f in $boxForms) { $f.Dispose() }
  foreach ($f in $badgeForms) { $f.Dispose() }
}
