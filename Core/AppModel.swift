import Combine
import Foundation

/// 全局可观察状态与模块注册表
final class AppModel: ObservableObject {
    static let shared = AppModel()

    static let openSettingsRequest = Notification.Name("NotchDeckOpenSettings")
    static let quitRequest = Notification.Name("NotchDeckQuit")
    /// 面板展开完成，模块可借此刷新数据（如自定义子项）
    static let panelDidExpand = Notification.Name("NotchDeckPanelDidExpand")

    @Published var isExpanded = false {
        didSet {
            if isExpanded && !oldValue {
                NotificationCenter.default.post(name: Self.panelDidExpand, object: nil)
            }
        }
    }
    /// 当前选中的标签页模块
    @Published var activeTabID: String?

    let registry = ModuleRegistry()
    let settings = SettingsStore.shared

    // 内置模块
    let media = MediaModule()
    let system = SystemMonitor()
    let node = NodeProcessScanner()
    let volume = VolumeModule()
    let custom = CustomItemsModule()
    let apps = AppLauncherModule()

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        registry.register(media)
        registry.register(volume)
        registry.register(apps)
        registry.register(system)
        registry.register(node)
        registry.register(custom)

        registry.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        let customWasActive = registry.boxes.first(where: { $0.id == custom.id })?.isActive == true
        registry.updateActivity(settings: settings)
        if isExpanded, !customWasActive,
           registry.boxes.first(where: { $0.id == custom.id })?.isActive == true {
            custom.refresh()
        }
        if !tabModules.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabModules.first?.id
        }
    }

    // MARK: - 布局计算

    /// 常驻顶部且可用的模块
    var pinnedModules: [ModuleBox] {
        effectiveModules(pinned: true)
    }

    /// 底部标签页切换的模块
    var tabModules: [ModuleBox] {
        effectiveModules(pinned: false)
    }

    private func effectiveModules(pinned: Bool) -> [ModuleBox] {
        registry.boxes.filter { box in
            guard box.isAvailable() else { return false }
            let config = settings.config(for: box.id)
            return config.enabled && config.pinned == pinned
        }
    }
}
