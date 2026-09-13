import Carbon.HIToolbox
import Combine
import Foundation

/// 单个模块的面板布局配置
struct ModuleConfig: Codable, Equatable {
    var enabled: Bool
    /// true = 常驻顶部；false = 底部标签页切换
    var pinned: Bool
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
            NotificationCenter.default.post(name: Self.hotKeyDidChange, object: nil)
        }
    }
    @Published var hotKeyModifiers: UInt32 {
        didSet {
            defaults.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers)
            NotificationCenter.default.post(name: Self.hotKeyDidChange, object: nil)
        }
    }
    /// 模块布局配置：moduleId → 配置；未记录的模块使用默认值
    @Published var moduleConfigs: [String: ModuleConfig] {
        didSet { persist(moduleConfigs, forKey: Keys.moduleConfigs) }
    }
    /// 用户自定义子项
    @Published var customItems: [CustomItem] {
        didSet { persist(customItems, forKey: Keys.customItems) }
    }
    /// 已启用的媒体源（bundleID）；默认为空 = 安装后不申请任何权限
    @Published var mediaSources: [String] {
        didSet { defaults.set(mediaSources, forKey: Keys.mediaSources) }
    }
    /// 用户添加到面板的应用
    @Published var panelApps: [PanelApp] {
        didSet { persist(panelApps, forKey: Keys.panelApps) }
    }
    /// 进程监控关键词：命令行或可执行文件包含任一关键词且监听端口的进程会被列出
    @Published var processKeywords: [String] {
        didSet { defaults.set(processKeywords, forKey: Keys.processKeywords) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hoverEnabled = "settings.hoverEnabled"
        static let hoverDelay = "settings.hoverDelay"
        static let collapseEnabled = "settings.collapseEnabled"
        static let collapseDelay = "settings.collapseDelay"
        static let hotKeyCode = "settings.hotKeyCode"
        static let hotKeyModifiers = "settings.hotKeyModifiers"
        static let moduleConfigs = "settings.moduleConfigs"
        static let customItems = "settings.customItems"
        static let mediaSources = "settings.mediaSources"
        static let panelApps = "settings.panelApps"
        static let processKeywords = "settings.processKeywords"
    }

    /// 各模块的默认布局
    static let moduleConfigDefaults: [String: ModuleConfig] = [
        "media": ModuleConfig(enabled: true, pinned: true),
        "volume": ModuleConfig(enabled: true, pinned: true),
        "apps": ModuleConfig(enabled: true, pinned: false),
        "system": ModuleConfig(enabled: true, pinned: false),
        "node": ModuleConfig(enabled: true, pinned: false),
        "custom": ModuleConfig(enabled: true, pinned: false),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverEnabled = defaults.object(forKey: Keys.hoverEnabled) as? Bool ?? true
        hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? 0.2
        collapseEnabled = defaults.object(forKey: Keys.collapseEnabled) as? Bool ?? true
        collapseDelay = defaults.object(forKey: Keys.collapseDelay) as? Double ?? 1.0

        let storedKeyCode = defaults.integer(forKey: Keys.hotKeyCode)
        hotKeyCode = storedKeyCode == 0 ? UInt32(kVK_ANSI_I) : UInt32(storedKeyCode)
        let storedModifiers = defaults.integer(forKey: Keys.hotKeyModifiers)
        hotKeyModifiers = storedModifiers == 0 ? UInt32(cmdKey | shiftKey) : UInt32(storedModifiers)

        moduleConfigs = Self.decode([String: ModuleConfig].self, forKey: Keys.moduleConfigs, defaults: defaults) ?? [:]
        customItems = Self.decode([CustomItem].self, forKey: Keys.customItems, defaults: defaults) ?? []
        mediaSources = defaults.stringArray(forKey: Keys.mediaSources) ?? []
        panelApps = Self.decode([PanelApp].self, forKey: Keys.panelApps, defaults: defaults) ?? []
        processKeywords = defaults.stringArray(forKey: Keys.processKeywords) ?? ["node"]
    }

    // MARK: - 模块配置

    func config(for id: String) -> ModuleConfig {
        moduleConfigs[id] ?? Self.moduleConfigDefaults[id] ?? ModuleConfig(enabled: true, pinned: false)
    }

    func updateConfig(for id: String, mutate: (inout ModuleConfig) -> Void) {
        var config = self.config(for: id)
        mutate(&config)
        var configs = moduleConfigs
        configs[id] = config
        moduleConfigs = configs
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
