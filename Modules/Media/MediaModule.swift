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
    /// true 时通过 AppleScript 控制（脚本路径产出的曲目）
    var controlViaScript = false
    var artwork: NSImage?
    var duration: Double = 0
    var elapsed: Double = 0

    static func == (lhs: MediaTrack, rhs: MediaTrack) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album &&
            lhs.isPlaying == rhs.isPlaying && lhs.appName == rhs.appName &&
            lhs.duration == rhs.duration && lhs.elapsed == rhs.elapsed
    }
}

/// 媒体模块：
/// - 主路径 AppleScript（Music / Spotify，仅对已安装的 App 发起，避免"选择应用"弹窗）
/// - 启动时探测系统级"正在播放"（MediaRemote）；系统允许时自动启用，
///   可覆盖浏览器视频等任意媒体源，控制与读取走系统通道
final class MediaModule: ObservableObject, NotchModule {
    let id = "media"
    let title = "媒体"
    let systemImage = "waveform"

    @Published private(set) var track: MediaTrack?
    /// track 最近一次更新的时间（进度条推进用）
    private(set) var trackUpdatedAt = Date()

    /// MediaRemote 通道经探测确认可用后为 true
    private var mediaRemoteAvailable = false
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refreshDebounce: DispatchWorkItem?
    private let scriptQueue = DispatchQueue(label: "com.notchdeck.media", qos: .utility)
    private var artworkKey = ""

    private enum InfoKey {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let artwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let artworkAlt = "kMRMediaRemoteNowPlayingInfoArtwork"
    }

    deinit {
        pollTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // 探测系统级"正在播放"是否对本进程开放（部分系统版本会静默忽略第三方调用）
        MediaRemoteBridge.shared.probe { [weak self] available in
            guard let self, available else { return }
            self.mediaRemoteAvailable = true
            self.registerMediaRemoteObservers()
            self.refresh()
        }
    }

    func content() -> some View {
        MediaView(module: self)
    }

    // MARK: - 控制

    func togglePlayPause() {
        control(.togglePlayPause, script: "playpause")
        refreshSoon()
    }

    func playNext() {
        control(.nextTrack, script: "next track")
        refreshSoon()
    }

    func playPrevious() {
        control(.previousTrack, script: "previous track")
        refreshSoon()
    }

    /// 跳转到当前播放源对应的 App
    func openApp() {
        if let bundleID = track?.appBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let name = track?.appName, !name.isEmpty {
            Scripting.open(appName: name)
        }
    }

    private func control(_ command: MediaRemoteBridge.Command, script: String) {
        if track?.controlViaScript == true || !mediaRemoteAvailable {
            if let appName = track?.appName, !appName.isEmpty {
                Scripting.run("tell application \"\(appName)\" to \(script)")
            }
        } else {
            MediaRemoteBridge.shared.send(command)
        }
    }

    // MARK: - 状态刷新

    private func registerMediaRemoteObservers() {
        let center = NotificationCenter.default
        for name in [MediaRemoteBridge.shared.infoDidChange,
                     MediaRemoteBridge.shared.playingStateDidChange,
                     MediaRemoteBridge.shared.nowPlayingAppDidChange].compactMap({ $0 }) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshSoon()
            })
        }
    }

    private func refreshSoon() {
        refreshDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func refresh() {
        if mediaRemoteAvailable {
            refreshViaMediaRemote()
        } else {
            refreshViaAppleScript()
        }
    }

    private func refreshViaMediaRemote() {
        MediaRemoteBridge.shared.requestNowPlayingApp { [weak self] bundleID in
            guard let self else { return }
            MediaRemoteBridge.shared.requestIsPlaying { [weak self] playing in
                guard let self else { return }
                MediaRemoteBridge.shared.requestNowPlayingInfo { [weak self] info in
                    guard let self else { return }
                    if let info, !info.isEmpty, let title = info[InfoKey.title] as? String, !title.isEmpty {
                        var newTrack = MediaTrack()
                        newTrack.title = title
                        newTrack.artist = (info[InfoKey.artist] as? String) ?? ""
                        newTrack.album = (info[InfoKey.album] as? String) ?? ""
                        newTrack.duration = (info[InfoKey.duration] as? Double) ?? 0
                        newTrack.elapsed = (info[InfoKey.elapsed] as? Double) ?? 0
                        newTrack.isPlaying = playing
                        newTrack.appBundleID = bundleID
                        newTrack.appName = Self.displayName(for: bundleID)

                        let key = "\(newTrack.appName)|\(newTrack.title)|\(newTrack.album)"
                        if key == self.artworkKey {
                            newTrack.artwork = self.track?.artwork
                        } else {
                            self.artworkKey = key
                            for artworkKey in [InfoKey.artwork, InfoKey.artworkAlt] {
                                if let data = info[artworkKey] as? Data,
                                   let image = NSImage(data: data) {
                                    newTrack.artwork = image
                                    break
                                }
                            }
                        }
                        self.track = newTrack
                        self.trackUpdatedAt = Date()
                    } else {
                        // 系统通道无数据：走脚本兜底
                        self.refreshViaAppleScript()
                    }
                }
            }
        }
    }

    private func refreshViaAppleScript() {
        scriptQueue.async { [weak self] in
            guard let self else { return }

            let candidates = Self.installedScriptableApps()
            guard !candidates.isEmpty else {
                DispatchQueue.main.async {
                    self.track = nil
                    self.artworkKey = ""
                }
                return
            }

            var chosen: MediaTrack?
            for (appName, bundleID) in candidates {
                guard let raw = Scripting.run(Scripting.infoScript(for: appName)),
                      var parsed = Scripting.parse(raw) else { continue }
                parsed.appName = appName
                parsed.appBundleID = bundleID
                parsed.controlViaScript = true
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

    // MARK: - 辅助

    private static func installedScriptableApps() -> [(name: String, bundleID: String)] {
        let known: [(name: String, bundleID: String)] = [
            ("Music", "com.apple.Music"),
            ("Spotify", "com.spotify.client"),
        ]
        // 只对实际安装的 App 发起脚本，避免系统弹出"定位应用"对话框
        return known.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    private static func displayName(for bundleID: String?) -> String {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return ""
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - AppleScript 执行（仅针对已安装 App，避免"选择应用"弹窗）

private enum Scripting {
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
