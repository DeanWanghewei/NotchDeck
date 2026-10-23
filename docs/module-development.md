# 内置 Swift 组件接入

目前的扩展方式是随 NotchDeck 一起编译的 Swift 组件。组件共享应用进程和权限边界；可选插件通过应用内插件市场添加与移除，目录由 GitHub 管理，代码随应用更新。完整组件参考是 `Modules/Clock/ClockModule.swift`、`UI/ClockView.swift` 和 `UI/Settings/ClockModuleSettingsView.swift`；市场插件参考 `Modules/Subscriptions/`。

## 接入位置

1. 在 `Modules/<领域>/` 实现 `NotchModule`，数据模型与采集逻辑放在同一领域目录。
2. 面板视图放在 `UI/`，组件设置放在 `UI/Settings/`。
3. 默认随应用注册的组件，在 `Modules/BuiltInModules.swift` 加入 `ModuleBox(YourModule(settings: settings))`。可选市场插件则在 `Modules/MarketplacePlugins.swift` 注册工厂、实现版本，并添加 `marketplace/catalog.json` 条目（不要两处同时注册）。具体流程见 [插件市场维护说明](../marketplace/README.md)。只有装配清单依赖具体组件；不必修改 `AppModel`、全局设置字段或设置导航分支。

工程由 xcodegen 自动收集上述目录中的 Swift 文件。组件会自动获得模块开关、区域/样式选择、排序和设置入口。

## 元数据与默认配置

```swift
static let descriptor = ModuleDescriptor(
    id: "clock",
    title: "时钟",
    systemImage: "clock",
    summary: "本地时间、日期与时区，无需权限",
    defaultConfig: ModuleConfig(enabled: false, pinned: false)
)
```

`id` 是持久化配置的标识，发布后应保持稳定；标题可以调整。注册表拒绝空白、首尾带空白和重复的 id，以及无效的区域/样式声明。未指定 `defaultConfig` 时默认启用、位于标签页；已有用户配置优先于默认值。新增可选内容建议默认关闭，避免改变已有用户布局。

需要直接读写模块布局时，传入同一份默认值：

```swift
settings.config(for: id, default: Self.descriptor.defaultConfig)
settings.updateConfig(for: id, default: Self.descriptor.defaultConfig) {
    $0.enabled = true
}
```

`isAvailable` 默认返回 `true`。需要用户先添加内容的组件可返回 `false`，并用 `unavailableReason` 说明原因。不可用组件停止采集、隐藏面板内容，但保留设置入口。可用性改变须通过 `objectWillChange` 通知宿主，例如使用 `@Published`，或由注入的 `SettingsStore` 发布配置变化。

## 布局与数据展示

插件通过 `ModuleDescriptor.presentation` 声明支持的位置与样式，通过 `defaultConfig` 指定默认选择。例如订阅额度：

```swift
static let descriptor = ModuleDescriptor(
    id: "subscriptions", title: "订阅额度", systemImage: "chart.bar.xaxis",
    summary: "GLM Coding Plan 与 ChatGPT · Codex 套餐额度",
    defaultConfig: ModuleConfig(enabled: false, placement: .tab, displayModeID: "cards"),
    presentation: ModulePresentationOptions(
        placements: [.top, .tab, .bottom],
        displayModes: [
            ModuleDisplayMode(id: "cards", title: "百分比长条"),
            ModuleDisplayMode(id: "rings", title: "百分比圆环"),
            ModuleDisplayMode(id: "compact", title: "紧凑长条"),
        ],
        showsSectionHeader: false // 视图已有标题，避免常驻区域重复展示标题
    )
)
```

| 区域 | 展开信息岛中的位置 |
|---|---|
| `.top` 顶部常驻 | 标签页上方，所有已启用组件同时展示 |
| `.tab` 标签页 | 中间切换区，一次展示选中的组件 |
| `.bottom` 底部常驻 | 标签页下方，所有已启用组件同时展示，随内容滚动 |

应用底栏仍由宿主管理。三个区域均使用完整内容宽度，共享面板滚动和 520 × 580pt 上限；当前不提供任意 x/y 坐标、跨组件重叠、收起时刘海两侧摘要。插件视图要适应窄屏、浅色/深色与系统辅助功能外观。

省略 `presentation` 时支持三个区域、仅提供“标准”样式、常驻区域由宿主显示标题；插件已有自己的标题时可设置 `showsSectionHeader: false`。`placements` 与 `displayModes` 均不得为空或重复；样式 id 使用小写英文、数字、连字符（最多 64 字符），显示名最多 40 字符。可以仅声明自己适配的区域与样式，不必给不适合的组件提供全部选项。

宿主自动生成“布局与展示”设置，模块管理也可修改同一份配置；上下箭头只交换同一区域的组件。设置保存在 `ModuleConfig.placement` / `displayModeID`，用户选择覆盖插件默认值。旧的 `pinned` 配置自动映射为 `.top` / `.tab`；新增字段不会让旧布局丢失。配置包含当前实现不支持的区域或样式时，显示时按插件默认值、再按第一个可用选项回退，保留原存储值供以后恢复。

