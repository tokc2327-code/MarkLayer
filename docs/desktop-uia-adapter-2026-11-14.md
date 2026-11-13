# Windows UIA 适配器（部分验收）

覆盖层已在画图中验证移动、改大小和目标消失；记事本的启动 PID 没有可归属顶层窗口，跨应用验收尚未完成。不要把本版本视为生产就绪。

`node packages/desktop-uia/cli.mjs list-windows` 列出窗口；`node packages/desktop-uia/cli.mjs snapshot -Hwnd <句柄>` 枚举控件；`node packages/desktop-uia/cli.mjs resolve -Target <JSON 路径>` 查找目标。重定位返回 `window_gone`、`not_found` 或 `ambiguous:<数量>`，不会选择多个匹配中的一个。`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File packages/desktop-uia/overlay.ps1 -Targets <JSON 数组路径>` 启动透明覆盖层；路径含空格时应加引号。

本机探测将进程设为 DPI aware，UIA 矩形按屏幕物理像素使用；目标里的 dpr 和 screen.scale 是捕获时缩放系数，单显示器逻辑尺寸可由物理尺寸除以该系数得到。跨屏坐标换算未验证。

本版不处理跨屏、最小化、自绘控件、隐私脱敏和跨重启身份稳定性。窗口标题及祖先信息可能变化，可能重名，重新定位并不能证明身份。
