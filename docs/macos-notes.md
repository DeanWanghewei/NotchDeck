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
- 27.3 上的复证结果见下文「macOS 27.3 复核（26C5035r）」。

## macOS 27.3 复核（26C5035r）

在 macOS 27.3（Build 26C5035r）、Xcode 27.2（Build 27B52）、SDK `MacOSX27.2.sdk` 下复核上一版探针结论，供代码侧对照：

- **电池注册表键位：结论不变。** `AppleSmartBattery` 下 `AppleRawMaxCapacity` / `AppleRawCurrentCapacity` / `DesignCapacity` 仍在嵌套的 `BatteryData` 字典里（实测 5461 / 4176 / 6075），而 `CycleCount` / `DesignCycleCount9C` / `Voltage` / `Amperage` 仍在顶层。代码里"先顶层、后嵌套"的兼容读法有效，**无需改动**（`Modules/System/BatteryAndSwap.swift`）。
- **GPU：结论不变。** `/System/Library/Frameworks/IOReport.framework` 在 27.3 上仍不存在，用户态 GPU 统计没有公开来源，面板继续隐藏 GPU 卡片。
- **风扇与温度：仍不可用。** 27.3 上 `AppleSMC` 服务存在、`IOServiceOpen` 成功，但 READ_KEYINFO 结构方法取不到数据（本次手工构造 `SMCKeyData` 布局的探针返回 `kIOReturnBadArgument`）。该错误码与 27.2 记录的 `kIOReturnUnsupported` 不同，**不足以说明接口状态发生变更**，因此不作为结论；稳妥表述仍是风扇与温度在 27.3 上依旧不可用，温度的公开等价物为 `ProcessInfo.thermalState`（本次为 `nominal`）。
- **应用冒烟**：Debug 版在 27.3 上启动后正常运行，无崩溃、无 DiagnosticReports 崩溃日志。
- **回归**：该环境下**全量回归全绿**（标准命令 `xcodegen generate && xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`）。若所在环境限制 `/bin/ps` 执行，见下文「受限运行环境下的验证方式」。

### 深浅两版自渲染与色标审计（27.3）

系统监控卡是最敏感的一屏（`HeatScale` 冷暖色标 + 百分比必显数字 + 悬停明细行式结构），27.3 上重做了深浅两版自渲染：`NSHostingView` + `cacheDisplay` 导出 `build/render-macos27/*.png`（`Tests/MacOS27RenderTests.swift`，设置 `NOTCHDECK_RENDER_DIR` 后运行）。

目检之外另配程序化颜色审计脚本 `scripts/audit-render.py`（模型无法直接看图时以像素统计替代目检），结论：

- **HeatScale 冷端停靠点精确命中**：#3478F6 ≈ 停靠点 0.00 的 (0.30, 0.56, 1.00)，低负载核心的用量条即规范中的冷蓝。
- **暖端在有高负载样本时可达**：本次采样出现暖黄 #E5BB48（落在 0.75 停靠点附近）；热红停靠点未命中，原因是本机没有接近 100% 的负载样本，**不是缺陷**，不应写成"暖端未验证"。
- **内存构成分类色符合规范 §1.2**：交换 / 联动紫 #B03ECC 命中。
- **深浅两版色标像素数几乎完全一致**（冷 15636 / 15637，暖 4911 / 4912），说明色标在两种外观下没有偏移或被压暗。
- **深色版有足量对比文字像素**（约 1.9%~2.1%），未见黑底黑字。

审计脚本本身也踩过两个坑，都已修正（结论以修正后的脚本为准）：

- **背景色不能靠"近黑"阈值猜**：设置页深色底是 `#1E1E1E`、系统监控深色底是 `#000000`，用近黑阈值会把设置页误判成浅色版，得出"对比文字占 97%"的假信号。现在改为**从四角像素实测背景色**。
- **文字色不能用众数**：抗锯齿边缘像素的众数落在中间调上，算出 1.3:1 这种没有意义的对比度。现在取**与背景对比度最高的墨色**作为文字核心色。

修正后对 12 张图（系统监控 6 张 / 进程列表 4 张 / 自定义设置页 2 张）的统一结论：

