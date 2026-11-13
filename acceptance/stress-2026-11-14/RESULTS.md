# 并发压测记录（2026-11-14）

基线 `af2493af`，Windows 11，Bun 1.4.3，Chrome 157.0.8103.52，本地 Wrangler 4.127.1、D1 本地迁移 0001–0016。未访问生产房间。两项均**未通过验收**：下面的实测只覆盖部分要求，缺少的观测不能推断为通过。

## 多用户：未通过验收

- 六个独立 Chrome 用户目录加载同一房间，分别通过 `Extensions.loadUnpacked` 加载扩展；六个页面均显示 6 人在线。`browser.png` 和 `browser-raw.json` 留存页面与会话证据。
- 六个会话通过 CDP 同时选择批注工具、输入并发送各自的 `browser-comment-0` 至 `browser-comment-5`。稍后的服务端快照包含六条各不相同的批注。提交后约 3 秒快照仍为 0，稍后快照为 6；没有更细时间采样，不能据此判断何时持久化或计算延迟。
- 尝试拖动未产生操作，未完成对同一批元素的并发拖动、编辑及线程回复。没有逐条捕获 ACK/NACK，拒绝回滚及原因、错误数、延迟 p50/p95 均未测得；没有采集每个浏览器的完整 ops 集合，无法判断丢失和收敛。
- 对一个页面施加 30 秒 CDP 离线模拟后恢复，随后服务端快照有六条批注；没有捕获 WebSocket 关闭和重新连接事件，也没有在离线期间验证其他客户端写入，因此不能证明真实断线重连、重连次数或回连后收敛。

## 多 AI：未通过验收

四个独立 MCP HTTP 会话连接同一房间。总计 52 次请求（含 4 次初始化），HTTP/JSON-RPC/工具错误 0 次。4 次创建批注、16 次交叉回复、20 次读取单个批注、4 次列表、4 次页面读取。最终四个线程分别读回预期的四条不同回复，共 16/16，未见重复、缺失或错线程；这是本轮样本结果。

| 工具 | 次数 | p50 毫秒 | p95 毫秒 |
| --- | ---: | ---: | ---: |
| create_annotation | 4 | 147.3 | 149.5 |
| list_annotations | 4 | 719.6 | 1007.4 |
| reply | 16 | 746.2 | 1225.6 |
| get_annotation | 20 | 612.6 | 1227.5 |
| read_page | 4 | 1443.4 | 1963.2 |

计时包含 HTTP 往返和响应读取；分位数取排序后下标 `floor(n × p)`，样本小。没有第二房间对照，无法验证跨房串台；没有制造并验证冲突报错，也未调用注册语义接口。原始请求、响应和时长在 `mcp-raw.json`。

## 重跑

在仓库根目录运行 `bun install --frozen-lockfile`、`bun run build`；在 `apps/worker` 运行 `bunx wrangler d1 migrations apply marklayer --local` 和 `bunx wrangler dev --local --port 5199`。另开终端在根目录运行 `node acceptance/stress-2026-11-14/browser-probe.mjs` 与 `node acceptance/stress-2026-11-14/mcp-stress.mjs`。脚本会创建新的本地房间并覆盖同目录 JSON/截图；浏览器脚本使用本机 Chrome 固定路径与 19200–19205 端口，并在系统临时目录创建独立配置目录。它们是部分探针，不是完整验收脚本。

`bun run build` 成功（6/6，2 项缓存），`bun run check` 成功（12/12，11 项缓存）。两个脚本均执行 `bunx biome check --write`；MCP 脚本有一条环境变量缓存声明警告。
