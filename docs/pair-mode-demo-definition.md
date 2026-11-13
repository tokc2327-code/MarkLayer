# Pair 模式演示定义

本任务的 Pair 最小验收要求：agent 同时获得人当前视口、指针位置或选中元素，以及人刚完成的动作；agent 的回复在人的当前视口可见。视口和指针应标明采集时间，避免把旧快照误当成实时状态。

当前房间默认为 Pair，批注可以携带目标元素和创建时的视口快照。但 `RoomCore.apply` 没有保存或向 watch 暴露 `cursor` 消息，`projectAnnotation` 也没有输出 `captureViewport`；房间元数据的 width 是建房时宽度，并非当前视口。因此现状尚不能证明满足上述最小验收，亦未实现本次要求的实时 Pair 闭环。
