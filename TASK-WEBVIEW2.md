# BRIEF · 桌面覆盖层改用 WebView2 承载 web 现成 UI(2026-11-14)

## 一句话

把桌面 UIA 覆盖层(`packages/desktop-uia/overlay.ps1`)的**自绘 WinForms 界面**换成
**WebView2 里跑 web 端现成的那套批注 UI**;PowerShell 只留窗口、坐标、UIA、键鼠。
**UI 一律照 web 的,不许自己另设计风格、文案、间距。**

## 为什么

xxc 15:51 原话:「按着清单继续跑,我希望今天能看到 Web 版和桌面版都落地,桌面版 UI Web 版就是现成的,别擅自改风格」。
现在桌面覆盖层是自己用 WinForms 画的 Composer / 按钮 / 角标,跟 web 版两套皮,而且 D6 卡在
`WS_EX_NOACTIVATE` 不抢焦点、Composer 的 `$box.Focus()` 拿不到键盘输入。

## 硬约束

1. **不引重框架**:用 WebView2(WinForms 宿主),不要 Electron、不要另起 Chromium。
   - 本机 WebView2 Runtime 已装:**157.0.4341.46**(`C:\Program Files (x86)\Microsoft\EdgeWebView\Application`)。
   - .NET 包装从 NuGet 装**最新版** `Microsoft.Web.WebView2`(x64 的 `WebView2Loader.dll` 必须同目录)。
     不要依赖 Office 自带那份(1.0.2535,Settings 属性名对不上,已踩)。
2. **UI 直接复用**:`apps/extension/components/*` + `apps/extension/entrypoints/content/style.css` 就是来源。
   覆盖层要显示的就是那套工具栏 / Composer / 角标;样式、字体、圆角、颜色**原样**,不许改写。
   web 组件里出现的新文案也不要改。
3. **不动 web 端行为**:web 端现有测试(`bun run test`)必须继续绿。
4. **环境铁律**:
   - 跑 node 一律用 `D:\NODE\node.exe`(PATH 上的 `node` 被 Coopanion 的 shim 顶掉,会报 `Unknown arguments: local, persist-to, …`)。
   - `bun` 可用(1.4.3)。`bun install` / `bun run build` / `bun run check` 都能跑。
   - 别碰 `D:\visual collaboration` 主工作区,只在你的 worktree 里改。

## 已知可行的技术事实(我 16:00 验过,别再重复踩)

- PowerShell 里能加载 `Microsoft.Web.WebView2.Core.dll` + `Microsoft.Web.WebView2.WinForms.dll` 并成功起 Core。
- **`EnsureCoreWebView2Async($null).Wait(20000)` 会挂住**(阻塞 UI 线程,初始化永远等不到)。
  正确姿势:调 `EnsureCoreWebView2Async($null) | Out-Null` 然后自己泵消息
  (`[System.Windows.Forms.Application]::DoEvents()` + `Start-Sleep -Milliseconds 50`)直到 `$wv.CoreWebView2 -ne $null`。
- 透明:`$form.BackColor = Magenta; $form.TransparencyKey = Magenta` + `$wv.DefaultBackgroundColor = Transparent`
  (老 wrapper 没有这个属性,新 NuGet 包有)。
- 参考探针:`workspace/workspace/scripts/webview2-overlay-probe.ps1`(我写的,能跑通 core + NavigateToString)。

## 要做的

1. **`overlay.ps1` 换壳**
   - 覆盖层窗口:无边框、`TopMost`、透明、不抢焦点(`WS_EX_NOACTIVATE`)。
   - 窗口里放一个 WebView2,加载**产物化的 web UI**(见 2)。
   - 保留现有能力:序号角标、跟随目标窗口位置(`relativeRect`)、点击穿透 / 捕捉幕(CaptureCurtain)、
     `Show-CommentComposer` 改成由 WebView2 里的 UI 承担。
2. **web UI 产物**:从 `apps/extension` 打一个「只有批注 UI」的页面(或直接复用 content script 的产物),
   放到 `packages/desktop-uia/web/`,由 WebView2 用 `file://` 或本地 http 加载。
   页面必须能在没有扩展 API 的环境下跑:凡是 `browser.*` 的调用要走 host 注入的 shim,由 PowerShell 侧通过
   `WebMessageReceived` 应答(例如「把这条评论写成房间 op」)。
3. **桥**:`postMessage` / `CoreWebView2.WebMessageReceived` 双向。PowerShell 侧要处理:
   - `annotate:submit` → 调 CLI / HTTP 写进房间(复用 `packages/desktop-uia` 现有写入路径)
   - `capture:element` → 现成的截图裁剪
   - `window:track` → 目标窗口移动时把覆盖层跟上
4. **键盘焦点**:必须实测并写结论 —— WebView2 里的输入框在 `WS_EX_NOACTIVATE` 的宿主窗口下能不能打字。
   若不行,给出替代(例如输入阶段临时允许激活,提交后恢复 `NOACTIVATE`),把实测记进 RESULTS。

## 验收(要留证据,进 `acceptance/desktop-annotation-2026-11-14/`)

- A1 覆盖层出现的是 **web 那套 UI**(截图,和 web 版并排比)
- A2 点 `+ Annotate` → 拖一段 → Composer 打字 → 回车 → **真实房间里出现该 op**(JSON + 截图)
- A3 键盘焦点结论(能打字 / 走替代方案),附实测截图
- A4 `bun run check`、`bun run test` 绿
- A5 覆盖层跟随目标窗口移动、被 topmost 窗口遮挡时回位时间 ≤ 1 秒

## 交付

分支 `feat/desktop-webview2`,基于 `feat/desktop-annotation`。
提交信息写清「UI 改为复用 web 组件」+ 证据文件路径。推上去开 **draft PR**,标题里带 `WebView2`。
做完把 PR 号、提交 sha、A1–A5 的结论各一行报回来。

## 不要做

- 不要改 web 端组件的样式、文案、布局。
- 不要自己发明一套新的批注面板。
- 不要 deploy 任何东西到 Cloudflare(生产部署要 xxc 点头)。
