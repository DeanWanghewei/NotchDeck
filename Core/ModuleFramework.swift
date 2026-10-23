import Combine
import SwiftUI

// MARK: - 组件描述与协议

/// 元数据与默认布局由组件自行声明，新增组件不再维护第二份中央默认值表。
struct ModuleDescriptor: Equatable {
    let id: String
    let title: String
    let systemImage: String
    let summary: String
    var defaultConfig = ModuleConfig(enabled: true, pinned: false)
    var presentation = ModulePresentationOptions()
}

/// 面板子项模块：所有面板内容（内置或自定义）都通过此协议接入 NotchDeck。
/// 新增模块只需实现本协议并在 `ModuleRegistry` 注册，即可获得：
/// 设置中的开关/区域/样式配置、统一滚动与模块生命周期管理。
protocol NotchModule: ObservableObject {
    /// id 是历史配置的持久化 key，发布后不得随名称调整而改变。
    static var descriptor: ModuleDescriptor { get }
    /// 不可用时隐藏面板内容，设置中仍保留配置入口。
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    /// 由注册表统一管理；关闭模块时停止轮询、订阅和命令执行。
    func start()
    func stop()
    /// 仅向已启动的组件派发；面板已展开时新启用组件也能收到一次展开事件。
    func panelDidExpand()
    func panelDidCollapse()
    /// 面板内容
    associatedtype Content: View
    func content() -> Content
    /// 返回 Form 内的 Section；默认无独立设置页，不需要修改宿主设置导航。
    associatedtype SettingsContent: View = EmptyView
    func settingsContent() -> SettingsContent
}

extension NotchModule {
    var id: String { Self.descriptor.id }
    var title: String { Self.descriptor.title }
    var systemImage: String { Self.descriptor.systemImage }
    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }
    func panelDidExpand() {}
    func panelDidCollapse() {}
}

extension NotchModule where SettingsContent == EmptyView {
    func settingsContent() -> EmptyView { EmptyView() }
}

// MARK: - 类型擦除包装

/// 将具体模块擦除为可放入异构集合的盒子，并转发 objectWillChange
final class ModuleBox: ObservableObject, Identifiable {
    let descriptor: ModuleDescriptor
    var id: String { descriptor.id }
    var title: String { descriptor.title }
    var systemImage: String { descriptor.systemImage }
    let makeContent: () -> AnyView
    let makeSettings: (() -> AnyView)?
    let isAvailable: () -> Bool
    let unavailableReason: () -> String?
    private let start: () -> Void
    private let stop: () -> Void
    private let didExpand: () -> Void
    private let didCollapse: () -> Void
    private(set) var isActive = false
    private var panelExpanded = false

    private var cancellable: AnyCancellable?

    init<M: NotchModule>(_ module: M) {
        descriptor = M.descriptor
        isAvailable = { [weak module] in module?.isAvailable ?? false }
        unavailableReason = { [weak module] in module?.unavailableReason }
        start = { module.start() }
        stop = { module.stop() }
        didExpand = { module.panelDidExpand() }
        didCollapse = { module.panelDidCollapse() }
        makeContent = { AnyView(module.content()) }
        makeSettings = M.SettingsContent.self == EmptyView.self ? nil : { AnyView(module.settingsContent()) }
        cancellable = module.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit { setActive(false) }

    func content(in context: ModulePresentationContext) -> some View {
        makeContent().environment(\.modulePresentation, context)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if !active { setPanelExpanded(false) }
        isActive = active
        active ? start() : stop()
    }

    func setPanelExpanded(_ expanded: Bool) {
        guard isActive, expanded != panelExpanded else { return }
        panelExpanded = expanded
        expanded ? didExpand() : didCollapse()
    }
}

// MARK: - 模块注册表

final class ModuleRegistry: ObservableObject {
    @Published private(set) var boxes: [ModuleBox] = []
    private var cancellables: [String: AnyCancellable] = [:]
    private var panelExpanded = false

    deinit { stopAll() }

    @discardableResult
    func register<M: NotchModule>(_ module: M) -> Bool {
        register(ModuleBox(module))
    }

    @discardableResult
    func register(_ box: ModuleBox) -> Bool {
        guard !box.id.isEmpty, box.id == box.id.trimmingCharacters(in: .whitespacesAndNewlines),
              box.descriptor.presentation.isValid,
              !boxes.contains(where: { $0.id == box.id }) else { return false }
        cancellables[box.id] = box.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        boxes.append(box)
        return true
    }

    @discardableResult
    func unregister(_ id: String) -> Bool {
        guard let box = boxes.first(where: { $0.id == id }) else { return false }
        cancellables.removeValue(forKey: id)
        box.setActive(false)
        boxes.removeAll { $0.id == id }
        return true
    }

    func updateActivity(settings: SettingsStore) {
        for box in boxes {
            box.setActive(settings.config(for: box.id, default: box.descriptor.defaultConfig).enabled && box.isAvailable())
            box.setPanelExpanded(panelExpanded)
        }
    }

    func setPanelExpanded(_ expanded: Bool) {
        panelExpanded = expanded
        boxes.forEach { $0.setPanelExpanded(expanded) }
    }

    func stopAll() {
        panelExpanded = false
        boxes.forEach { $0.setActive(false) }
    }
}
