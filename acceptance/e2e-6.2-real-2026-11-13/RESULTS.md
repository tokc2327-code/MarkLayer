# 本轮补测结果（2026-11-13）

总体 **FAIL**：三项均未覆盖完整验收条件，未修改产品行为。下面保留的此前暂存记录是开始工作前的历史状态，其环境描述已被本轮记录取代。

| 项目 | 结果 | 观察及证据 |
| --- | --- | --- |
| 多人并发 | FAIL（覆盖不完整） | 两个 Edge 会话对同一评论近同时设置不同状态，双方均收到 applied ACK，最终两页与 API 为 resolved；没有触发 NACK 或验证回滚。见 `concurrent.json`、`concurrent.png`。 |
| 断线重连 | FAIL（覆盖不完整） | B 离线约 31.1 秒并出现 WS close/init，A 离线期间提交的状态重连后两页与 API 均为 in_progress；未验证 B 离线提交的待发送操作是否丢失。见 `reconnect.json`、`reconnect.png`。 |
| Edge 原生缩放 | FAIL（未验证） | CDP 发出 Ctrl+0、Ctrl+=、Ctrl+0，但三次 devicePixelRatio 均为 1，无法证明浏览器原生倍率改变；几何与截图仅作尝试证据。见 `zoom.json`、`zoom-baseline.png`、`zoom-plus.png`、`zoom-reset.png`。 |

环境：Edge 157 的现成 9334 CDP，worker 本地 Vite 和本地 D1 迁移；默认启动需要 Cloudflare 远程 AI 认证，本轮仅在临时配置移除 AI 绑定（不涉及以上场景），未改产品源码。两会话为同一 Edge profile 的两个页面。并发分别发送 dismissed 和 resolved，ACK rev 3/4；未观察到被拒，不能推断回滚正确。未进行离线本地操作的丢失测试，也不能据此判断产品缺陷。

缩放几何：pin 圆心（以子元素盒计算）基线 (175.781,128.906)、按 Ctrl+= 后 (225,165)、复位 (175.781,128.906)，但 iframe 尺寸同时变化，且未确认浏览器倍率，不能用这些数值评定锚点偏差。

## 此前暂存记录（历史，已被上方补测取代）

# 6.2 真机验收结果（2026-11-13）

当前分支 `agent/e2e-real-2026-11-13`，HEAD `0da4b5b`。任务书所述基线为 `9702c22`，当前 HEAD 不同。

| 项目 | 结果 | 原因与证据 |
| --- | --- | --- |
| 多人并发 | 未验证 | 本地 worker 未能启动，未建立两个实际会话；见 `environment.log`。 |
| 断线重连 | 未验证 | 本地 worker 未能启动，未执行 30 秒断线和状态回读；见 `environment.log`。 |
| Edge 原生缩放 | 未验证 | 9334 CDP 不可达，隔离 Edge 启动后退出，未测量 pin 和 Comment；见 `environment.log`。 |

未验证不代表产品缺陷，也不能记为通过。没有使用 CSS zoom 或仿真充当本轮真机证据。未生成截图或几何 JSON。

`bun run check` 首次因 Astro 并发写临时文件 ENOENT 失败；`bun run check -- --concurrency=1` 重跑 12/12 任务成功。GitHub CLI 在当前环境报告账号认证不可用；本 worktree 的 Git 元数据位于可写根之外，当前沙箱仅授予读取权限，因此未提交、推送或创建 PR。
