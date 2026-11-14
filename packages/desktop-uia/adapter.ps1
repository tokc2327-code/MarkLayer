param(
  [Parameter(Mandatory=$true)][ValidateSet('list-windows','snapshot','resolve','capture')][string]$Command,
  [long]$Hwnd,
  [string]$Target,
  [string]$AutomationId,
  [string]$Name,
  [string]$ControlType,
  [int]$X = [int]::MinValue,
  [int]$Y = [int]::MinValue
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'uia-core.ps1')

if ($Command -eq 'list-windows') {
  $result = @(Get-DesktopWindows | ForEach-Object {
    @{
      hwnd        = $_.hwnd
      title       = $_.title
      process     = $_.process
      appPath     = $_.appPath
      windowClass = $_.windowClass
      minimized   = $_.minimized
      rect        = $_.rect
    }
  })
  ConvertTo-Json -InputObject $result -Depth 12
} elseif ($Command -eq 'snapshot') {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
  if (!$root) { throw 'Window not found' }
  $nodes = @($root) + @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_ })
  $items = @(foreach ($node in $nodes) {
    try {
      $c = $node.Current
      $parent = $script:UiaWalker.GetParent($node)
      @{
        runtimeId         = ($node.GetRuntimeId() -join '.')
        parentRuntimeId   = $(if ($parent) { $parent.GetRuntimeId() -join '.' } else { $null })
        controlType       = $c.ControlType.ProgrammaticName
        name              = $c.Name
        automationId      = $c.AutomationId
        rect              = (ConvertTo-RectMap $c.BoundingRectangle)
        enabled           = $c.IsEnabled
        keyboardFocusable = $c.IsKeyboardFocusable
        ancestry          = $(if ([System.Windows.Automation.Automation]::Compare($node, $root)) { @() } else { Get-ElementAncestry $node $root })
      }
    } catch { }
  })
  ConvertTo-Json -InputObject $items -Depth 30
} elseif ($Command -eq 'capture') {
  if ($X -ne [int]::MinValue -and $Y -ne [int]::MinValue) {
    $captured = Get-TargetAtPoint $X $Y $null
    if ($null -eq $captured) { throw "No UIA target found at ($X, $Y)" }
    ConvertTo-Json -InputObject $captured -Depth 30
    exit
  }
  if ($Hwnd -le 0) { throw 'capture requires -Hwnd or (-X and -Y)' }
  $win = @(Get-DesktopWindows | Where-Object { $_.hwnd -eq $Hwnd }) | Select-Object -First 1
  if (!$win) { throw 'Window not found' }
  $nodes = @($win.element) + @($win.element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_ })
  $match = $null
  foreach ($node in $nodes) {
    try {
      $c = $node.Current
      if ($AutomationId -and $c.AutomationId -cne $AutomationId) { continue }
      if ($Name -and $c.Name -cne $Name) { continue }
      if ($ControlType -and $c.ControlType.ProgrammaticName -cne $ControlType) { continue }
      if (!$c.BoundingRectangle.IsEmpty) {
        $match = $node
        break
      }
    } catch { }
  }
  if ($null -eq $match) { throw 'Matching control not found in window' }
  $captured = Build-DesktopTarget $match $win $null
  if ($null -eq $captured) { throw 'Failed to build desktop target' }
  ConvertTo-Json -InputObject $captured -Depth 30
} else {
  $t = Get-Content -LiteralPath $Target -Raw -Encoding UTF8 | ConvertFrom-Json
  $res = Resolve-DesktopTarget $t
  ConvertTo-Json -InputObject $res -Depth 10
}
