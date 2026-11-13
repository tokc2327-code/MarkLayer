# 页面批注到 MCP 回复演示

2026-11-13，本地真实浏览器和本地 Worker 的演示。成片：[demo.mp4](demo.mp4)（29 秒，1280×900，H.264，约 156 KiB）；[缩略图](thumbnail.png)。

## 实际链路与边界

- 浏览器在本地 Web Viewer 中打开 `https://example.com`，用真实工具栏创建矩形、高亮和评论 pin。矩形与高亮是绘图对象，评论是可回复的批注；它们不是三条独立的评论。
- 脚本向本地房间的 `/s/<id>/mcp` 发送 JSON-RPC `tools/call`：`marklayer_read_page` 读页面，`marklayer_list_annotations` 读到一条评论和其 `visualContext` 中的 rectangle、highlight；`marklayer_reply` 写入改法，`marklayer_get_annotation` 回读同一评论线程，作者为 `scripted-demo`。浏览器侧栏也实际显示该回复。房间只保存在本机，示例房间一天后过期。
- 鼠标操作、评论、MCP 客户端和回复内容均由脚本代替真人及 AI 模型；没有调用模型，也没有修改网页代码。页面右上角的英文说明条是演示脚本叠加的字幕，不是产品 UI 或 MCP 返回内容。隔离浏览器上下文预先关闭支持提示卡。
- 视频由运行期间的浏览器截图序列合成，约每 0.5 秒采样一次，按 2 fps 播放；截图耗时会造成采样间隔不均，因此它是低帧率、非严格实时的过程记录，不是连续桌面录屏，没有声音或鼠标指针。部分拖动中间过程可能被跳帧。Playwright 自带视频编码器在本机缺失，故使用已有 FFmpeg 合成。

## 时间轴（成片近似）

- 00:00–00:07：加载网页，选择矩形并框选。
- 00:07–00:14：绘制高亮，添加评论。
- 00:14–00:23：脚本依次调用读取页面、列出批注和回复工具。
- 00:23–00:29：展开原评论线程，显示回复并进行 MCP 回读。

## 重跑

需已有 Bun、已安装的项目依赖、本地 FFmpeg、能运行 `browser_run_code_unsafe` 的 Playwright MCP 浏览器及对 example.com 的访问。以下为本机 PowerShell；按实际工作区修改 `demo.js` 顶部的 `out` 绝对路径。截图文件会写入该目录，重跑前应移走或删除旧的 `frame-*.png`，避免残留尾帧。

```powershell
cd apps/site
bun run build
cd ../worker
bun run build
bunx wrangler d1 migrations apply marklayer --local
bunx wrangler dev --local --port 5199
```

保持 Worker 运行，在 Playwright MCP 中先打开任意页面，再以 `browser_run_code_unsafe` 的 `filename` 参数执行 `acceptance/demo-2026-11-13/demo.js`。脚本返回 MCP 实际结果；仅在成功读到两种绘图对象、写入并回读回复且网页中回复可见时结束。然后从仓库根目录合成并检查：

```powershell
ffmpeg -y -framerate 2 -i acceptance/demo-2026-11-13/frame-%04d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart acceptance/demo-2026-11-13/demo.mp4
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height,r_frame_rate -of json acceptance/demo-2026-11-13/demo.mp4
```

本次验证：脚本成功返回 58 帧及上述 MCP 数据；`ffprobe` 读到 H.264、1280×900、2 fps、29 秒；缩略图经人工视觉检查可见矩形、高亮、评论和原线程回复。此提交未修改产品功能代码，未运行全仓测试。
