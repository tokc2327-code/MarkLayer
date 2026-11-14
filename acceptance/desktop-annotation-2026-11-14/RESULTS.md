# 桌面标注集成验收报告（2026-11-14）

- **分支**：`feat/desktop-annotation`
- **硬件与系统环境**：Windows PerMonitorV2（单屏 `\\.\DISPLAY5` 逻辑 `1707x1067` / 物理 `2560x1600 @ 1.5x`）、Node `v24.21.0`、Bun `1.4.3`、Chrome CDP headless、本地 Cloudflare Worker（`wrangler dev --local` + `--persist-to` D1 + Durable Object `AnnotationRoom`）、自建 WinForms 测试窗体（`MarkLayer Desktop Fixture`，含 `btnSave` / `btnCancel` 点击计数器与 `WindowFromPoint` PID 白名单防误触）。
- **可复现命令**：
  - 全量静态检查：`bun run check --concurrency=1`
  - 全量单元测试：`bun run test --concurrency=1`
  - 变更范围 Biome 检查：`bunx biome check packages/desktop-uia packages/agent-tools packages/types apps/worker/web/AnnotationDetail.tsx acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`
  - 真实桌面端到端复验（在交互桌面 `WinSta0\Default` 下执行，须直指 `D:\NODE\node.exe`）：
    `bun run --cwd apps/worker build && D:\NODE\node.exe acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`

## 验收结果（D1–D6 + 密码房 4401）

| 里程碑 / 验收项 | 本轮前状态 | 本轮后状态 | 实测结论与未完成原因 | 证据文件 |
| --- | --- | --- | --- | --- |
| **D1 稳定目标定位协议（含 1.5x DPI 物理像素）** | 通过 | **通过** | 确立 `windows-uia` Schema（`desktop-target.schema.json` 与 `@marklayer/types` 对齐），`DISPLAY5` `1.5x` 缩放下 `capture` 准确输出物理像素 `captured`（`dpr=1.5`）、`screen`（`2560x1600, scale=1.5`）、`relativeRect` 与 `ancestry`。 | `target-save.json`、`desktop-acceptance.json`、`targeted-result.json` |
| **D2 房间与 Web 查看互通** | 通过 | **通过** | 本地 Worker 持久化 `desktopTarget`，Chrome CDP 打开 `/s/<roomId>` 零报错（`pageErrors=0, consoleErrors=0`），详情面板 `ContextSection` 渲染 `powershell · MarkLayer Desktop Fixture`、`ControlType.Button · Save (#btnSave)`、`180 × 56 px @ 1.5x`；Web 基线房同步通过。 | `web-readback.png`、`desktop-acceptance.json` |
| **D3 CLI / 本地入口写入真房间** | 通过 | **通过** | `cli.mjs annotate` 写入本地 `wrangler dev --local` 房间收到 `ack (status: "applied")`；短 ID 不存在房间 `missing1` 明确拒绝（`Room has expired or does not exist`）。 | `room-ops-after-d3.json`、`mock-result.json`、`desktop-acceptance.json` |
| **D4 Agent 通过 MCP 读回** | 通过 | **通过** | 真实 `/s/<roomId>/mcp` 实测 `marklayer_list_annotations` 支持 `{ desktop: true/false }` 精准过滤，Web 基线房返回 1 条；`marklayer_get_annotation` 完整返回 `btnSave` `desktopTarget`。 | `mcp-readback.json`、`desktop-acceptance.json`、`targeted-result.json` |
| **真实 Worker 密码房鉴权（`4401`）** | 通过 | **通过** | 真实 `wrangler dev --local` + D1 PBKDF2-SHA256 锁定房间下：`cli.mjs annotate` 无密码被拒（`Room is password-protected; pass --password or set MARKLAYER_PASSWORD`）、错密码被拒（`Room rejected the password`）、带 `--password` 写入成功并获 `opId`；MCP 无令牌返回 `HTTP 401`，带 `Authorization: Bearer` 读回 1 条桌面标注（注：Default 桌面硬件复验在 D6 提前中止，该项证据保留自同分支完整运行）。 | `password-room-4401.json` |
| **D5 桌面 Overlay 呈现与穿透** | 部分 | **通过（真实硬件：CopyFromScreen 截图 + SetCursorPos/mouse_event 穿透点击 btnSave）** | 在真实 `WinSta0\Default` 桌面复验全绿：`screenshotModes=["copyFromScreen","copyFromScreen"]`、`clickPassthrough.inputMode="hardwareMouse"`、`hardwareCursorMoved=true`、`saveClicks=1`、`initialBoxVsButtonDiffPx=0`、`badgesDisjoint=true`、`trackLatencyMs=852`、`afterForegroundPid=49432`（透明穿透命中 `btnSave` 且焦点不抢占）；跨多显示器 DPI 切换因仅有单屏 `DISPLAY5` 属硬件缺失，非代码问题。 | `overlay-two-badges.png`、`overlay-moved.png`、`desktop-acceptance.json` |
| **D6 桌面端交互创建与双向协作** | 部分 | **部分** | 在 `WinSta0\exebox-*` 下曾以 Win32 窗口消息走通 `+ Annotate` -> `CaptureCurtain` 拖拽 -> Composer -> 房间/MCP 同步 3 条；在 `WinSta0\Default` 真实硬件路径下，`type-submit` 被 `win32-driver.ps1` 安全断言拦下：`"Safety abort: foreground pid=49432 ('MarkLayer Desktop Fixture') not in allowed=[46932]"`。根因在于覆盖层按设计设置 `WS_EX_NOACTIVATE` / `ShowWithoutActivation` 不抢被测窗体焦点，而来自另一进程的合成点击不能为未激活的覆盖层进程授予 Windows 前台输入权，导致 `Show-CommentComposer` 的 `$box.Focus()` 拿不到键盘焦点；属跨进程合成输入边界而非代码必然缺陷，**唯一未闭环项**：需人工按一次（点击 `+ Annotate`、拖一段、在 Composer 里输入、回车）。 | `desktop-acceptance.json`、`overlay-d6-created.png`、`room-ops-after-d6.json` |

