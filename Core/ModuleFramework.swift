import Combine
import SwiftUI

// MARK: - 模块协议（框架核心）

/// 面板子项模块：所有面板内容（内置或自定义）都通过此协议接入 NotchDeck。
/// 新增模块只需实现本协议并在 `ModuleRegistry` 注册，即可获得：
/// 设置中的开关/位置配置、常驻区/标签页布局、面板动态高度等能力。
protocol NotchModule: ObservableObject {
    /// 稳定标识（持久化配置的 key）
    var id: String { get }
    /// 显示名称（设置界面与常驻区标题）
    var title: String { get }
    /// SF Symbol 图标名（标签页图标）
    var systemImage: String { get }
    /// 是否可用；不可用的模块不出现在面板与设置中
    var isAvailable: Bool { get }
    /// 面板内容
    associatedtype Content: View
    func content() -> Content
}

extension NotchModule {
    var isAvailable: Bool { true }
}

// MARK: - 类型擦除包装

/// 将具体模块擦除为可放入异构集合的盒子，并转发 objectWillChange
final class ModuleBox: ObservableObject, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let makeContent: () -> AnyView
    let isAvailable: () -> Bool

    private var cancellable: AnyCancellable?

    init<M: NotchModule>(_ module: M) {
        id = module.id
        title = module.title
        systemImage = module.systemImage
        isAvailable = { [weak module] in module?.isAvailable ?? false }
        makeContent = { AnyView(module.content()) }
        cancellable = module.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

// MARK: - 模块注册表

final class ModuleRegistry: ObservableObject {
    @Published private(set) var boxes: [ModuleBox] = []
    private var cancellables: Set<AnyCancellable> = []

    func register<M: NotchModule>(_ module: M) {
        let box = ModuleBox(module)
        box.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        boxes.append(box)
    }
}

// MARK: - 自定义子项模型

/// 用户自定义的命令小部件：执行 shell 命令并展示输出
struct CustomItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var command = ""
}
