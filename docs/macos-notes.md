# macOS 平台实证笔记

记录各 macOS 版本上以探针 / 实机实验得出的平台行为与陷阱，供开发时查阅；随系统版本演进需复证，代码侧在相应模块注释中同步标注。README 只保留结论级摘要，细节以此文档为准。

## 窗口与 Space（macOS 27.2，26B5091g 实测）

### canJoinAllSpaces 面板搁浅 → 悬停呼出永久失效（v0.19.3 修复）

- **现象**：悬停刘海无法呼出岛屿；全局快捷键表现为静默"收起"（状态机卡在 `.expanded` 而面板实际不可见），此后悬停热区只会不断清零收起倒计时，永不重新展开。用户侧观察为"全屏应用下无法呼出"，偶发可被"重启目标应用"暂时治愈。
- **触发**：Space 生命周期扰动——全屏空间的创建/销毁、应用重启（其全屏 Space 重建）、更新程序强切前台等。扰动后 `canJoinAllSpaces` 窗口可能被窗口服务器留在一个不可见空间上。
- **机制**：搁浅时窗口处于"已置入但不在当前 Space"状态，`orderFrontRegardless()` 静默空转（它在"自己的空间"里本就最前）；状态机不知情照常进入 `.expanded`。
- **修复锚点**：`Core/NotchWindowController.swift` 的 `orderFrontEnsuringVisible()`——置前后用 CGWindowList 自查真实合成状态；未上屏则 `orderOut` 摘下 + 重挂 `collectionBehavior`（强制窗口服务器重算归属）+ 再置前，最多重试 3 次；仍失败由 `restorePresentation()`（应用激活通知）兜底。恢复动作仅在真异常时发生并落一条日志到 `/tmp/notchdeck-debug.log`。
- **保留项**：原始偶发链路（多事件叠加）未在受控环境复现，恢复路径按机制验证；日后再发生时以上日志可回溯。

### 可见性判据只有一路可信

- `NSWindow.isOnActiveSpace` 与**外部进程**读 `CGWindowListCopyWindowInfo` 的 `kCGWindowIsOnscreen` 在 Space 扰动后可能谎报"不可见"（面板实际在屏）。调试/自动化脚本勿依赖外部窗口列表判断面板可见性。
- 唯一可信：进程内用自身 `windowNumber` 查 `CGWindowListCopyWindowInfo(.optionOnScreenOnly, windowNumber)`，见 `NotchWindowController.isCompositedOnScreen`。

### 崩溃组合（禁止使用）

- `collectionBehavior` 上 `union(.moveToActiveSpace)` 与 `canJoinAllSpaces` 并存 → 断言崩溃（27.2 实测，调试期间真实崩过一次）。

## 电源与传感器（macOS 27 起）

- `AppleSmartBattery` 的 mAh 容量键（`AppleRawMaxCapacity` 等）从注册表顶层移入嵌套 `BatteryData` 字典（27.2 探针实证，旧读法得到"无电池"）；电池读取已做双层兼容，见 `Modules/System/BatteryAndSwap.swift`。
- SMC 风扇/温度在 27.2 复证仍不可用（`AppleSMC` 结构方法返回 `kIOReturnUnsupported`）；热压力档位（`ProcessInfo.thermalState`）作为温度的公开等价物提供。

## 渲染与验证工具

- `cacheDisplay` 不能可靠还原系统玻璃材质；完整玻璃效果与辅助功能外观需人工目检。
- NSLog 在本工程（未签名 Debug 构建）不进统一日志（`log show`/`log stream` 均收不到），进程内诊断用文件落盘（`DebugLog`）。
