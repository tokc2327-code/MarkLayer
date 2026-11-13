# v0.1 发布验收清单（2026-11-14 夜）

这份清单只写**有证据**的结论。每条给「结论 + 证据在哪」。结论只有三种：通过 / 部分 / 未覆盖。

---

## A. 桌面版 v0.1（Windows UIA 适配器）

代码 `packages/desktop-uia/`（`adapter.ps1` / `overlay.ps1` / `cli.mjs`），说明
`docs/desktop-uia-adapter-2026-11-14.md`，验收 `acceptance/desktop-uia-2026-11-14/`。

| # | 项 | 结论 | 证据 |
| --- | --- | --- | --- |
| A1 | 画图：快照与重定位 | 通过 | `mspaint-snapshot.json`、`mspaint-target.json`、`mspaint-observations.json`（目标为设置按钮，三次数值均为 1091,151,48,48） |
| A2 | 画图：窗口移动 200×100 后仍能定位 | 通过 | 同上，变为 1291,251,48,48 |
| A3 | 画图：改窗口大小后仍能定位 | 通过 | 同上，变为 1435,251,48,48 |
| A4 | 覆盖层：红框 + 局部截图 | 通过（限定场景） | `paint-moved.png`、`paint-resized.png`（只截目标周围局部，不提交整屏） |
| A5 | 目标消失时覆盖层隐藏 | 通过 | `overlay-disappearance.json`（窗口隐藏，覆盖层进程仍在） |
| A6 | 关掉应用重开能找回 | 通过（本次） | `paint-reopened.json`：句柄变化后 resolve 成功 |
| A7 | 记事本：抓取 / 移动 / 改大小 | 通过 | `notepad-target.json`、`notepad-observations.json`、`notepad-resized.png`；快照 806,615,348,48 → 移动后 1006,715（+200/+100）→ 改窗口为 1200×850 后 1106,791 |

未覆盖（写清楚了，不算通过）：跨屏、窗口最小化、点击穿透、连续拖动；身份稳定只做到
「句柄变了能重新 resolve」，没做到跨应用重启仍稳定。

**记事本这一项差点没做成**：Win11 记事本是商店应用，`Start-Process` 返回的 PID
不是窗口所属进程（启动 PID 70852 / 窗口属 PID 67076），按 PID 找窗口永远空。
最终办法是用带随机哈希的临时文件名当标题标记来定位窗口，不依赖进程归属，
也不碰别人开着的记事本。

用法：

```
node packages/desktop-uia/cli.mjs list-windows
node packages/desktop-uia/cli.mjs snapshot -Hwnd <句柄>
node packages/desktop-uia/cli.mjs resolve -Target <target.json>
```

---

## B. Web v0.1

### B1. 真实房间 Comment → AI 读取 → 回应：通过

2026-11-11 视觉闭环验收（`acceptance/vision-loop-2026-11-11/`），真实 AI 读取截图附件
并以 `marklayer_reply` 写回，经 `marklayer_get_annotation` 回查确认。边界：图片经
`marklayer_read_attachment` 落盘后由 CLI 打开读取，不是 image content 直进模型。

### B2. Pair 真人两轮 + 真模型回复 + 连续录屏：通过（带缺口）

2026-11-14 03:11，真人操作由本机真实键鼠完成（不是脚本模拟点击）：
在「欢迎加入」卡片上新建批注 → 右上角出现模型回复 → 同线程追问一次。
首轮 24.414 秒、追问 27.031 秒出回复，两条都由 codex exec 生成并经 MCP 写回。
150 秒连续录屏 `acceptance/demo-2026-11-14-live/out.mp4`（含其他窗口，不推仓库），
`timeline.json` 记时序，`RESULTS.md` 记缺口。

缺口（必须在 v0.2 前补，别当已完成）：

- 房间还没周期性提供**当前视口和光标**，所以「看得到人在看哪」这件事还不成立；
- 扩展这次只验证了「能加载」，页面上的批注走的是同房间 widget；
- 第二次回复暗示「页面已修改」，但页面实际没改 —— 这种表述要在提示里禁掉，
  否则人会以为改完了。

### B3. 浏览器原生缩放（真实按键）：通过

真实键鼠按下 Ctrl+= / Ctrl+- / Ctrl+0，DPR 1.5 → 1.65 → 1.875，innerWidth
1266 → 1151，元素 CSS 几何不变。证据 `acceptance/zoom-native-2026-11-14/`
（读数和七张截图）。之前两轮用 SendKeys 和 CDP 派发都没能真正改变 DPR，那次不算。

### B4. 按需读取视口元素：通过

2026-11-11 真实 Edge（157.0.4341.42，非 headless）验收：一次点击读一批，稳定的一轮
20/20/20/20/20/8，共 108 个唯一选择器，零重复，第 6 批 `done=true`；隐藏 / aria-hidden /
inert / 透明 / 离屏都被排除。证据 `acceptance/3.1-edge-2026-11-11/`。

### B5. 诊断包（agent 读得懂）：进行中

`marklayer_diagnose` 现有 live / partial 两种形态字段不一致，agent 拿 partial 时
看不出缺什么。2026-11-14 在 `feat/diagnose-r2` 上重做：统一形状 + `completeness` /
`missing` + ≤400 字结论摘要 + 规则化 hitChain + 读数接口先给摘要。**不在 v0.1 门槛内**，
但属于「持续优化」这条线。

---

## C. 结论

- **桌面版 v0.1 可以验收**：A1–A7 全过，`packages/desktop-uia` 有可跑的 CLI，
  剩余未覆盖项写在上面，没有含糊的「应该没问题」。
- **Web v0.1 可以验收 B1–B4**，B2 的三个缺口要当面说，不能让人以为 Pair 已经完整。
- 明早要看的两个证据目录：
  `acceptance/desktop-uia-2026-11-14/`、`acceptance/demo-2026-11-14-live/`。
- 六阶段总表（`docs/visual-collaboration-progress.md`）的空框一个都没偷着勾，
  只有真做完的才勾。
