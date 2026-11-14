# 桌面标注集成验收报告（2026-11-14）

- **分支**：`feat/desktop-annotation`
- **环境**：Windows PerMonitorV2（单屏 `\\.\DISPLAY5` 逻辑 `1707x1067` / 物理 `2560x1600 @ 1.5x`）、Node `v24.21.0`、Bun `1.4.3`、Chrome CDP headless、本地 Cloudflare Worker（`wrangler dev --local` + 独立 `--persist-to` D1 + Durable Object `AnnotationRoom`）、自建 WinForms 测试窗体（`MarkLayer Desktop Fixture`，含 `btnSave` / `btnCancel` 点击计数器，操作前通过 `WindowFromPoint` PID 白名单防止误触其他窗体）。
- **执行会话实测诊断（`desktop-acceptance.json -> environment`）**：`sessionId=1`、`winsta=WinSta0`、`threadDesk=exebox-MFN5C5SIUAQOFDKGOYRUIACR36`、`inputDesk=Default`、`monitorCount=1`。尽管用户物理桌面处于解锁状态，代理命令执行器运行在隔离的非输入 Win32 桌面 `exebox-*` 中，Windows 对非输入桌面禁止 `SetCursorPos`/`mouse_event`/`SendKeys` 与 `CopyFromScreen`（`The handle is invalid`）。
- **可复现命令**：
  - 全量静态检查：`bun run check --concurrency=1`
  - 全量单元测试：`bun run test --concurrency=1`
  - 变更范围 Biome 检查：`bunx biome check packages/desktop-uia packages/agent-tools packages/types apps/worker/web/AnnotationDetail.tsx acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`
  - 一键端到端实测：`bun run --cwd apps/worker build && node acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`

## 验收结果（D1–D6 + 密码房 4401）