> 进程列表（指标缺失显示「—」）与自定义子项设置页（探测间隔选择）是本轮改动的两个新视图，渲染产物在 `build/render-new/`，由 `Tests/NodeScannerTests.swift` 与 `Tests/CustomItemsTests.swift` 的渲染用例导出（同样设置 `NOTCHDECK_RENDER_DIR`）。

- **四周留白正常，未见文字贴边或溢出**（最小边缘余量 32px），即没有截断；
- **文字核心色与背景对比度 12.6:1 ~ 16.5:1**，均满足 AA；
- **深浅两版的可见行带数量完全一致**（设置页 56/56、进程列表 4/4 与 3/3、系统监控 7/7 与 13/13），说明两种外观下结构没有错位。

**克制结论**：程序化颜色审计只能验证色值落点与对比度；**玻璃材质、圆角、辅助功能外观仍需人工目检**——"cacheDisplay 不能可靠还原系统玻璃材质"这一既有结论不变，本次审计不改变它。

## SwiftUI 动效与材质（macOS 27.3 / Xcode 27.2 实测）

面板形变（`UI/PanelOutline.swift`、`UI/PanelSurface.swift`）落地过程中逐条实验得出的平台行为。每条都有回归测试钉住；结论变化时先改测试再改实现。

### `ImageRenderer` 画不出 `glassEffect`

- **现象**：用 `ImageRenderer` 渲染真实面板，卡片本体的黑色只有约 35% 不透明度，底部还缺一条通宽的带。
- **机制**：材质由窗口服务器的背景层合成，离屏渲染器画不出来，只剩下垫在玻璃后面的压暗层（`PanelBodySurface.attachedGlassDim`：当时取 0.35，实测残留的 alpha 正好是 0.35）。对照实验里只有形状、形状 + 裁剪、轮廓层配纯色内容、轮廓层配滚动内容、乃至旧结构都渲染正确，唯独带 `glassEffect` 的真实面板失真。
- **约束**：像素断言只针对不透明表面，测试里必须显式 `settings.liquidGlass = false`（开关默认开启）。玻璃材质只能靠真实窗口目检。

### `cacheDisplay` 把 `glassEffect` 画成全透明，只留下它后面的图层

- **实测**：屏幕外窗口里用 `NSHostingView` + `cacheDisplay` 导出"接壤 + 玻璃 + 亮色渐变背景"的截图，逐通道比对卡片与入射背景，比值恒等于 1 − 压暗值。即材质本身在截图里不贡献任何压暗与模糊，卡片只是压暗层叠在背景上。
- **用途**：这是一个"假设材质不压暗"的最悲观可读性模型。接壤玻璃的压暗值 0.6 就是按它定的：纯白壁纸下白字须达到正文可读的 4.5:1。最初的 0.35 在亮色渐变上实测白字只有 3.3~3.6:1、灰色次要文字 1.3:1。
- **实机复核推翻了"真实材质会再压暗一些"的预期**：取得屏幕录制权限后做屏幕区域截图，亮色渐变背景上卡片与入射背景的通道比值是 **0.41**，几乎正好是 1 − 0.6——深色外观下的 `.regular` 材质本身几乎不压暗。所以上面的最悲观模型就是真实模型，0.6 不是下限而是实际生效的值，不能再低。实测白字对比度：亮色背景 6.2~7.8:1，暗色背景 10.0~13.7:1。
- **仍需人工看的**：边缘高光与折射在截图里有、动起来之后的手感没有；玻璃"透"的程度是否合口味也是主观判断，调 `PanelBodySurface.attachedGlassDim` 一处即可。

### 窗口合成后的截图需要"屏幕录制"权限

