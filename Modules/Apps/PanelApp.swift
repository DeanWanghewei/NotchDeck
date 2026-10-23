import Foundation

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
