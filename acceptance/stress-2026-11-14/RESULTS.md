# 并发压测记录（2026-11-14）

## 第四轮补测

本机 Wrangler 4.127.1、本地 D1、Chrome 无头会话；HTTP MCP 与 stdio MCP 均连接本机隔离房间，未访问生产。功能实现位于本分支，语义表保存在房间 Durable Object；注册的 `version` 是查询返回的房间操作游标，同一 `(page, name)` 首次写入获胜，后到者 `duplicate_semantic` 拒绝，旧游标返回 `version_conflict`。查询与注册受房间访问门禁约束，写入沿用批注编辑权限。

1. **跨房同时写入：本轮未扩展。** 第三轮仅覆盖跨房同时新增批注，拖动及线程回复同时跨房写入仍未覆盖。
2. **冲突报错原文：批注过期版本冲突仍未覆盖。** 语义注册同键冲突本轮实际返回 `duplicate_semantic: 该页面的语义名称已经注册`；这不能替代批注冲突 NACK 的证据。
3. **注册语义接口并发：通过本轮场景。** 四个独立 HTTP MCP 会话同时注册同一页面、同一名称和元素：1 次成功，3 次带原因拒绝，无重复；另四个不同名称同时注册均成功，四次并发查询完整结果一致（5 条），无 JSON-RPC/HTTP 错误，预期工具拒绝 3 次。`round4-semantics.json` 包含请求、响应和该阶段最终表快照。随后独立 stdio MCP 进程实际查询、注册另一条并读回，见 `round4-stdio.json`。该轮没有并发跨房注册，不能据此判断跨房语义串台。
4. **延迟分位数及 30 秒断线：本轮已测。** 6 个浏览器，一个客户端离线 30.226 秒并显式关闭 socket；离线期间另一个客户端发送 20 条操作，恢复后原客户端发送 10 条。逐帧按 clientOpId 匹配发送到 ACK，以 CDP 单调时间差计时，最近秩法：全轮 ACK n=32，p50 485.78 ms、p95 573.68 ms、max 582.69 ms；离线期间在线端写入 n=20，p50 484.64 ms、p95 498.91 ms、max 499.59 ms；恢复端写入 n=10，p50 543.05 ms、p95/max 582.69 ms。另有 1 条无效图层 NACK，不计入 ACK 分位数；23+10 条发送均有回执。最终六个客户端与服务端各 31 条、逐字段一致，每客户端缺失和额外均为 0。逐条数据和快照见 `round4-offline-raw.json`、`round4-offline-summary.json`。这不是 30 次独立断线的重连耗时分布。

另一次与重新构建过程重叠的运行中，恢复端 10 条写入虽收到 applied ACK，快照读取时其他客户端和服务端尚无这 10 条，见 `round4-reload-raw.json` 和 `round4-reload-summary.json`；无法确定原因，不能把该次称为收敛。上述稳定构建上的复测与它分开报告。

验证：`bun run check` 12/12，`bun run test` 重跑 12/12；首次全仓测试在浏览器压测并行时有 1 项扩展测试超时，停止本轮服务后重跑通过，不能确定超时原因。`bunx biome check --write acceptance/stress-2026-11-14` 执行成功（有警告）。

重跑：构建并在独立端口启动本地 Wrangler 后设置 `STRESS_BASE`，运行 `node acceptance/stress-2026-11-14/round4-semantics.mjs`、`node acceptance/stress-2026-11-14/round4-stdio.mjs`、`node acceptance/stress-2026-11-14/round4-offline.mjs`、`node acceptance/stress-2026-11-14/analyze-round4.mjs`。stdio 脚本使用本机 5397 端口和已构建 CLI；离线脚本需本机 Chrome 及构建好的扩展。脚本覆盖同名证据。

## 第三轮补测

本轮基线 `2bb43c6`，本地 Wrangler 和四个独立 Chrome 157 无头会话；每个浏览器通过 CDP `Extensions.loadUnpacked` 加载扩展。`round3.mjs` 复用上一轮的浏览器连接、应用本地变更管线及 CDP 采集；`round3-raw.json` 保存事件和客户端完整 ops，`analyze-round3.mjs` 生成比对及逐条回执。仅代表本机这一轮，未访问生产房间。

