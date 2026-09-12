import AppKit
import Foundation

/// 通过 AppleScript 控制播放。首次控制会触发系统自动化授权弹窗，允许一次即可
enum MusicController {
    static func togglePlayPause(source: TrackInfo.Source) {
        send("playpause", to: source)
    }

    static func playNext(source: TrackInfo.Source) {
        send("next track", to: source)
    }

    static func playPrevious(source: TrackInfo.Source) {
        send("previous track", to: source)
    }

    /// 跳转到对应 App（M4）
    static func openApp(source: TrackInfo.Source) {
        switch source {
        case .appleMusic:
            let url = URL(fileURLWithPath: "/System/Applications/Music.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .spotify:
            if let url = URL(string: "spotify:") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func send(_ command: String, to app: TrackInfo.Source) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: "tell application \"\(app.rawValue)\" to \(command)")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                NSLog("NotchDeck AppleScript error: \(error)")
            }
        }
    }
}
