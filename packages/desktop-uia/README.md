# Windows Desktop UIA Annotation (`packages/desktop-uia`)

Desktop targets plug Windows UI Automation (UIA) controls into the same MarkLayer room, op stream, Web viewer, and MCP agent tools as browser annotations.

## Schema (`desktopTarget`)

- Runtime & TypeScript contract: [`desktopTargetSchema`](../types/src/ops.ts) (`DesktopTarget`, carried on `commentOpSchema.desktopTarget`).
- JSON Schema (Draft-07): [`desktop-target.schema.json`](./desktop-target.schema.json).

### Fields

| Field | Required | Description |
| --- | --- | --- |
| `kind` | Yes | Fixed `"windows-uia"`. |
| `app` | Yes | Process name without `.exe` (e.g. `"Notepad"`, `"powershell"`). |
| `windowTitle` | Yes | Exact top-level window title at capture time. |
| `appPath` | No | Full executable path to disambiguate windows. |
| `windowClass` | No | Win32 window class name (`GetClassName`). |
| `controlType` | Yes | UIA `ControlType.ProgrammaticName` (e.g. `"ControlType.Button"`). |
| `name` | Yes | UIA `Current.Name` of the control. |
| `automationId` | Yes | UIA `Current.AutomationId` of the control. |
| `relativeRect` | No* | `{ left, top, width, height }` in physical pixels relative to the UIA control's top-left corner (*optional for backwards compatibility with older ops; required by CLI `annotate` and produced by `capture` / interactive overlay). |
| `ancestry` | Yes | Ordered array of `{ controlType, name, automationId }` from the top-level window down to the direct parent of the target control. |
| `captured` | Yes | `{ left, top, width, height, dpr }` — physical screen pixels and monitor scale at capture time. |
| `screen` | Yes | `{ width, height, scale }` — monitor physical resolution and DPI scale at capture time. |

### Coordinate System & DPI

All UIA, screen, `relativeRect`, and overlay coordinates use **physical desktop pixels** under `PerMonitorV2` (`SetProcessDpiAwarenessContext(-4)` and `SetThreadDpiAwarenessContext(-4)`), set before WinForms loads.

## CLI Commands

```bash
# List visible top-level windows
node packages/desktop-uia/cli.mjs list-windows

# Snapshot UIA tree of a window
node packages/desktop-uia/cli.mjs snapshot -Hwnd <hwnd>

# Capture a schema-compliant target JSON from a window/control or physical point
node packages/desktop-uia/cli.mjs capture -Hwnd <hwnd> -AutomationId <id>
node packages/desktop-uia/cli.mjs capture -X <px> -Y <px>

# Resolve a target JSON back to current physical coordinates
node packages/desktop-uia/cli.mjs resolve -Target target.json

# Write a desktop annotation into a MarkLayer room (waits for room ACK)
node packages/desktop-uia/cli.mjs annotate -Target target.json --text "意见" --room http://127.0.0.1:5173/s/<roomId>
# Password-protected rooms accept --password <pwd> or MARKLAYER_PASSWORD

# Run the click-through overlay connected to a live room (with optional interactive creator)
node packages/desktop-uia/cli.mjs overlay --room http://127.0.0.1:5173/s/<roomId> --interactive
```

## Notes & Constraints

- **Click-through & Non-activating**: Display boxes and numbered badges use `WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` and `ShowWithoutActivation = true`, so they never steal focus or eat clicks.
- **Non-overlapping badges**: Multiple annotations targeting the same or adjacent controls automatically lay out disjoint numbered badges (`#1`, `#2`, ...).
- **Resolution honesty**: Title changes, identical sibling paths without distinct `AutomationId`/`Name`, or app restarts without stable titles fail cleanly (`not_found` / `ambiguous:<n>`) instead of guessing.
- **Room permissions**: Read-only rooms return an error; password-protected rooms require `--password` or `MARKLAYER_PASSWORD`.