- **实测**（macOS 27.3）：`CGWindowListCreateImage(.optionIncludingWindow)` 对进程自建的窗口返回尺寸正确但**全透明**的图像；`screencapture -l <windowID>` 退出码 1。工具沙箱内外结果相同，所以拦路的是权限而不是沙箱。
- **影响**：`Tests/PanelLiveCaptureTests.swift` 只有在运行测试的进程拥有屏幕录制权限时才有意义（例如从已授权的终端运行）；没有权限时它先用一块小窗口探明并在 2 秒内失败，不会把面板在屏幕上摆很久，也不会静默产出黑图。
- **有了权限之后要截屏幕区域，不要截单个窗口**：`CGWindowListCreateImage(.optionIncludingWindow)` 取到的玻璃是一片不含背景采样的平灰，背后的内容完全不透出来；用 `.optionOnScreenOnly` 截面板所在的屏幕区域才是窗口服务器合成后的真实样子。测试在面板后面垫一块自带的渐变窗口盖住整块区域，截到的只有"测试背景 + 面板"。
- **顺带发现**：窗口控制器此前在 `refreshFrame()` 里读全局的 `SettingsStore.shared.notchAttached`，测试传入的设置不生效，"接壤"配置截出来的其实是悬浮卡片。已改为读注入的 `appModel.settings`；实机截图对每种接壤配置断言面板贴着屏幕顶缘。

### 连续圆角沿边的实际延伸量大于标称半径（约 1.2 倍）

- **实测**：`RoundedRectangle` / `UnevenRoundedRectangle` 的 `.continuous` 样式，曲率从 0 缓升，曲线越过标称半径之后才逐渐平到边上。曲线平到距边 0.05pt 以内的位置在 **1.18~1.27 倍半径**之间（r = 2 / 10 / 19.5 / 23.4 / 26 / 40 六档依次为 1.230 / 1.249 / 1.182 / 1.240 / 1.268 / 1.234，与顶部/底部半径是否相等无关）。另测 r = 5 一档得到 1.00，与上述趋势不符，原因未查明；取值时以偏大的一侧为准。
- **影响**：判断"形状某条边上某一段是不是直线"必须用这个系数。形变开始时卡片只比颈部宽一点，顶角若按 1:1 计算会伸进颈部与凹角所在的区段，接缝处豁出约 2.75pt 的缺口——只在中间帧出现，静态截图看不出来。规则见 `PanelBodyShape.continuousCornerReach`。

### 挂载与状态翻转落在同一个事务里，Animatable 形状没有前值可插值

- **现象**：视图首次求值时目标就已是终态，弹簧无从出发；屏幕外测试窗口里轮廓停在空形状上 0.8s 不再更新。
- **约束**：展开必须"先按折叠轮廓挂载并上屏，再翻转目标值"。`NotchWindowController` 只由视图挂载完成后的回调（`PanelPresentation.didMount`，在 `onAppear` 里、挪到下一轮运行循环）触发翻转；另有超时回滚——视图迟迟没挂载上屏就放弃这次展开。**不能到点盲目翻转**：首帧若晚于定时器，翻转就落在挂载的同一事务里，正是要规避的情形。

### SwiftUI 动画的最后一帧不保证精确落在目标值上

- **实测**：弹簧结束后最后一次求值的残差在 0.0005~0.05pt 之间浮动，取决于最后一帧落在动画的哪个时刻。
- **影响**：静止的卡片会比窗口窄/矮零点几个点，边缘是一条亚像素的透明细边。`PanelBodyShape.rect(in:)` 对距窗口边缘不足 0.1pt 的内缩与高度做贴边吸附。

### `.animation(_:value:)` 的作用域会连带驱动裁剪遮罩

- **现象**：把"内容淡入"的 `.animation` 挂在 `.clipShape` 外层，遮罩就跟着内容的弹簧走而不是本体的弹簧。两组参数碰巧速度接近，平时看不出；"减弱动态效果"下本体直接落位而遮罩仍走 0.12s 缓动，立刻暴露。变异验证（改回这种写法）：收起时实测本体 107pt、遮罩 167pt——内容溢出卡片约 60pt。
- **约束**：遮罩与本体填充必须由同一个 `.animation(motion, value: showsContent)` 驱动；内容的淡入与位移在裁剪之前单独挂 `.animation(…, value: showsContent)`。回归判据见 `PanelMorphTests.testContentMaskAndBodyStayOnOneClock`：只看主行程（首次到位之前，没有过冲），同一时钟下采样流单调，反方向的回跳只可能来自另一个时钟。

### 同一轮运行循环里可能连续求值多个动画帧

