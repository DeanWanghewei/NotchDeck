import AppKit
import Combine

/// 全局可观察状态与各模块 Monitor 的聚合根，注入面板 SwiftUI 视图树
final class AppModel: ObservableObject {
    static let openSettingsRequest = Notification.Name("NotchDeckOpenSettings")
    static let quitRequest = Notification.Name("NotchDeckQuit")

    @Published var isExpanded = false

    let music = MusicMonitor()
    let system = SystemMonitor()
    let node = NodeProcessScanner()
    let settings = SettingsStore.shared

    func startAll() {
        system.start()
        node.start()
        music.start()
    }
}