## 真实硬件键鼠复验（WinSta0\Default 桌面执行）

- **执行环境说明**：通过 Coopanion 的 `shell_run` 在真实交互桌面 `WinSta0\Default`（`threadDesk="Default"`、`inputDesk="Default"`、`copyFromScreenAvailable=true`）运行 `D:\NODE\node.exe acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`。命令中必须显式使用 `D:\NODE\node.exe`（Coopanion 的 `shims` 会顶掉默认 `node`，导致 `wrangler` 报 `Unknown arguments`）。
- **状态迁移汇总**：
  - **本轮从「部分」转成「通过」**：**D5 桌面 Overlay 呈现与穿透** —— 由原先 `exebox-*` 隔离桌面的窗口消息/分层合成，升级为真实 `WinSta0\Default` 物理键鼠与真屏抓图全通过：
    - `d5.screenshotModes = ["copyFromScreen", "copyFromScreen"]`（真实 DWM 桌面截屏，见 `overlay-two-badges.png`、`overlay-moved.png`）
    - `d5.clickPassthrough.inputMode = "hardwareMouse"`、`hardwareCursorMoved = true`、`saveClicks = 1`、`afterForegroundPid = 49432`（`SetCursorPos`/`mouse_event` 物理点击穿透红框真实触发 `btnSave` 点击计数）
    - `d5.initialBoxVsButtonDiffPx = 0`、`d5.badgesDisjoint = true`、`d5.trackLatencyMs = 852`、`d5.movedBoxRect = { left: 323, top: 375, width: 180, height: 56 }`
  - **本轮仍为「部分」及精确原因**：**D6 桌面端交互创建** —— 在 `WinSta0\Default` 下点击 `+ Annotate` 并拖拽后，`Show-CommentComposer` 弹窗打开前，合成鼠标点击（由 `win32-driver.ps1` 子进程发起）按 Windows 前台锁定策略不能将前台输入权授予带 `WS_EX_NOACTIVATE` / `ShowWithoutActivation` 样式的覆盖层进程，`win32-driver.ps1` 触发安全保护中止（`Safety abort: foreground pid=49432 ('MarkLayer Desktop Fixture') not in allowed=[46932]`）。真人实际鼠标点击会由 Windows 授予前台权，因此该阻断属于跨进程合成输入边界。
- **脚本健壮性修复**：
  - `run-acceptance.mjs` `finally` 中 `rmSync(workDir)` 在 Coopanion `TEMP` 环境下可能遭遇 `EPERM`，已包裹 `try/catch` 避免覆盖写入报告；
  - 为 `try` 主体补充 `catch` 记录 `report.error` 并用 `process.exitCode = report.ok ? 0 : 1` 如实反馈退出码，确保失败时仍输出 `desktop-acceptance.json` 证据。

## 还差什么（唯一未闭环项）

1. **D6 真人交互闭环（唯一未闭环项）**：需人工在桌面运行 `overlay --interactive` 后按一次真实手操验证：**点击 `+ Annotate` -> 拖一段框 -> 在弹出的 Composer 里输入评论 -> 按回车提交**，确认新批注进入房间并回显红框与角标。
2. **硬件缺失说明（非代码问题）**：当前主机仅接入单块 `\\.\DISPLAY5`（`2560x1600 @ 1.5x`）显示器，缺少第二块不同缩放比显示器，无法实测真跨屏动态 DPI 切换。