- **实测**：`Animatable` 形状逐帧重新求 `path(in:)`，相邻两帧的墙钟间隔可短于 2ms（动画时间各推进一帧，墙钟被压缩）。同一个形状的两种用途（填充 / 遮罩）谁先求值也不固定，遮罩每帧被求值约 7 次。
- **约束**：不能用时间戳判断"同一帧"，也不能假定求值顺序；测试靠仅调试构建存在的 `PanelBodyShape.debugTag` 区分用途。

### `accessibilityReduceMotion` 是只读环境值

- 测试无法通过 `.environment` 注入。`PanelOutlineLayer` 把它做成显式入参 `reduceMotion`，由 `PanelRoot` 读环境后传入，测试据此覆盖"减弱动态效果"下的轮廓层。

### 测试里的窗口必须真正结束，`close()` 又会过度释放

- **现象**：逐帧采样的用例原先只用 `orderOut` 把屏幕外窗口移出屏幕。窗口仍然活着，动画还在跑，形状还在逐帧求值；而采样钩子是进程级的一根，前一个窗口的取值会灌进后一条用例的采样里。实测：收起用例的采样流里混着完全展开的 580，看起来像"等待时刻轮廓还没缩完"——一度被误判成时序抖动。
- **修法**：释放时先 `window.contentView = nil`（SwiftUI 的视图图随之结束），再 `orderOut` + `close`。
- **陷阱**：`NSWindow` 默认 `isReleasedWhenClosed = true`，`close()` 会额外释放一次；Swift 这边仍持有强引用时就是过度释放，实测测试进程直接崩溃、后续用例连带失败。创建测试窗口时先设 `isReleasedWhenClosed = false`，把生命周期交给 ARC（主应用的面板同样显式设为 false）。
- **教训**：连续失败不要先归结为抖动。同一条用例单独跑 12 次全挂、全量跑却几乎总过，差别在于进程里有没有别的窗口活着。

### 本机编译器比 CI 的宽松：发版前先让 main 的 CI 跑一遍

- **现象**：v1.1.0 第一次打标签时，tag 触发的 CI 在"运行测试"一步编译失败：`Tests/PanelMorphTests.swift` 把 `NSColor` 的分量（CGFloat）直接装进 `(red: Double, …)` 元组返回。本机 Xcode 27.2 的编译器会在元组里自动做 CGFloat → Double 的转换，CI 是 macOS 15.8 + Xcode 16.4，不做这个转换。Release 步骤因此被跳过，没有发布出任何东西。
- **约束**：本机只有一套 Xcode，这类差异在本地重现不了。CI 工具链是 Xcode 16.4（macOS 15 SDK），`glassEffect` 等新 API 必须用 `#if compiler(>=6.2)` 一类的编译期条件挡住（应用代码当时能编译过，正是因为原有代码保留了这层条件）。涉及数值类型的地方写显式转换，不要依赖编译器的隐式放宽。
- **流程**：推 `v*` 标签就是发布。发版前先把待发布的提交推到 main 让 CI 跑绿——main 上的 CI 只构建不发布，是对 CI 工具链的真实验证。

### 逐帧采样用例在没有刷新时钟的环境里跳过

- 依赖动画逐帧推进的用例先跑一个环境探针（一个确定会动的形状能否采到 3 个以上不同的取值），采不到就跳过并写明原因；像素与几何用例不依赖时钟，照常执行。没有图形会话的 CI、SSH 会话因此不会误报失败。
- 本地（macOS 27.3）探针为真，这些用例全部执行；把探针强制为否时实测 7 条跳过、0 失败。

## 受限运行环境下的验证方式

在受限沙箱 / 部分 CI 环境下，标准验证命令会因**环境**而非代码失败。以下为逐条实证与绕过办法；所有绕过都只是命令行覆盖，**不写入 `project.yml`**。

### 1. DerivedData 不可写

`~/Library/Developer/Xcode/DerivedData` 不可写时，`xcodebuild` 在建测试会话、写 result bundle 阶段失败，典型输出：

```
Couldn't create workspace arena folder '.../Library/Developer/Xcode/DerivedData/NotchDeck-...': Unable to write to info file '.../info.plist'.
Testing failed: ... Operation not permitted
** TEST FAILED **
```

绕过：把 DerivedData 指向仓库内的可写目录（`build/` 已在 `.gitignore`）：

```bash
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData test
```

