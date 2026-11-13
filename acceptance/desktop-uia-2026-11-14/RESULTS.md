# Windows UIA 验收记录（2026-11-14）

| 项 | 结果 | 证据 |
| --- | --- | --- |
| 1. 画图快照与重定位 | 通过 | mspaint-snapshot.json、mspaint-target.json、mspaint-observations.json：均为 (1091,151,48,48)，目标为设置按钮 |
| 2. 画图移动 200×100 | 通过 | mspaint-observations.json：变为 (1291,251,48,48) |
| 3. 画图改窗口大小 | 通过 | mspaint-observations.json：变为 (1435,251,48,48) |
| 4. 覆盖层及截图 | 通过（指定场景） | paint-moved.png、paint-resized.png：桌面局部截图可见按钮上的红框及编号；overlay-disappearance.json：关闭画图后覆盖窗隐藏，进程仍在运行 |
| 5. 关闭画图重开 | 通过本次找回 | paint-reopened.json：句柄变化后 resolve 成功；不保证跨重启身份稳定 |
| 6. 记事本抓取、移动、改窗口大小 | 通过 | notepad-target.json、notepad-observations.json、notepad-resized.png：快照 (806,615,348,48)；窗口从 (300,200,1000,700) 移到 (500,300) 后元素为 (1006,715,348,48)，正好 +200/+100；窗口改为 1200×850 后元素为 (1106,791,348,48)，随窗口居中偏移再 +100/+76，元素自身尺寸不变 |

## 关于记事本这一项怎么过的

Win11 的记事本是商店应用，`Start-Process notepad.exe` 返回的 PID **不是**窗口所属进程
（本次启动 PID 70852，窗口属于 PID 67076），所以按 PID 用 EnumWindows 找窗口永远空。
改成**用窗口标题里的唯一标记找窗口**：脚本先写一个带随机哈希的临时文件
`uia-notepad-<8位>.txt` 并用它启动记事本，再按标题包含该标记定位窗口，之后所有
snapshot / resolve 都针对这个句柄。这条办法不依赖进程归属，也不碰别人开着的记事本
（`respanapi.txt` 那个窗口全程没动）。

## 没覆盖的

跨屏、窗口最小化、点击穿透、连续拖动都还没验；覆盖层只在画图场景下验证过。
身份稳定性只做到「句柄变化后能重新 resolve」，没做到跨应用重启仍然稳定。