1. **跨房同时写入：未覆盖完整场景。** A、B 各两个客户端，四条独立批注通过真实应用管线在约 1 ms 内发送，均 ACK；A/B 服务端各 3 条，ID 交集为 0，四个客户端按 ID 排序后与各自服务器快照逐字段一致。原始快照分别为 `round3-room-a.json`、`round3-room-b.json`，比较在 `round3-summary.json`。本轮未在两房同时操作拖动及线程回复，因此不把整个要求标为通过。
2. **冲突报错原文：未覆盖。** 同房两个客户端对同一 op 的 text 字段同时发出不同值，CDP 发送时间相差 0.113 ms，均收到 applied ACK（rev 4、5），并未出现冲突 NACK；因此没有被拒方、回滚或冲突报错原文可记录。wire schema 的 update_op 没有基于旧版本的前置条件字段；本轮没有实际提交可识别的过期版本并收到拒绝，过期场景也未覆盖。此前无效图层 NACK 不能冒充冲突报错。
3. **注册语义接口并发：未覆盖。** 四个真实 MCP 会话并发 `tools/list` 的返回中无语义注册或查询工具；实际并发四个 HTTP 语义查询返回 200 且均为 `{"semantics":[]}`，见 `round3-semantics.json`。源码中的 `registerUiSemantic` 标为仅供可信服务端调用，未暴露网络写路由；因此没有并发注册、注册后查询或注册后的 dump，不能判断重复注册及串台。
4. **延迟分位数：未覆盖完整断线轮次。** 本轮 6 条发出的变更均匹配 ACK，无遗漏；CDP 帧单调时间戳之差分别为 91.04、91.15、73.30、52.73、20.82、13.75 ms，最近秩法 p50 **52.73 ms**、p95 **91.15 ms**、max **91.15 ms**（n=6）。另主动关闭 socket 五次，从关闭调用前到以 100 ms 轮询观察到 init 的耗时为 1175、1071、1178、1179、1071 ms，p50 **1175 ms**、p95/max **1179 ms**（n=5，含轮询和调度误差）。这些不是上一轮 30 秒网络离线恢复的多次分布；该断线轮次重连耗时分布仍未覆盖。

重跑：按下文启动本地服务，依次运行 `node acceptance/stress-2026-11-14/round3.mjs`、`node acceptance/stress-2026-11-14/analyze-round3.mjs` 和 `node acceptance/stress-2026-11-14/round3-semantics.mjs`；会覆盖本轮 JSON。脚本采用隔离的临时浏览器配置目录和本地新房间。

## 第二轮补测

本轮的原始 CDP 事件、各阶段每个客户端的完整内存 ops 和服务器快照见 `round2-raw.json`；脚本 `round2.mjs`。这些结论限于本机一次运行，不代表大规模或远端环境。

- **同一元素并发拖动：通过本轮场景。** 六个独立 Chrome 会话打开同一房间的看板；客户端 0、1 同时按下并拖动同一张卡片，从 Open 放到 In progress。两条 `update_op` 发送时间相差 4 ms，分别收到 `applied` ACK，延迟 54 ms、57 ms；没有被拒者。六个客户端的本地卡片最终均为 `in_progress`。本轮两人拖向同一列，不代表不同目标的冲突解决已验证。
- **主动拒绝与回滚：通过本轮场景。** 客户端 0 经应用自身的本地变更管线，乐观地把该批注 `layerId` 改为不存在的 `does-not-exist`。27 ms 后收到 NACK，原文 `code: layer_unavailable`，`reason: 目标图层不存在或不可用`；本地恢复为 `default`，页面出现相同原因，最终服务器对应对象一致。这是无效图层拒绝，不是声称并发拖动触发了拒绝。
- **离线与补齐：通过本轮场景。** 对客户端 0 调用 `Network.emulateNetworkConditions` 离线 30.079 秒。由于离线模拟本身不会立即关闭已有 WebSocket，脚本同时显式关闭该客户端的房间 socket；CDP 随后记录 5 次重连失败，原因均为 `net::ERR_INTERNET_DISCONNECTED`。离线第 22 秒客户端 2 使用应用的本地变更管线新增一条独立批注并收到 ACK；恢复前客户端 0 的内存只有 1 条，恢复网络后第 1 次重连成功，`init` 包含 2 条。恢复后六个客户端和服务器各有 2 条，完整对象逐字段相等，逐客户端缺失 **0 条**、额外 **0 条**。共 6 次重连尝试，其中 5 次失败、1 次成功；此处不将脚本主动关闭计作服务端主动断线。
- **跨房隔离：通过本轮只读对照。** 第二房间独有 `room-B-only`；客户端 5 导航至该房间后读到 1 条且与 B 的服务器快照完全一致。与此同时客户端 1 的 A 房间读到 A 的 2 条，没有 B 的标记；B 中也没有 A 的两条。此项未覆盖两房同时写入的隔离。
- 本轮记录 4 次关联变更回执：3 ACK、1 NACK，均有对应发送帧。发送到回执的耗时分别为 54、57、27、26 ms；四个样本的 p50 为 54 ms、p95 为 57 ms（排序后取 `floor(n × p)`）。

重跑：按下方步骤启动本地服务后运行 `node acceptance/stress-2026-11-14/round2.mjs`，会覆盖第二轮 JSON 和截图；再运行 `node acceptance/stress-2026-11-14/analyze-round2.mjs` 生成 `round2-summary.json`。脚本使用构建产物的模块导出读取应用自身 `operations` 信号，并只为无效图层和离线期间新增操作调用应用本地变更管线；拖放通过 CDP 鼠标事件完成。该导出名依赖当前构建，重建后若变化需核对，不能把读取失败当作空集合。

第一轮多 AI 的跨房同时写入、注册语义接口及冲突报错仍未覆盖，因此不能据本轮宣布完整多 AI 压测通过。

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
