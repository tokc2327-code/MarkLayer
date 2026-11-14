# 桌面标注集成验收报告（2026-11-14）

- **分支**：`feat/desktop-annotation`
- **环境**：Windows PerMonitorV2（主屏 `2560x1600 @ 1.5x`）、Node `v24.21.0`、Bun `1.4.3`、Chrome CDP headless、本地 Cloudflare Worker（`wrangler dev --local` + D1 migrations + Durable Object `AnnotationRoom`）、自建 WinForms 测试窗体（`MarkLayer Desktop Fixture`，含 `btnSave` / `btnCancel` 点击计数器，全程通过 `WindowFromPoint` PID 校验防误触外部窗口）。
- **可复现命令**：
  - 全量静态检查：`bun run check --concurrency=1`
  - 全量单元测试：`bun run test --concurrency=1`
  - 变更范围 Biome 检查：`bunx biome check packages/desktop-uia packages/agent-tools packages/types apps/worker/web/AnnotationDetail.tsx acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`
  - 一键端到端实测：`bun run --cwd apps/worker build && node acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`

## 验收结果（D1–D6）

| 里程碑 | 状态 | 实测结论 | 证据文件 |
| --- | --- | --- | --- |
| **D1 稳定目标定位协议** | **通过** | 确立 `windows-uia` Schema（[desktop-target.schema.json](../../packages/desktop-uia/desktop-target.schema.json) 与 `@marklayer/types` `desktopTargetSchema` 对齐并纳入单测），`capture -Hwnd <hwnd> -AutomationId btnSave` 输出物理像素 `captured`（`dpr=1.5`）、`screen`（`2560x1600, scale=1.5`）、`relativeRect` 与完整 `ancestry`。 | `target-save.json`、`desktop-acceptance.json`、`targeted-result.json` |
| **D2 房间与 Web 查看互通** | **通过** | 本地 Worker 房间持久化写入 `desktopTarget`（`ops`），Chrome CDP 打开 `/s/<roomId>` 零报错（`pageErrors=0, consoleErrors=0`），左侧批注列表与右侧详情 `ContextSection` 正常渲染 `powershell · MarkLayer Desktop Fixture`、`ControlType.Button · Save (#btnSave)`、`180 × 56 px @ 1.5x`；同步验证经典 Web 房间（`https://example.com`）无回归。 | `web-readback.png`、`desktop-acceptance.json` |
| **D3 CLI / 本地入口写入真房间** | **通过** | `cli.mjs annotate` 向本地 `wrangler dev --local` 房间写入 2 条带 `desktopTarget` 的评论均收到 `ack (status: "applied")` 及 `opId`，`GET /api/<roomId>` 完整回读 2 条 op；短 ID 不存在房间（`missing1`）触发明确拒绝（`Room has expired or does not exist`）。 | `room-ops-after-d3.json`、`mock-result.json`、`desktop-acceptance.json` |
| **D4 Agent 通过 MCP 读回** | **通过** | 真实 Worker `/s/<roomId>/mcp` 实测：`marklayer_list_annotations({})` 返回 2 条、`{ desktop: true }` 返回 2 条、`{ desktop: false }` 返回 0 条（Web 基线房返回 1 条），`marklayer_get_annotation` 返回完整 `btnSave` `desktopTarget`，`marklayer_get_feedback` 汇总正确。 | `mcp-readback.json`、`desktop-acceptance.json`、`targeted-result.json` |
| **D5 桌面 Overlay 呈现与穿透** | **部分** | 实测 1.5x DPI 下两处同控件标注 red box 零像素误差（`initialBoxVsButtonDiffPx=0`）、角标 `#1`（`left=223`）与 `#2`（`left=259`）自动错位无重叠、窗体移动 `(+100,+70)` 后 Overlay 同步跟随至 `(323,375)`（耗时 `1222ms` 含状态读写），且 `WindowFromPoint` 在红框中心穿透 `PassthroughForm` 命中底层 `btnSave`（`targetOwnerPid` 为测试窗体 PID）；但当前无头代理会话处于桌面锁定/分离状态，`SetCursorPos`/`CopyFromScreen` 不可用，点击触发回退 `win32MessageFallback`、裁剪截图回退 `printWindowComposite`。 | `overlay-two-badges.png`、`overlay-moved.png`、`desktop-acceptance.json` |
| **D6 桌面端交互创建与双向协作** | **部分** | 实测完成交互闭环：点击悬浮条 `+ Annotate` -> `CaptureCurtain` 接管屏幕（拖拽期间 `btnCancel` 零泄漏点击 `cancelClicks=0`）-> 框选 `btnCancel` 子区域（`relativeRect: 12,10,156x36`）-> 弹出 `Show-CommentComposer` 输入 `"Interactive Cancel note"` 提交 -> `OutboxDir` 转 WebSocket 写入房间 -> Overlay 刷新为 3 条（`Notes (3)`）且 MCP 读回 `mcpCountAfterD6=3`；同样因当前会话锁屏，拖拽与弹窗输入以 Win32 窗口消息回退完成，物理鼠标键盘体验与密码锁定房间（`4401`）真实 Worker 联调待解锁环境补测。 | `overlay-d6-created.png`、`room-ops-after-d6.json`、`desktop-acceptance.json` |

## 实测过程发现并修复的问题

1. **多条桌面标注合并为单元素数组（`overlay.ps1`）**：`Read-TargetItems` 原先同时使用了 `return ,$items` 与调用方 `@(Read-TargetItems $Targets)`，导致 2 条及以上标注被二次包裹成二维数组引发成员枚举失败，已修复为直接 `return $items`。
2. **1.5x DPI 下角标与悬浮条文字裁切（`overlay.ps1`）**：`NonActivatingToolForm` / `PassthroughForm` 使用物理像素尺寸（`AutoScaleMode = None`），但字体误用 `GraphicsUnit::Point` 导致 150% DPI 下 `#1` 被裁成 `#`、`+ Annotate` 被裁成 `+ Anno`；已统一改为 `GraphicsUnit::Pixel` 并使用 `TextRenderer::MeasureText` 动态计算角标宽高。
3. **无物理光标时的拖拽坐标来源（`overlay.ps1`）**：`CaptureCurtain` 原先依赖 `GetCursorPos`，现改用 `$s.PointToScreen($e.Location)`，在真实鼠标与窗口消息下都能精确采集物理坐标与自定义 `relativeRect`。

## 还差什么

1. **解锁交互桌面复测物理硬件输入与 DWM 屏幕抓拍**：在已登录、未锁屏的 Windows 桌面会话下运行 `node acceptance/desktop-annotation-2026-11-14/run-acceptance.mjs`，验证 `hardwareCursorMoved=true`、`mouse_event` 真实硬件点击穿透/拖拽、`SendKeys` 真实键盘输入以及 `CopyFromScreen`（而非 `PrintWindow` 合成）抓图通过。
2. **多显示器（跨不同 DPI 屏幕）现场验证**：验证窗体从 `1.5x` 屏拖到 `1.0x` 副屏时的 `PerMonitorV2` 动态矩形与框线对齐精度。
3. **非 WinForms 宿主（WPF / Electron / 原生 Win32）与真实 Worker 密码房（`4401`）联调**：当前 `4401` 密码鉴权已在 `reproduce-mock.mjs` 通过，真实 Worker 下设置房间密码的自动化端到端用例尚可补充。
