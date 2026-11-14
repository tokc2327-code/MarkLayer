# Pair 房间视口与光标

扩展通过已有房间 WebSocket 上报视口和鼠标位置。视口每 5 秒刷新一次；鼠标移动时最多每 250 毫秒发送一次，超限样本直接丢弃，不排队。静止时没有光标定时发送；下一次视口刷新会清空已静止至少 1 秒的光标。视口坐标和尺寸单位为 CSS px，光标为文档 CSS px（client 坐标加滚动偏移）。

房间把每个连接的最后数据放在 WebSocket 附件中，以便 Durable Object 休眠后读取；超过 10 秒标记 stale，读取时清除超过 60 秒的数据。页面离开及连接 teardown 会清除该连接的 presence。MCP 的 `marklayer_room_presence` 按需读取，可用 member 过滤；它不进入 annotation watch 日志。上报不包含截图、DOM、URL 或焦点选择器。

本次没有实现焦点选择器；光标停止后直到下一次视口刷新才从结果清空。扩展之外的 widget 和网页宿主没有启用上报。详细验收及边界见 `acceptance/pair-presence-2026-11-14/RESULTS.md`。