实际内容仍由插件的 `content()` 提供，宿主会注入解析后的上下文：

```swift
@Environment(\.modulePresentation) private var presentation
// presentation.placement：本次实际摆放区域
// presentation.displayModeID：本次实际样式，如 "cards" / "compact"
```

在视图中按样式 id 组织卡片、列表、数字、曲线或热力图；必须实现自己声明的每种样式。参考 `UI/SubscriptionQuotaView.swift`：长条、圆环和紧凑长条复用同一份多账号数据与采集器，圆环中心直接显示已用百分比，紧凑样式保留已用/剩余数字和用量条，重置说明通过悬停查看。更改区域、样式和顺序不会重新启动采集。百分比、冷暖色标、缺失值仍须遵循 [design-conventions.md](design-conventions.md)，不能由样式覆盖数据语义。

GitHub 目录用于介绍这些能力；运行时以应用随附插件的声明与实现为准，刷新 JSON 不会增添新的布局代码或视图。

## 生命周期

初始化、`content()` 与 `settingsContent()` 不得启动采集、执行命令或请求权限。注册表仅在组件启用且可用时调用 `start()`，停用、不可用、移除或退出应用时调用 `stop()`。组件也应保证这两个方法可重复调用：

- `start()` 创建定时器、订阅和任务；重复调用不重复创建。
- `stop()` 取消任务、释放订阅与定时器，并使在途旧结果失效。
- `deinit` 对持有的系统资源做兜底清理；异步回调避免强引用组件。
- 只在主队列发布可观察状态；耗时采样、解析和命令放在后台执行。

`panelDidExpand()` 和 `panelDidCollapse()` 默认为空实现，只派发给已启动组件。面板已展开时新启用的组件会先启动，再收到展开事件；展开期间停用组件时先收到收起事件，再停止。展开钩子适合刷新快照，不能每次重建采集器，也不能重叠执行未完成的命令。不要另订阅全局面板通知。

`ModuleRegistry.unregister(_:)` 停止组件并断开事件转发，保留用户配置以便重新接入；`stopAll()` 用于应用退出。插件市场通过同一注册表管理添加与移除，安装列表独立持久化；移除不删除应用内的二进制代码。

## 组件配置与设置视图

新组件使用自己的 Codable 值，不向 `SettingsStore` 增添专属字段：

```swift
struct ClockPreferences: Codable, Equatable {
    var showSeconds = true
    var showTimeZone = true
}

// 在组件 init 中创建并持有，面板和设置视图使用同一个实例。
preferences = settings.modulePreferences(
    for: Self.descriptor.id, default: ClockPreferences()
)
```

数据以 JSON 存在注入的 UserDefaults 域内，键为 `modules.preferences.<id>`。每个组件只创建一份 `ModulePreferences`；工厂不会缓存实例，也不会同步同 id 的多个实例。面板与设置视图通过 `@ObservedObject` 观察同一实例。

使用 `preferences.update { ... }` 修改配置，或用 `preferences.binding(for: \.showSeconds)` 绑定控件。编码成功后才保存和发布；编码失败返回 `false`，保留旧值并设置 `saveError`，设置页应显示该错误。未保存或数据无法解码时回退到默认值，初始化不覆盖原数据。后续新增字段或修改类型时，组件负责自定义解码、迁移和兼容性测试，避免合成解码失败后整份配置回退。原有内置组件继续读取旧存储键，保留用户设置。

实现 `settingsContent() -> some View` 并返回 `Form` 内的一个或多个 `Section`，宿主负责表单和侧栏导航，不要再嵌套 Form。没有专属设置时省略该方法，默认 `EmptyView` 不产生侧栏页面。设置页即使在组件停用时也能打开，不能依赖采集器已启动。需要从面板直达设置时，发送 `AppModel.openSettingsRequest`，其 `object` 设为组件 id。

## 权限、数据与验证

遵循 [design-conventions.md](design-conventions.md) 的颜色与数字展示规范。仅使用公开系统 API；新增系统数据源须先用探针验证并记录结论，解析和差分提取为纯函数。默认启动不申请权限；需要权限的能力由用户主动开启时申请。

测试通过临时 UserDefaults 和 `AppModel(settings:modules:)` 注入组件，不启动主程序、用户命令或媒体授权。可参考 `Tests/ModuleFrameworkTests.swift`；组件自己的采样、解析、取消与配置迁移应按实际行为验证。

```bash
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

涉及界面时还需用 `NSHostingView` 承载实际视图，以浅色和深色 `NSAppearance` 分别通过 `cacheDisplay` 导出 PNG 并目检。覆盖面板、组件设置、默认及最小窗口尺寸；检查中文截断、滚动、选中态和对比度。自渲染不能完整还原系统玻璃材质，该部分仍需实机查看。功能与文档变化同步更新 README。
