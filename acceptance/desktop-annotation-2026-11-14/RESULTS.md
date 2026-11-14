# 桌面批注验收（2026-11-14）

| 项 | 结果 | 证据与原因 |
| --- | --- | --- |
| D1 | 通过 | `packages/types/src/ops.ts` 的 `desktopTargetSchema` 与 `packages/desktop-uia/README.md` 描述窗口、UIA 路径、相对矩形和物理像素；`targeted-result.json` 是相关测试读数。旧数据可缺相对矩形，新 CLI 要求提供。 |
| D2 | 部分 | comment schema 可保留目标，`parseOps` 测试覆盖混合读取；未在真实本地 Worker 房间持久化并通过网页读回。 |
| D3 | 部分 | CLI 已实现并等待 ACK；`mock-result.json` 仅为模拟 WebSocket，未证明真实房间写入。密码房间不支持。 |
| D4 | 部分 | MCP 投影已传递 desktopTarget，测试通过；未从真实 MCP 服务读取真实房间。 |
| D5 | 部分 | 既有覆盖层显示序号并轮询 UIA 位置；未接房间、未解决同目标角标重叠，也未进行本轮真实窗口验收。 |
| D6 | 未覆盖 | 没有从人实际点选或拖动到房间的交互路径。覆盖层仍穿透点击；脚本模拟不是人的交互。 |

全仓 `bun run check --concurrency=1`、`bun run test --concurrency=1` 通过；初次默认并发检查遇到进程内存不足并中断。现有网页验收脚本本轮未运行，不能推断网页端端到端通过。未创建或点击真实桌面窗口，无截图。评分器搜索因 MCP Transport closed 失败。

复现：在仓库根目录运行 `node packages/desktop-uia/reproduce-mock.mjs`，以及 `bun test packages/agent-tools/src/project.test.ts packages/types/src/ops.test.ts`。前者仅测试模拟协议，不会访问真实房间。执行全部检查时可用上述单并发命令。

## 还差什么

接入独立的人机选区和文本输入（同时维持显示层不抢焦点、不吃点击）；房间驱动的角标布局和跟踪；对自建窗口做 DPI、命中 PID、移动、重叠、点击穿透的真实验证；启动隔离 Worker，验证 CLI 写入、网页读取和 MCP 读回，以及既有网页验收脚本；支持或明确拒绝密码房间。D1–D4 未全部通过，本单未通过。
