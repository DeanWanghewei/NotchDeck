# macOS 平台实证笔记

记录各 macOS 版本上以探针 / 实机实验得出的平台行为与陷阱，供开发时查阅；随系统版本演进需复证，代码侧在相应模块注释中同步标注。README 只保留结论级摘要，细节以此文档为准。

## 窗口与 Space（macOS 27.2，26B5091g 实测）

### canJoinAllSpaces 面板搁浅 → 悬停呼出永久失效（v0.19.3 修复）

- **现象**：悬停刘海无法呼出岛屿；全局快捷键表现为静默"收起"（状态机卡在 `.expanded` 而面板实际不可见），此后悬停热区只会不断清零收起倒计时，永不重新展开。用户侧观察为"全屏应用下无法呼出"，偶发可被"重启目标应用"暂时治愈。
- **触发**：Space 生命周期扰动——全屏空间的创建/销毁、应用重启（其全屏 Space 重建）、更新程序强切前台等。扰动后 `canJoinAllSpaces` 窗口可能被窗口服务器留在一个不可见空间上。
- **机制**：搁浅时窗口处于"已置入但不在当前 Space"状态，`orderFrontRegardless()` 静默空转（它在"自己的空间"里本就最前）；状态机不知情照常进入 `.expanded`。
- **修复锚点**：`Core/NotchWindowController.swift` 配合 `Core/PanelVisibilityRecovery.swift`——置前后用 CGWindowList 自查真实合成状态；未上屏则 `orderOut` 摘下 + 重挂 `collectionBehavior`（强制窗口服务器重算归属）+ 再置前。详见下方对 v0.19.3 检查缺陷的修正。
- **保留项**：原始偶发链路（多事件叠加）未在受控环境复现，恢复路径按机制验证；日后再发生时以上日志可回溯。

### v0.19.4：修正 v0.19.3 可见性误判与全屏恢复（2026-10-22）

- **根因**：`CGWindowListCopyWindowInfo(.optionOnScreenOnly, windowNumber)` 不会只返回指定窗口。SDK `CGWindow.h` 明确要求该选项的第二参数使用 `kCGNullWindowID`，结果是当前所有在屏窗口。旧实现只判断 `!list.isEmpty`，其他窗口也会被误认成信息岛，导致恢复分支被跳过。
- **本机探针**（macOS 27.2，26B118）：创建同款非激活 NSPanel，在首次置前前、置前后、`orderOut` 后分别查询。旧判断三次均为 true；枚举窗口并精确匹配自身 `kCGWindowNumber`，结果依次为 false / true / false。无需屏幕录制权限。
- **修正**：使用 `.optionOnScreenOnly` + `kCGNullWindowID` 获取列表，再精确匹配面板 ID；查询返回 nil 作为未知状态，不误判成不可见。
- **异步恢复**：置前 0.1 秒后再核验，成功后再等 0.8 秒复查，覆盖全屏动画开始时可见、结束后丢失的情况。确实未上屏时重挂归属，按 0.15 / 0.3 / 0.6 / 1 秒间隔最多重试 4 次。
- **状态兜底**：最终失败回到 `.collapsed` 并废弃展开动画回调，保证悬停和快捷键能再次唤起。收起、新一轮唤起及 Space 恢复均使旧核验回调失效，避免延迟回调重新打开已收起面板。
- **回归**：窗口列表匹配、全屏过渡后丢失、恢复成功、重试上限、取消、连续唤起与查询失败均有无宿主测试；不启动主程序、不申请权限。
- **实际全屏验证**：独立测试进程创建原生全屏主窗口，另一进程加载产品源码中的 `AppModel` 与 `NotchWindowController`。首次在其他应用全屏 Space 唤起、退出全屏后保持显示、再次进入全屏后保持显示、收起后延迟核验不重开，四项均通过；共进入/退出全屏两轮。测试进程使用独立偏好域，媒体源为空，不修改用户设置或已安装应用。原始多事件叠加的偶发链路仍未受控复现。

### 可见性判据与查询边界

- `NSWindow.isOnActiveSpace` 与**外部进程**读 `CGWindowListCopyWindowInfo` 的 `kCGWindowIsOnscreen` 在 Space 扰动后可能谎报"不可见"（面板实际在屏）。调试/自动化脚本勿依赖外部窗口列表判断面板可见性。
- 进程内枚举 `.optionOnScreenOnly` 列表，再核对自身 `kCGWindowNumber`，见 `PanelVisibility.isOnScreen`。它能确认窗口在当前屏幕列表中，但不证明像素未被其他窗口遮挡；面板仍需保留 `.statusBar` 层级与全屏辅助窗口配置。

### 崩溃组合（禁止使用）

- `collectionBehavior` 上 `union(.moveToActiveSpace)` 与 `canJoinAllSpaces` 并存 → 断言崩溃（27.2 实测，调试期间真实崩过一次）。

## 电源与传感器（macOS 27 起）

- `AppleSmartBattery` 的 mAh 容量键（`AppleRawMaxCapacity` 等）从注册表顶层移入嵌套 `BatteryData` 字典（27.2 探针实证，旧读法得到"无电池"）；电池读取已做双层兼容，见 `Modules/System/BatteryAndSwap.swift`。
- SMC 风扇/温度在 27.2 复证仍不可用（`AppleSMC` 结构方法返回 `kIOReturnUnsupported`）；热压力档位（`ProcessInfo.thermalState`）作为温度的公开等价物提供。

## 渲染与验证工具

- `cacheDisplay` 不能可靠还原系统玻璃材质；完整玻璃效果与辅助功能外观需人工目检。
- NSLog 在本工程（未签名 Debug 构建）不进统一日志（`log show`/`log stream` 均收不到），进程内诊断用文件落盘（`DebugLog`）。
