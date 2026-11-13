# 真实页面诊断验收（2026-11-13）

## 采集与范围

在 Windows 的无头 Chrome 157 中，加载本工作区构建的扩展，访问由本地静态服务器提供的 `apps/site/dist/about.html`。通过扩展工具栏在标题上发布 comment，再调用评论卡片的“诊断”按钮。使用 CDP 对按钮执行 DOM `click()`；批注落点与提交由 CDP 鼠标事件完成。`comment-op.json` 是从该页面的 IndexedDB `marklayer-drafts` 读回的完整评论 op，`screenshot.png` 显示评论和诊断摘要。没有连接房间，因此这份 op 来自本地草稿，**不是房间 op 或 MCP 读回**；房间同步及 `marklayer_diagnose` / `marklayer_read_diagnosis` 端到端未验证。

## 字段逐项核对

| 字段 | 实测和核对 | 限制 |
| --- | --- | --- |
| 采集时间 | `1794585179862`，即 2026-11-13 15:52:59.862 UTC（北京时间 23:52:59.862）。 | 来自浏览器系统时钟，未校时。 |
| 目标元素 | `h1`，文本 `About the author`，矩形 `(40, 140.015625, 663, 46.625)`；与同页 DOM 读数一致。 | 只验证普通顶层元素。 |
| iframe / shadow 层级 | `iframeDepth: 0`、`shadowDepth: 0`，与该 `h1` 位于顶层文档一致。 | 未验证嵌套或跨域 iframe、shadow 内元素。 |
| 命中与遮挡链 | `covered: false`，命中 `h1`；链为 `h1 → body > div → body → html`。独立 `elementsFromPoint` 多出扩展的 `MARK-LAYER`，其余顺序一致；诊断有意排除扩展覆盖层。 | `html` 的 selector 为空字符串；标签仍为 `html`，该链条不能完全凭 selector 重定位。没有构造真实遮挡场景。 |
| 页面报错 | `pageErrorCount: 0`、`pageErrors: []`。 | 扩展在页面加载后激活，加载前发生的错误可能未被记录；未注入已知错误验证采集。 |
| 失败请求 | `networkFailureCount: 0`、`networkFailures: []`。 | 激活前的请求不在该采集窗口；未注入已知失败请求验证采集。 |
| DPR / 缩放 / 滚动 | `devicePixelRatio: 1`、`scale: 1`、`scrollX: 0`、`scrollY: 0`，与同页 DOM 读数一致；视口 758 × 482 CSS px。 | 非默认缩放与滚动未验证；scale 是 visual viewport scale。 |
| 复现步骤 | 自动生成两步：打开本地页面、定位 `h1`。 | 未包含实际问题操作或预期/实际结果，是定位草稿，不足以复现具体行为故障；本例评论是采集验收而非故障报告。 |
| 完整性 | `source: live-page`、`partial: false`。 | 该标记不代表上述未覆盖场景或房间链路已验证。评论 op 的截图附件 ID 保留在 JSON，附件本体未导出；另附独立 CDP 截图。 |

## 操作步骤

1. 构建站点与扩展；以本地静态服务器提供 `apps/site/dist`，打开 `http://127.0.0.1:9417/about.html`。
2. 在加载扩展后重新导航页面，触发扩展动作，选择 Comment，在标题上落点 `(150, 165)`，提交“诊断验收：检查此标题的页面现场。”。
3. 在评论卡片触发“诊断”，等草稿写入；从页面 IndexedDB 的 `marklayer-drafts` / `drafts` 读取含 diagnosis 的 comment op。
4. 重新打开评论卡片并用 CDP 截图；截图记录诊断摘要。数据中的本地 URL 需要上述服务运行才能再次访问。

## 发现与边界

未修改产品代码。一个可观察的字段缺口是命中链中 `html` selector 为空；尚未判断其对消费者的影响。正常鼠标在评论模式下点击诊断按钮的首次尝试落到了页面并打开新的评论草稿，本次改为 DOM `click()` 成功触发诊断，不能据此确认常规指针交互通过；额外草稿已取消。测试没有连接房间，所以不得把本结果称为 MCP 或房间端到端验收。
