# Pair presence 验收记录（2026-11-14）

真实 Chrome 157.0.8103.52，独立临时 profile、headless 模式，通过 CDP 加载本次构建的扩展。为连接隔离的本地 Worker，测试脚本只修改临时扩展副本的 API origin 并增加 localhost 主机权限；并用 CDP 从扩展 service worker 注入 content script。房间、D1 和 fixture 均为本地测试数据。`chrome-result.json` 保存 MCP 读取结果；这不是物理鼠标操作，也不是对线上部署的验证。

- 页面滚动至 Y=700，CDP 移动鼠标至 client (120, 180)。MCP 返回 viewport 758×482、DPR 1、文档 743×4016，cursor 为文档 CSS px (120, 880)，`stale: false`。
- 使用 CDP 冻结页面 11 秒，MCP 再次读取同一时间戳和坐标，`stale: true`。恢复页面后导航，MCP 返回空成员列表。
- 自动测试覆盖 250ms 节流、静止 1 秒后无光标发送、滚动坐标换算、客户端离开消息、10 秒 stale、60 秒丢弃、服务端断线清除、watch 日志不增长和 member 过滤。60 秒过期为模拟时钟单测，不是 Chrome 等待实测。
- Widget gzip 实测 107143 字节，预算 107520 字节，余量 377 字节；未调整预算。

复现脚本 `chrome.mjs` 使用本机 Chrome、独立 profile、19479–19481 端口和独立本地 Wrangler 数据目录；需要先构建扩展和 Worker，并对该本地目录运行 D1 migrations。脚本关闭自身启动的进程，不操作其他浏览器窗口。
