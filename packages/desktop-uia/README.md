# Windows 桌面目标

房间 comment op 的 `desktopTarget` 是独立于网页 `target` 的 Windows UIA 目标；类型与运行时校验定义在 `packages/types/src/ops.ts`。`kind` 固定为 `windows-uia`。`app`、`windowTitle`、`controlType`、`name`、`automationId` 和由窗口到控件父节点的 `ancestry` 用于解析；可选 `appPath`、`windowClass` 缩小匹配范围。`relativeRect` 为相对控件左上角的物理像素矩形；`captured` 是采集时屏幕物理像素矩形及 dpr；`screen` 记录当时屏幕尺寸和 scale。旧数据可以缺少 `relativeRect`，新 CLI 要求提供。标题变化、相同路径的控件或应用重启可能导致找不到或歧义，解析器不会猜测。

用 `node packages/desktop-uia/cli.mjs annotate -Target target.json --text "意见" --room https://host/s/room` 写入，成功只在房间返回 ACK 后输出 opId。当前不支持密码房间；以目标文件所在来源的权限使用，注意该文件包含窗口名称和坐标。
