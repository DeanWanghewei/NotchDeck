import AppKit
import Combine
import SwiftUI

struct MediaTrack: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var appName = ""
    var appBundleID: String?
    var artwork: NSImage?
    var duration: Double = 0
    var elapsed: Double = 0

    static func == (lhs: MediaTrack, rhs: MediaTrack) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album &&
            lhs.isPlaying == rhs.isPlaying && lhs.appName == rhs.appName &&
            lhs.duration == rhs.duration && lhs.elapsed == rhs.elapsed
    }
}

/// 媒体模块（最小权限模型）：
/// - 默认不查询任何 App、不申请任何权限
/// - 用户在设置中启用某个媒体源（Music / Spotify / …）后才发起 AppleScript，
///   授权弹窗在"启用后首次读取"那一刻才出现
/// - 只对已安装且已启用的 App 发起脚本，绝不触发"定位应用"弹窗
///
/// 备注：系统级"正在播放"（MediaRemote 私有框架）在 macOS 15.4+ 对第三方进程
/// 静默不应答且符号 ABI 已变化（ForOrigin 变体），故不接入；模块框架保留了
/// 接入更广媒体源的位置（knownSources 注册表）。
final class MediaModule: ObservableObject, NotchModule {
    let id = "media"
    let title = "媒体"
    let systemImage = "waveform"

    /// 受支持的媒体源注册表（后续可扩展更多 App）
    struct MediaSource {
        let name: String          // AppleScript 目标名
        let bundleID: String
        let displayName: String
        let symbol: String
    }

    static let knownSources: [MediaSource] = [
        MediaSource(name: "Music", bundleID: "com.apple.Music", displayName: "Music", symbol: "music.note"),
        MediaSource(name: "Spotify", bundleID: "com.spotify.client", displayName: "Spotify", symbol: "dot.radiowaves.left.and.right"),
    ]

    /// 本机已安装、可添加的媒体源（供设置界面展示）
    static var installedSources: [MediaSource] {
        knownSources.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    @Published private(set) var track: MediaTrack?
    /// track 最近一次更新的时间（进度条推进用）
    private(set) var trackUpdatedAt = Date()

    private var pollTimer: Timer?
    private var refreshDebounce: DispatchWorkItem?
    private let scriptQueue = DispatchQueue(label: "com.notchdeck.media", qos: .utility)
    private var artworkKey = ""
    private let settings = SettingsStore.shared

    deinit {
        pollTimer?.invalidate()
    }

    func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func content() -> some View {
        MediaView(module: self)
    }

    /// 供设置界面在启用/关闭媒体源后立即刷新（授权弹窗在此时刻触发，语境清晰）
    func requestRefresh() {
        refreshSoon()
    }

    /// 未配置任何媒体源（用于空态引导）
    var noSourceConfigured: Bool {
        enabledSources.isEmpty
    }

    /// 已启用且已安装的媒体源
    private var enabledSources: [(name: String, bundleID: String)] {
        Self.knownSources.compactMap { source in
            guard settings.mediaSources.contains(source.bundleID),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) != nil else {
                return nil
            }
            return (source.name, source.bundleID)
        }
    }

    // MARK: - 控制

    func togglePlayPause() {
        send("playpause")
        refreshSoon()
    }

    func playNext() {
        send("next track")
        refreshSoon()
    }

    func playPrevious() {
        send("previous track")
        refreshSoon()
    }

    /// 跳转到当前播放源对应的 App
    func openApp() {
        guard let appName = track?.appName, !appName.isEmpty else { return }
        Scripting.open(appName: appName)
    }

    private func send(_ command: String) {
        guard let appName = track?.appName, !appName.isEmpty else { return }
        scriptQueue.async {
            Scripting.run("tell application \"\(appName)\" to \(command)")
        }
    }

    // MARK: - 状态刷新

    private func refreshSoon() {
        refreshDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func refresh() {
        // 最小权限：没有启用的媒体源时不发起任何脚本
        let candidates = enabledSources
        guard !candidates.isEmpty else {
            if track != nil {
                track = nil
                artworkKey = ""
            }
            return
        }

        scriptQueue.async { [weak self] in
            guard let self else { return }

            var chosen: MediaTrack?
            for (appName, bundleID) in candidates {
                guard let raw = Scripting.run(Scripting.infoScript(for: appName)),
                      var parsed = Scripting.parse(raw) else { continue }
                parsed.appName = appName
                parsed.appBundleID = bundleID
                if chosen == nil || parsed.isPlaying {
                    chosen = parsed
                }
            }

            guard var newTrack = chosen else {
                DispatchQueue.main.async {
                    self.track = nil
                    self.artworkKey = ""
                }
                return
            }

            let key = "\(newTrack.appName)|\(newTrack.title)|\(newTrack.album)"
            if key == self.artworkKey {
                newTrack.artwork = self.track?.artwork
            } else {
                self.artworkKey = key
                if let data = Scripting.runData(Scripting.artworkScript(for: newTrack.appName)),
                   let image = NSImage(data: data) {
                    newTrack.artwork = image
                }
            }

            DispatchQueue.main.async {
                self.track = newTrack
                self.trackUpdatedAt = Date()
            }
        }
    }
}

// MARK: - AppleScript 执行（仅针对已安装且已启用的 App）

enum Scripting {
    @discardableResult
    static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("NotchDeck AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }

    static func runData(_ source: String) -> Data? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("NotchDeck AppleScript error: \(error)")
            return nil
        }
        let data = output.data
        return data.isEmpty ? nil : data
    }

    /// "title|artist|album|state|elapsed|duration"
    static func infoScript(for app: String) -> String {
        """
        tell application "\(app)"
            if it is running then
                try
                    set theName to name of current track
                    set theArtist to artist of current track
                    set theAlbum to album of current track
                    set st to "stopped"
                    if player state is playing then set st to "playing"
                    if player state is paused then set st to "paused"
                    set theElapsed to player position
                    set theDuration to duration of current track
                    return theName & "|" & theArtist & "|" & theAlbum & "|" & st & "|" & (theElapsed as text) & "|" & (theDuration as text)
                on error
                    return ""
                end try
            end if
            return ""
        end tell
        """
    }

    static func artworkScript(for app: String) -> String {
        switch app {
        case "Spotify":
            return """
            tell application "Spotify"
                if it is running then
                    try
                        return artwork of current track
                    on error
                        return ""
                    end try
                end if
                return ""
            end tell
            """
        default:
            return """
            tell application "\(app)"
                if it is running then
                    try
                        return data of artwork 1 of current track
                    on error
                        return ""
                    end try
                end if
                return ""
            end tell
            """
        }
    }

    static func parse(_ raw: String?) -> MediaTrack? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 6, !parts[0].isEmpty else { return nil }
        var track = MediaTrack()
        track.title = parts[0]
        track.artist = parts[1]
        track.album = parts[2]
        track.isPlaying = parts[3] == "playing"
        track.elapsed = Double(parts[4]) ?? 0
        track.duration = Double(parts[5]) ?? 0
        return track
    }

    static func open(appName: String) {
        let bundleIDs = ["Music": "com.apple.Music", "Spotify": "com.spotify.client"]
        if let bundleID = bundleIDs[appName],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
