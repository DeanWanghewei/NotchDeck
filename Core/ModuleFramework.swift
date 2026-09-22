import Combine
import SwiftUI

// MARK: - 模块协议（框架核心）

/// 面板子项模块：所有面板内容（内置或自定义）都通过此协议接入 NotchDeck。
/// 新增模块只需实现本协议并在 `ModuleRegistry` 注册，即可获得：
/// 设置中的开关/位置配置、常驻区/标签页布局、统一滚动与模块生命周期管理。
protocol NotchModule: ObservableObject {
    /// 稳定标识（持久化配置的 key）
    var id: String { get }
    /// 显示名称（设置界面与常驻区标题）
    var title: String { get }
    /// SF Symbol 图标名（标签页图标）
    var systemImage: String { get }
    /// 是否可用；不可用的模块不出现在面板与设置中
    var isAvailable: Bool { get }
    /// 由注册表统一管理；关闭模块时停止轮询、订阅和命令执行。
    func start()
    func stop()
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
    private let start: () -> Void
    private let stop: () -> Void
    private(set) var isActive = false

    private var cancellable: AnyCancellable?

    init<M: NotchModule>(_ module: M) {
        id = module.id
        title = module.title
        systemImage = module.systemImage
        isAvailable = { [weak module] in module?.isAvailable ?? false }
        start = { module.start() }
        stop = { module.stop() }
        makeContent = { AnyView(module.content()) }
        cancellable = module.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        active ? start() : stop()
    }
}

// MARK: - 模块注册表

final class ModuleRegistry: ObservableObject {
    @Published private(set) var boxes: [ModuleBox] = []
    private var cancellables: Set<AnyCancellable> = []

    func register<M: NotchModule>(_ module: M) {
        guard !boxes.contains(where: { $0.id == module.id }) else { return }
        let box = ModuleBox(module)
        box.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        boxes.append(box)
    }

    func updateActivity(settings: SettingsStore) {
        for box in boxes {
            box.setActive(settings.config(for: box.id).enabled && box.isAvailable())
        }
    }
}

// MARK: - 自定义子项模型

/// 用户自定义的命令小部件：执行 shell 命令并展示输出
struct CustomItem: Codable, Identifiable, Equatable {
    /// 展示方式：text = 原样显示输出；heatmap = 输出解析为数值序列后按大小着色
    enum Display: String, Codable, Equatable {
        case text
        case heatmap
    }

    var id = UUID().uuidString
    var name = ""
    var command = ""
    var display: Display = .text
}

/// 旧版本持久化数据没有 display 字段，缺失或损坏时回退默认值而不是整体丢弃
extension CustomItem {
    private enum CodingKeys: String, CodingKey {
        case id, name, command, display
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        display = try container.decodeIfPresent(Display.self, forKey: .display) ?? .text
    }
}

/// 用户添加到面板的第三方 App
struct PanelApp: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var bundleID: String
    var name: String
    var path: String
}

// MARK: - 已适配应用白名单

/// 已深度适配的 App：添加到面板时显示"已适配"标记，具备更深度的集成能力
enum AdaptedApps {
    /// bundleID → 适配能力说明
    static let whitelist: [String: String] = [
        "com.apple.Music": "媒体播放控制与曲目展示",
        "com.spotify.client": "媒体播放控制与曲目展示",
    ]

    static func isAdapted(_ bundleID: String) -> Bool {
        whitelist[bundleID] != nil
    }

    static func adaptationNote(_ bundleID: String) -> String? {
        whitelist[bundleID]
    }
}
