import Carbon.HIToolbox
import Combine
import Foundation

/// 单个模块的面板布局配置
struct ModuleConfig: Codable, Equatable {
    var enabled: Bool
    var placement: ModulePlacement
    var displayModeID: String?

    /// 保留旧组件的配置写法；新组件直接使用 placement。
    var pinned: Bool {
        get { placement == .top }
        set { placement = newValue ? .top : .tab }
    }

    init(enabled: Bool, pinned: Bool) {
        self.init(enabled: enabled, placement: pinned ? .top : .tab)
    }

    init(enabled: Bool, placement: ModulePlacement, displayModeID: String? = nil) {
        self.enabled = enabled
        self.placement = placement
        self.displayModeID = displayModeID
    }

    private enum CodingKeys: String, CodingKey { case enabled, pinned, placement, displayModeID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        let legacyPinned = (try? values.decode(Bool.self, forKey: .pinned)) ?? false
        // 未知区域按旧布局兜底，不让单个插件的新字段破坏整份模块配置。
        placement = (try? values.decode(ModulePlacement.self, forKey: .placement)) ?? (legacyPinned ? .top : .tab)
        displayModeID = try? values.decode(String.self, forKey: .displayModeID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(placement, forKey: .placement)
        try values.encodeIfPresent(displayModeID, forKey: .displayModeID)
        // 回退应用版本后，底部常驻仍能作为常驻内容展示。
        try values.encode(placement != .tab, forKey: .pinned)
    }
}

/// UserDefaults 封装的设置存储（需求 2.5 + 模块管理）
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let hotKeyDidChange = Notification.Name("NotchDeckHotKeyDidChange")

