# 原生缩放验收：未覆盖

- **通过**：Chrome 157.0.8103.52 有窗口启动；以 `--enable-unsafe-extension-debugging` 和 CDP `Extensions.loadUnpacked` 加载本工作区构建的扩展。没有使用 `--load-extension`。
- **未覆盖**：真实快捷键缩放、各缩放下新建评论、拖动 pin、重开评论框及像素误差。两种输入尝试均未造成页面尺寸或 DPR 变化，不能当作缩放成功；扩展仅加载，未激活批注层。
- **未覆盖**：修复前后对比：没有测到 pin，无法判断是否存在错位，也没有修改产品代码。

`probe.mjs` 在独立临时 Chrome profile 打开多层 DOM 的本地 fixture，先使用 Windows SendKeys（AppActivate 返回 True），随后使用页面 CDP `Input.dispatchKeyEvent`。这两种方法均未读到缩放变化。原始读数在 [probe.json](probe.json)，逐次页面截图在本目录；截图是页面视口，并非桌面整屏。

所有采样：DPR 1.5、visualViewport.scale 1、innerWidth 1266、innerHeight 806；目标 rect x=325.3333、y=164、width=420、height=220 CSS px。没有 pin 坐标，因此误差不可计算。DPR 1.5 是本机基线，不代表完成 150% 浏览器缩放。原生桌面控制通道尝试返回 `Computer Use native pipe is unavailable ... 系统找不到指定的文件`，无法通过该通道补验。