| 里程碑 / 验收项 | 本轮前状态 | 本轮后状态 | 实测结论与未完成原因 | 证据文件 |
| --- | --- | --- | --- | --- |
| **D1 稳定目标定位协议（含 1.5x DPI 物理像素）** | 通过 | **通过** | 确立 `windows-uia` Schema（`desktop-target.schema.json` 与 `@marklayer/types` 对齐），`DISPLAY5` `1.5x` 缩放下 `capture` 准确输出物理像素 `captured`（`dpr=1.5`）、`screen`（`2560x1600, scale=1.5`）、`relativeRect` 与 `ancestry`。 | `target-save.json`、`desktop-acceptance.json`、`targeted-result.json` |
| **D2 房间与 Web 查看互通** | 通过 | **通过** | 本地 Worker 持久化 `desktopTarget`，Chrome CDP 打开 `/s/<roomId>` 零报错（`pageErrors=0, consoleErrors=0`），详情面板 `ContextSection` 渲染 `powershell · MarkLayer Desktop Fixture`、`ControlType.Button · Save (#btnSave)`、`180 × 56 px @ 1.5x`；Web 基线房同步通过。 | `web-readback.png`、`desktop-acceptance.json` |
| **D3 CLI / 本地入口写入真房间** | 通过 | **通过** | `cli.mjs annotate` 写入本地 `wrangler dev --local` 房间收到 `ack (status: "applied")`；短 ID 不存在房间 `missing1` 明确拒绝（`Room has expired or does not exist`）。 | `room-ops-after-d3.json`、`mock-result.json`、`desktop-acceptance.json` |
| **D4 Agent 通过 MCP 读回** | 通过 | **通过** | 真实 `/s/<roomId>/mcp` 实测 `marklayer_list_annotations` 支持 `{ desktop: true/false }` 精准过滤，Web 基线房返回 1 条；`marklayer_get_annotation` 完整返回 `btnSave` `desktopTarget`。 | `mcp-readback.json`、`desktop-acceptance.json`、`targeted-result.json` |
| **真实 Worker 密码房鉴权（`4401`）** | 待补（仅 mock） | **通过（新增转绿）** | 在真实 `wrangler dev --local` + D1 下使用生产同款 PBKDF2-SHA256 `hashPassword` 锁定房间：`cli.mjs annotate` 无密码被拒（`Room is password-protected; pass --password or set MARKLAYER_PASSWORD`）、错密码被拒（`Room rejected the password`）、带 `--password` 写入成功并获 `opId`；MCP 无令牌返回 `HTTP 401`，带 `Authorization: Bearer` 读回 1 条桌面标注。 | `password-room-4401.json`、`desktop-acceptance.json` |
| **D5 桌面 Overlay 呈现与穿透** | 部分 | **部分** | 本桌面内实测 `1.5x` DPI 0px 对齐（`initialBoxVsButtonDiffPx=0`）、#1/#2 角标无重叠（`left=223`/`259`）、移动跟随 `749ms` 至 `(323,375)`，且 `WindowFromPoint` 穿透 `PassthroughForm` 命中底层 `btnSave`；**仍为「部分」原因**：1）代理命令桌面 `exebox-*` 与交互输入桌面 `Default` 隔离，导致 `SetCursorPos`/`CopyFromScreen` 系统级失效，只能以 `win32MessageFallback` + `printWindowComposite` 替代；2）仅接 1 块 `DISPLAY5` 显示器（硬件缺失），且用户正在使用主机不宜强改全局缩放率，跨屏多 DPI 实机移动未能运行（属环境/硬件限制，非代码问题）。 | `overlay-two-badges.png`、`overlay-moved.png`、`desktop-acceptance.json` |
| **D6 桌面端交互创建与双向协作** | 部分 | **部分** | 本桌面内实测 `+ Annotate` -> `CaptureCurtain` 区域拖拽 `btnCancel`（零泄漏点击 `cancelClicks=0`）-> Composer 输入 `"Interactive Cancel note"` 提交 -> `OutboxDir` / WebSocket 写入房间 -> Overlay（`Notes (3)`）与 MCP 均回读 3 条；**仍为「部分」原因**：同 D5，受限于代理非输入桌面 `exebox-*` 无法跨桌面注入硬件键鼠，交互驱动仍回退为 Win32 窗口消息，真交互桌面的物理键鼠手感需在用户本机普通终端（`WinSta0\Default`）运行同一验收脚本复验。 | `overlay-d6-created.png`、`room-ops-after-d6.json`、`desktop-acceptance.json` |

## 本轮收尾变化汇总（相对上一版验收报告）

- **已从「待补」转为「通过」**：真实本地 Worker 密码保护房间（WS `4401` 拒绝 + `--password` 写入 + HTTP `401` 拒绝 + `Authorization: Bearer` MCP 读回）全链路实测通过（`password-room-4401.json`）。
- **已查明并记录但无法绕过的环境/硬件约束（D5、D6 维持「部分」）**：
  1. **物理键鼠与 `CopyFromScreen`（环境隔离限制）**：代理命令运行在 `WinSta0\exebox-*` 而非用户交互桌面 `WinSta0\Default`，Windows 内核阻止非输入桌面调用 `SetCursorPos`/`mouse_event`/`SendKeys`/`CopyFromScreen`；此为执行隔离边界，未作假通过，已在 `desktop-acceptance.json -> environment` 留下原生诊断证据。
  2. **多屏跨 DPI（硬件缺失 + 防打扰限制）**：现场仅有一块 `DISPLAY5 (2560x1600 @ 1.5x)` 显示器，无第二块不同 DPI 屏幕可供真实跨屏拖移；`1.5x` 单屏物理像素对齐已严格通过。

## 还差什么（人工本地一键复验清单）

1. 在已解锁的本机普通 PowerShell / 终端（处于 `WinSta0\Default` 桌面）执行：
   `node acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`
   即可自动使用真实硬件 `SetCursorPos`/`mouse_event`/`SendKeys` 与 `CopyFromScreen`（脚本内 `hardwareCursorMoved` 与 `copyFromScreenAvailable` 会自动切换为真实硬件路径）。
2. 若后续接入第二块不同缩放（如 `100%`）显示器，可在双屏间拖动测试窗体复验跨屏 DPI 切换。