### 2. Swift 宏插件服务器套了二层沙箱

受限环境下 Swift 编译宏插件服务器需要再套一层沙箱，会报：

```
sandbox-exec: sandbox_apply: Operation not permitted
```

此时 `@State` 等宏展开失败，连锁报出 `cannot assign to property: 'self' is immutable` 这类**与真实原因无关**的误导性错误。绕过：编译参数追加 `-disable-sandbox`：

```bash
OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
```

### 3. 测试运行器需要 pty

`xcodebuild test` 在受限环境下可能报 `Pseudo Terminal Setup Error`。绕过：先 `build-for-testing`，再用 `xctest` 直接跑无宿主测试包（`NotchDeckTests` 是无宿主单元测试包，可脱离 Xcode 单独执行）：

```bash
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build-for-testing
xcrun xctest -XCTest All build/DerivedData/Build/Products/Debug/NotchDeckTests.xctest
```

`xctest` 末行输出 `Executed N tests, with 0 failures`。完整命令块见本节末尾。

### 4. 受限环境：/bin/ps 被拒 → 进程列表降级而不是消失

- 现象：受限运行环境（沙箱、部分 CI）里 `/bin/ps` 被系统以 EPERM 拒绝执行（`Operation not permitted`）。旧实现的进程扫描在 ps 失败时直接清空整个列表，面板上「进程监控」整体消失——零配置在这种环境里等于不可用。
- 现状：扫描改为降级。lsof 仍提供 pid、端口与命令名，CPU/内存标记为**缺失**并显示「—」，**不补 0 假装读数**；可执行路径用公开 libproc 的 `proc_pidpath` 兜底，因此系统守护进程过滤与 .app 进程识别在降级后依然成立。ps 可用时行为与原来完全一致。
- lsof 字段协议实证（macOS 27.3）：`-Fpcn` 输出 `p`=pid、`c`=命令名 basename（可含空格与括号，不是 16 字符截断）、`f`=fd（解析须忽略）、`n`=host:port（`n*:57076` / `n127.0.0.1:9884` / `n[::1]:3000`，同一进程可有多条）。
- 回归：`testScannerFindsOwnedListeningSocket` 在 ps 被拒的环境由失败转为通过——该环境不再依赖 ps 也能列出监听端口。

### 5. `swiftc` 直编探针脚本需要可写 module cache

`swiftc` 默认把 module cache 放在 `/var/folders/.../clang/ModuleCache`，受限环境下不可写，直编小探针脚本会失败：

```
error: unable to open output file '/var/folders/.../clang/ModuleCache/.../SwiftShims-*.pcm': 'Operation not permitted'
error: could not build Objective-C module 'SwiftShims'
```

绕过：用 `-module-cache-path` 指向可写目录：

```bash
swiftc -module-cache-path build/ModuleCache -o build/probe probe.swift
```

### 6. 受限环境跳过的用例

`CustomItemsPresetTests.testLocalPresetsRunAndParseNumbers`（自定义小部件本地模板实跑）会真的执行模板依赖的系统程序。受限环境拒绝执行时（如沙箱禁止 `/usr/bin/top`），该用例 **skip 而不是失败**：已跑通的模板照常断言，被拒的单独列名说明。

因此同一套测试在常规环境是「212 项 0 失败 0 跳过」，在受限沙箱是「212 项 0 失败 1 跳过」。跳过属环境所限，不代表模板在常规环境未验证。

### 完整命令块（可直接复制执行）

```bash
cd /path/to/NotchDeck
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build-for-testing
xcrun xctest -XCTest All build/DerivedData/Build/Products/Debug/NotchDeckTests.xctest
```

`build/` 已在 `.gitignore` 内，DerivedData、module cache 与自渲染导出的 PNG 都不会进入版本库。

## 渲染与验证工具

- `cacheDisplay` 不能可靠还原系统玻璃材质；完整玻璃效果与辅助功能外观需人工目检。
- 程序化颜色审计（`scripts/audit-render.py`）只验证色值落点与对比度，不替代人工目检。
- NSLog 在本工程（未签名 Debug 构建）不进统一日志（`log show`/`log stream` 均收不到），进程内诊断用文件落盘（`DebugLog`）。
