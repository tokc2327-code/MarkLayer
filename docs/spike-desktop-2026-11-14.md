# V0.3 Windows 桌面探路（2026-11-14）

## 结论与路线

Windows 的 UI Automation（UIA）和透明置顶窗足以做一个有证据的单机探针。建议下一步先做小型 Windows UIA 适配器与自有覆盖框，复用现有批注操作和协作层，先完成一个真实应用里的选取、定位、移动和重新打开验证；暂不把 agent-desktop 作为必选依赖。“200 行”只是 spike 量级，不是生产成本估计。跨应用、权限、隐私与 DPI 都仍需验证。

## 1. 语义读取：可以，覆盖取决于应用

用 Windows PowerShell 5.1、UIAutomationClient 读取真实的空白记事本和画图窗口，分别得到 40 和 61 个元素，见 [notepad.json](../spike/desktop-2026-11-14/notepad.json) 和 [mspaint.json](../spike/desktop-2026-11-14/mspaint.json)。包含窗口标题、名称、控件类型、AutomationId、屏幕矩形、启用和可键盘聚焦状态。空矩形保存为 null；枚举时失效的元素跳过。元素以列表保存，并用运行时 ID 与父 ID 表示父子关系；记事本的父 ID 均可在快照中找到，画图有 2 个父 ID 不在快照中，因此其树不完整。运行时 ID 仅供本次快照使用；不同应用与自绘控件可能暴露不完整。

`interactive` 只是 `enabled && keyboardFocusable` 的启发式，并非所有可交互控件的准确判定；需要按 UIA 控件模式和操作验证。没有读取控件值或文档内容；真实使用仍需控制快照、截图中可能出现的隐私信息。

## 2. 标注：小范围验证可行

在画图的“保存”按钮上用 WinForms 透明置顶窗口画红框，按 100 ms 轮询 UIA 矩形。将目标窗口移动后，按钮和覆盖框均从 `(377,151,48,48)` 变为 `(577,251,48,48)`；[movement.json](../spike/desktop-2026-11-14/movement.json) 记录两次采样，[移动前](../spike/desktop-2026-11-14/overlay-0.png)和[移动后](../spike/desktop-2026-11-14/overlay-1.png)是实际截图。脚本在两个位置各轮询约一秒，不是连续拖动过程的录像；未验证拖拽中延迟、跨屏 DPI、最小化、遮挡、点击穿透、权限隔离和失效重定位。

复现：在交互式 Windows 桌面、仓库根目录执行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File spike/desktop-2026-11-14/probe.ps1
bunx biome check --write spike/desktop-2026-11-14/notepad.json spike/desktop-2026-11-14/mspaint.json spike/desktop-2026-11-14/movement.json
```

脚本会打开记事本和画图、移动画图窗口、拍局部截图。需使用可见的交互式桌面；结果依赖窗口状态及应用版本。快照是实验数据，不作为稳定 locator。

## 3. 接入批注模型：可扩展，不能直接塞网页 target

`packages/types/src/ops.ts` 的 `commentOpSchema` 通过 `anchorable` 带可选 `target`，但 `targetElementSchema` 要求网页 `selector`、`tag`、`markdown`，其 rect/offset 也描述网页坐标。`device: desktop` 表示网页设备模式，不是桌面应用。直接把 UIA 元素伪装成 selector 会误导网页解析器。

最小方案是在 `anchorable` 增加可选、带 `kind: 'windows-uia'` 的 `desktopTarget`，保留旧 `target` 以兼容旧数据；内容包括应用/窗口识别、AutomationId、控件类型、名称、必要的祖先路径，以及捕获时矩形和相对锚点。显式定义屏幕物理像素、DPI 与坐标转换；运行时 ID、窗口句柄和矩形只作当前会话提示，不能作为跨重启稳定身份。解析须处理重名、多匹配、消失、权限和用户重选，不得猜中即操作。之后需更新 schema 验证、序列化、客户端渲染与读取方，并验证旧客户端对新字段的处理；这里没有实现或测试协议兼容性。

## 4. agent-desktop：值得后续比较，暂不接入

[官方仓库](https://github.com/vercel-labs/agent-desktop)列出 npm 包、Windows UIA snapshot、CLI/C 库和 cursor-overlay；snapshot 可作为问题 1 的候选，但本次未安装或实测，不能宣称其输出字段满足本任务。官方列出的 cursor-overlay 是代理光标，不等于任意控件矩形批注或位置跟随；未找到足以证明它覆盖问题 2 的接口。其 [Windows npm 光标覆盖问题 #619](https://github.com/vercel-labs/agent-desktop/issues/619) 在查阅时仍开放，报告针对 1.2.0，不能外推所有版本。建议先保留自行验证过的 UIA + 覆盖窗路径；需要跨平台语义树、动作和维护时再对固定版本做实际对照。

## 验证边界

这份探针不是产品，也没有实现批注协议、持久重定位或真实协作。截图和快照仅证明本机这两个窗口的观察结果。应用进程可能复用现有实例；请在安全的空白测试会话复现。
