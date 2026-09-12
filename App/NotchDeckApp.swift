import SwiftUI

@main
struct NotchDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 无常驻主窗口：UI 由顶部面板 + 菜单栏图标组成
        Settings {
            EmptyView()
        }
    }
}
