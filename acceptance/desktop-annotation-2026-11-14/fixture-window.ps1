param(
  [int]$X = 160,
  [int]$Y = 140,
  [int]$Width = 520,
  [int]$Height = 300,
  [string]$Title = 'MarkLayer Desktop Fixture',
  [string]$ReadyPath = ''
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FixtureDpi {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

  [DllImport("user32.dll")]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
'@

[void][FixtureDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
[void][FixtureDpi]::SetThreadDpiAwarenessContext([IntPtr](-4))

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.Name = 'FixtureWindow'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point($X, $Y)
$form.Size = New-Object System.Drawing.Size($Width, $Height)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

$header = New-Object System.Windows.Forms.Label
$header.Name = 'lblHeader'
$header.Text = 'MarkLayer Self-Built Acceptance Fixture'
$header.Location = New-Object System.Drawing.Point(24, 20)
$header.Size = New-Object System.Drawing.Size(460, 28)
$header.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($header)

$script:saveClicks = 0
$script:cancelClicks = 0

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Name = 'lblStatus'
$statusLabel.Text = 'saveClicks=0;cancelClicks=0'
$statusLabel.Location = New-Object System.Drawing.Point(24, 56)
$statusLabel.Size = New-Object System.Drawing.Size(460, 26)
$statusLabel.Font = New-Object System.Drawing.Font('Consolas', 10)
$form.Controls.Add($statusLabel)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Name = 'btnSave'
$btnSave.Text = 'Save'
$btnSave.AccessibleName = 'Save'
$btnSave.Location = New-Object System.Drawing.Point(32, 120)
$btnSave.Size = New-Object System.Drawing.Size(180, 56)
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnSave.ForeColor = [System.Drawing.Color]::White
$btnSave.FlatStyle = 'Flat'
$btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Name = 'btnCancel'
$btnCancel.Text = 'Cancel'
$btnCancel.AccessibleName = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(260, 120)
$btnCancel.Size = New-Object System.Drawing.Size(180, 56)
$btnCancel.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$btnCancel.FlatStyle = 'Flat'
$btnCancel.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$form.Controls.Add($btnCancel)

function Write-State {
  if ([string]::IsNullOrWhiteSpace($ReadyPath)) { return }
  $wr = New-Object FixtureDpi+RECT
  [void][FixtureDpi]::GetWindowRect($form.Handle, [ref]$wr)
  $savePt = $btnSave.PointToScreen([System.Drawing.Point]::Empty)
  $cancelPt = $btnCancel.PointToScreen([System.Drawing.Point]::Empty)
  $payload = [ordered]@{
    pid = $PID
    hwnd = [int64]$form.Handle
    processName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
    title = $form.Text
    saveClicks = $script:saveClicks
    cancelClicks = $script:cancelClicks
    windowRect = [ordered]@{
      left = $wr.Left
      top = $wr.Top
      width = ($wr.Right - $wr.Left)
      height = ($wr.Bottom - $wr.Top)
    }
    buttons = [ordered]@{
      btnSave = [ordered]@{
        left = $savePt.X
        top = $savePt.Y
        width = $btnSave.Width
        height = $btnSave.Height
      }
      btnCancel = [ordered]@{
        left = $cancelPt.X
        top = $cancelPt.Y
        width = $btnCancel.Width
        height = $btnCancel.Height
      }
    }
  }
  $tmp = "$ReadyPath.tmp"
  [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Path $tmp -Destination $ReadyPath -Force
}

$btnSave.Add_Click({
  $script:saveClicks++
  $statusLabel.Text = "saveClicks=$($script:saveClicks);cancelClicks=$($script:cancelClicks)"
  Write-State
})

$btnCancel.Add_Click({
  $script:cancelClicks++
  $statusLabel.Text = "saveClicks=$($script:saveClicks);cancelClicks=$($script:cancelClicks)"
  Write-State
})

$form.Add_Shown({
  $form.Activate()
  Write-State
})

$form.Add_LocationChanged({ Write-State })

[System.Windows.Forms.Application]::Run($form)
