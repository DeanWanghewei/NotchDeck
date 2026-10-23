import SwiftUI

/// 使用逻辑区域而非屏幕坐标，避免插件在不同刘海、窗口尺寸下互相遮挡。
enum ModulePlacement: String, Codable, CaseIterable, Identifiable {
    case top, tab, bottom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "顶部常驻"
        case .tab: return "标签页"
        case .bottom: return "底部常驻"
        }
    }
}

/// 样式 id 由插件定义，宿主仅提供选择和持久化，不假设插件的数据类型。
struct ModuleDisplayMode: Identifiable, Equatable {
    let id: String
    let title: String
    static let standard = Self(id: "standard", title: "标准")
}

struct ModulePresentationOptions: Equatable {
    var placements = ModulePlacement.allCases
    var displayModes: [ModuleDisplayMode] = [.standard]
    var showsSectionHeader = true

    var isValid: Bool {
        !placements.isEmpty && Set(placements).count == placements.count &&
        !displayModes.isEmpty && Set(displayModes.map(\.id)).count == displayModes.count &&
        displayModes.allSatisfy { mode in
            !mode.id.isEmpty && mode.id.count <= 64 &&
            mode.id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } &&
            !mode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mode.title.count <= 40
        }
    }
}

struct ModulePresentationContext: Equatable {
    let placement: ModulePlacement
    let displayModeID: String
}

extension ModuleDescriptor {
    /// 不覆盖未知存储值，回退应用版本后仍可保留用户对新版样式的选择。
    func presentationContext(for config: ModuleConfig) -> ModulePresentationContext {
        let placement = presentation.placements.contains(config.placement) ? config.placement :
            (presentation.placements.contains(defaultConfig.placement) ? defaultConfig.placement :
                presentation.placements.first ?? .tab)
        let modes = presentation.displayModes
        let mode = modes.first { $0.id == config.displayModeID } ??
            modes.first { $0.id == defaultConfig.displayModeID } ?? modes.first ?? .standard
        return ModulePresentationContext(placement: placement, displayModeID: mode.id)
    }
}

private struct ModulePresentationKey: EnvironmentKey {
    static let defaultValue = ModulePresentationContext(placement: .tab, displayModeID: "standard")
}

extension EnvironmentValues {
    var modulePresentation: ModulePresentationContext {
        get { self[ModulePresentationKey.self] }
        set { self[ModulePresentationKey.self] = newValue }
    }
}
