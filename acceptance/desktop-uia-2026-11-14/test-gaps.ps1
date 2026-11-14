$ErrorActionPreference='Stop'
$o=Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'gaps-observations.json') | ConvertFrom-Json
if (!$o.initial.ok -or !$o.minimized.minimized -or $null -ne $o.minimized.rect -or !$o.restored.ok) { throw 'minimize/restore resolve failed' }
if (!$o.negative.ok -or $o.negative.rect.top -ge 0 -or !$o.edge.ok -or ($o.edge.rect.left+$o.edge.rect.width) -le $o.virtualScreen.right) { throw 'offscreen resolve failed' }
if (!$o.restart.ok -or $o.pid1 -eq $o.pid2 -or $o.initial.hwnd -eq $o.restart.hwnd) { throw 'restart resolve failed' }
'Live observations passed: resolve minimize, restore, partial offscreen, restart.'