    @Published var hoverEnabled: Bool {
        didSet { defaults.set(hoverEnabled, forKey: Keys.hoverEnabled) }
    }
    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) }
    }
    @Published var collapseEnabled: Bool {
        didSet { defaults.set(collapseEnabled, forKey: Keys.collapseEnabled) }
    }
    @Published var collapseDelay: Double {
        didSet { defaults.set(collapseDelay, forKey: Keys.collapseDelay) }
    }
    @Published var hotKeyCode: UInt32 {
        didSet {
            defaults.set(Int(hotKeyCode), forKey: Keys.hotKeyCode)
            notifyHotKeyChange()
        }
    }
    @Published var hotKeyModifiers: UInt32 {
        didSet {
            defaults.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers)
            notifyHotKeyChange()
        }
    }
    /// 模块布局配置：moduleId → 配置；未记录的模块使用默认值
    @Published var moduleConfigs: [String: ModuleConfig] {
        didSet { persist(moduleConfigs, forKey: Keys.moduleConfigs) }
    }
    /// 模块显示顺序（moduleId 列表，用户在设置中调整）；未记录的模块按注册顺序附加在后
    @Published var moduleOrder: [String] {
        didSet { defaults.set(moduleOrder, forKey: Keys.moduleOrder) }
    }
    @Published private(set) var installedPluginIDs: [String] {
        didSet { defaults.set(installedPluginIDs, forKey: Keys.installedPluginIDs) }
    }
    var cachedPluginCatalog: Data? {
        get { defaults.data(forKey: Keys.pluginCatalogCache) }
        set { defaults.set(newValue, forKey: Keys.pluginCatalogCache) }
    }
    /// 用户自定义子项
    @Published var customItems: [CustomItem] {
        didSet { persist(customItems, forKey: Keys.customItems) }
    }
    /// 热力图单值序列的保留时长（小时），超出后旧样本自动清除；设置页提供 1~24 小时档位
    @Published var heatmapRetentionHours: Double {
        didSet { defaults.set(heatmapRetentionHours, forKey: Keys.heatmapRetentionHours) }
    }
    /// 已启用的媒体源（bundleID）；默认为空 = 安装后不申请任何权限
    @Published var mediaSources: [String] {
        didSet { defaults.set(mediaSources, forKey: Keys.mediaSources) }
    }
    /// 用户添加到面板的应用
    @Published var panelApps: [PanelApp] {
        didSet { persist(panelApps, forKey: Keys.panelApps) }
    }
    /// 进程展示方式：grid（块状网格，默认）/ list（行列表）
    @Published var processDisplay: String {
        didSet { defaults.set(processDisplay, forKey: Keys.processDisplay) }
    }
    /// 是否显示 App 进程占用的端口
    @Published var showAppProcesses: Bool {
        didSet { defaults.set(showAppProcesses, forKey: Keys.showAppProcesses) }
    }
    /// 是否显示脚本进程（node/python 等解释器）占用的端口
    @Published var showScriptProcesses: Bool {
        didSet { defaults.set(showScriptProcesses, forKey: Keys.showScriptProcesses) }
    }
    /// 实验性：直接读取系统"正在播放"（支持任意播放器，如飞牛影视/IINA/浏览器）
    @Published var experimentalNowPlaying: Bool {
        didSet { defaults.set(experimentalNowPlaying, forKey: Keys.experimentalNowPlaying) }
    }
    /// 面板与刘海接壤（视觉一体）；false = 悬浮于菜单栏下方
    @Published var notchAttached: Bool {
        didSet { defaults.set(notchAttached, forKey: Keys.notchAttached) }
    }
    /// 系统监控：CPU 近 15 分钟热力图
    @Published var showCPUHeatmap: Bool {
        didSet { defaults.set(showCPUHeatmap, forKey: Keys.showCPUHeatmap) }
    }
    /// 系统监控：交换内存
    @Published var showSwap: Bool {
        didSet { defaults.set(showSwap, forKey: Keys.showSwap) }
    }
    /// 系统监控：电池
    @Published var showBattery: Bool {
        didSet { defaults.set(showBattery, forKey: Keys.showBattery) }
    }
    /// 系统监控：热压力警示（系统过热降速时在监控页提示）
    @Published var showThermalPressure: Bool {
        didSet { defaults.set(showThermalPressure, forKey: Keys.showThermalPressure) }
    }

    private let defaults: UserDefaults
    private var updatingHotKey = false

    func updateHotKey(keyCode: UInt32, modifiers: UInt32) {
        updatingHotKey = true
        hotKeyCode = keyCode
        hotKeyModifiers = modifiers
        updatingHotKey = false
        notifyHotKeyChange()
    }

    private func notifyHotKeyChange() {
        guard !updatingHotKey else { return }
        NotificationCenter.default.post(name: Self.hotKeyDidChange, object: nil)
    }

    private enum Keys {
        static let hoverEnabled = "settings.hoverEnabled"
        static let hoverDelay = "settings.hoverDelay"
        static let collapseEnabled = "settings.collapseEnabled"
        static let collapseDelay = "settings.collapseDelay"
        static let hotKeyCode = "settings.hotKeyCode"
        static let hotKeyModifiers = "settings.hotKeyModifiers"
        static let moduleConfigs = "settings.moduleConfigs"
        static let moduleOrder = "settings.moduleOrder"
        static let installedPluginIDs = "marketplace.installedPluginIDs"
        static let pluginCatalogCache = "marketplace.catalogCache"
        static let customItems = "settings.customItems"
        static let heatmapRetentionHours = "settings.heatmapRetentionHours"
        static let mediaSources = "settings.mediaSources"
        static let panelApps = "settings.panelApps"
        static let processDisplay = "settings.processDisplay"
        static let showAppProcesses = "settings.showAppProcesses"
        static let showScriptProcesses = "settings.showScriptProcesses"
        static let showCPUHeatmap = "settings.showCPUHeatmap"
        static let showSwap = "settings.showSwap"
        static let showBattery = "settings.showBattery"
        static let showThermalPressure = "settings.showThermalPressure"
        static let experimentalNowPlaying = "settings.experimentalNowPlaying"
        static let notchAttached = "settings.notchAttached"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverEnabled = defaults.object(forKey: Keys.hoverEnabled) as? Bool ?? true
        hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? 0.2
        collapseEnabled = defaults.object(forKey: Keys.collapseEnabled) as? Bool ?? true
        collapseDelay = defaults.object(forKey: Keys.collapseDelay) as? Double ?? 0.5

        let storedKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? Int
        hotKeyCode = storedKeyCode.flatMap { (0...127).contains($0) ? UInt32($0) : nil }
            ?? UInt32(kVK_ANSI_I)
        let storedModifiers = defaults.integer(forKey: Keys.hotKeyModifiers)
        hotKeyModifiers = UInt32(exactly: storedModifiers).flatMap { $0 == 0 ? nil : $0 }
            ?? UInt32(cmdKey | shiftKey)

        moduleConfigs = Self.decode([String: ModuleConfig].self, forKey: Keys.moduleConfigs, defaults: defaults) ?? [:]
        moduleOrder = defaults.stringArray(forKey: Keys.moduleOrder) ?? []
        installedPluginIDs = defaults.stringArray(forKey: Keys.installedPluginIDs) ?? []
        customItems = Self.decode([CustomItem].self, forKey: Keys.customItems, defaults: defaults) ?? []
        // 兼容历史/异常值：夹到 0.5~24 小时
        heatmapRetentionHours = min(24, max(0.5, defaults.object(forKey: Keys.heatmapRetentionHours) as? Double ?? 2))
        mediaSources = defaults.stringArray(forKey: Keys.mediaSources) ?? []
        panelApps = Self.decode([PanelApp].self, forKey: Keys.panelApps, defaults: defaults) ?? []
        processDisplay = defaults.string(forKey: Keys.processDisplay) ?? "grid"
        showAppProcesses = defaults.object(forKey: Keys.showAppProcesses) as? Bool ?? true
        showScriptProcesses = defaults.object(forKey: Keys.showScriptProcesses) as? Bool ?? true
        showCPUHeatmap = defaults.object(forKey: Keys.showCPUHeatmap) as? Bool ?? true
        showSwap = defaults.object(forKey: Keys.showSwap) as? Bool ?? true
        showBattery = defaults.object(forKey: Keys.showBattery) as? Bool ?? true
        showThermalPressure = defaults.object(forKey: Keys.showThermalPressure) as? Bool ?? true
        experimentalNowPlaying = defaults.object(forKey: Keys.experimentalNowPlaying) as? Bool ?? false
        notchAttached = defaults.object(forKey: Keys.notchAttached) as? Bool ?? false
    }

    // MARK: - 模块配置

    /// 首次引入市场时保留已有插件设置；明确移除后的空列表不会再次触发迁移。
    func migratePluginInstallations(legacyIDs: [String]) {
        guard defaults.object(forKey: Keys.installedPluginIDs) == nil else { return }
        installedPluginIDs = legacyIDs.filter {
            moduleConfigs[$0] != nil || defaults.object(forKey: "modules.preferences.\($0)") != nil
        }
    }

    func setPluginInstalled(_ id: String, installed: Bool) {
        if installed {
            if !installedPluginIDs.contains(id) { installedPluginIDs.append(id) }
        } else { installedPluginIDs.removeAll { $0 == id } }
    }

    func modulePreferences<Value: Codable & Equatable>(for id: String, default defaultValue: Value) -> ModulePreferences<Value> {
        ModulePreferences(moduleID: id, defaultValue: defaultValue, defaults: defaults)
    }

    func config(for id: String, default defaultConfig: ModuleConfig = ModuleConfig(enabled: true, pinned: false)) -> ModuleConfig {
        moduleConfigs[id] ?? defaultConfig
    }

    func updateConfig(for id: String, default defaultConfig: ModuleConfig = ModuleConfig(enabled: true, pinned: false),
                      mutate: (inout ModuleConfig) -> Void) {
        var config = self.config(for: id, default: defaultConfig)
        mutate(&config)
        var configs = moduleConfigs
        configs[id] = config
        moduleConfigs = configs
    }

    // MARK: - 模块排序

    /// 完整显示顺序：用户排序在前，未记录/新增模块按注册顺序附加在后（去重、剔除未知 id）
    func effectiveModuleOrder(registryIDs: [String]) -> [String] {
        let known = Set(registryIDs)
        var seen = Set<String>()
        var ordered: [String] = []
        for id in moduleOrder where known.contains(id) && seen.insert(id).inserted {
            ordered.append(id)
        }
        ordered.append(contentsOf: registryIDs.filter { !seen.contains($0) })
        return ordered
    }

    /// 只交换目标区域内的相邻项，其他区域的相对顺序不受影响。
    func moveModule(_ id: String, offset: Int, registryIDs: [String], within groupIDs: [String]? = nil) {
        var ordered = effectiveModuleOrder(registryIDs: registryIDs)
        let group = groupIDs.map(Set.init)
        let candidates = ordered.filter { group?.contains($0) ?? true }
        guard let index = candidates.firstIndex(of: id), candidates.indices.contains(index + offset),
              let source = ordered.firstIndex(of: id),
              let target = ordered.firstIndex(of: candidates[index + offset]) else { return }
        ordered.swapAt(source, target)
        moduleOrder = ordered
    }

    // MARK: - 持久化

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
