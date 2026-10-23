import Combine
import Foundation

/// 全局可观察状态与模块注册表
final class AppModel: ObservableObject {
    static let shared = AppModel(settings: .shared, modules: BuiltInModules.make(settings: .shared),
                                 plugins: MarketplacePlugins.implementations)

    static let openSettingsRequest = Notification.Name("NotchDeckOpenSettings")
    static let quitRequest = Notification.Name("NotchDeckQuit")
    @Published var isExpanded = false {
        didSet {
            if isExpanded != oldValue { registry.setPanelExpanded(isExpanded) }
        }
    }
    /// 当前选中的标签页模块
    @Published var activeTabID: String?

    let registry: ModuleRegistry
    let settings: SettingsStore
    let marketplace: PluginMarketplace

    private var cancellables: Set<AnyCancellable> = []
    private var isRunning = true

    /// 可注入组件与偏好域，测试和预览不必启动内置采集器或读取用户媒体配置。
    init(settings: SettingsStore, modules: [ModuleBox], plugins: [PluginImplementation] = [],
         catalog: PluginCatalog? = nil, appVersion: String = PluginMarketplace.applicationVersion,
         catalogFetch: @escaping PluginCatalogFetch = { PluginCatalogClient.fetch(completion: $0) }) {
        self.settings = settings
        let registry = ModuleRegistry()
        self.registry = registry
        modules.forEach { registry.register($0) }
        marketplace = PluginMarketplace(settings: settings, registry: registry, implementations: plugins,
                                        bundledCatalog: catalog, appVersion: appVersion, fetch: catalogFetch)

        registry.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateModules() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // @Published 在赋值前发出事件，切到下一次主队列读取完整的新配置。
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateModules() }
            .store(in: &cancellables)
        updateModules()
    }

    private func updateModules() {
        guard isRunning else { return }
        registry.updateActivity(settings: settings)
        if !tabModules.contains(where: { $0.id == activeTabID }) {
            let next = tabModules.first?.id
            if activeTabID != next { activeTabID = next }
        }
    }

    func shutdown() {
        isRunning = false
        marketplace.shutdown()
        cancellables.removeAll()
        registry.stopAll()
    }

    // MARK: - 布局计算

    /// 全部模块，按设置中的显示顺序（未排序的按注册顺序附加在后）
    var orderedBoxes: [ModuleBox] {
        sortedByDisplayOrder(registry.boxes)
    }

    /// 常驻顶部且可用的模块
    var pinnedModules: [ModuleBox] {
        modules(at: .top)
    }

    /// 底部标签页切换的模块
    var tabModules: [ModuleBox] {
        modules(at: .tab)
    }

    var bottomModules: [ModuleBox] { modules(at: .bottom) }

    func presentationContext(for box: ModuleBox) -> ModulePresentationContext {
        box.descriptor.presentationContext(for: settings.config(for: box.id, default: box.descriptor.defaultConfig))
    }

    private func modules(at placement: ModulePlacement) -> [ModuleBox] {
        sortedByDisplayOrder(registry.boxes.filter { box in
            guard box.isAvailable() else { return false }
            let config = settings.config(for: box.id, default: box.descriptor.defaultConfig)
            return config.enabled && presentationContext(for: box).placement == placement
        })
    }

    private func sortedByDisplayOrder(_ boxes: [ModuleBox]) -> [ModuleBox] {
        let order = settings.effectiveModuleOrder(registryIDs: registry.boxes.map(\.id))
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return boxes.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
    }
}
