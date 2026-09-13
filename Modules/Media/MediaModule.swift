import AppKit
import Combine
import SwiftUI

struct MediaTrack: Decodable {
    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var elapsed: Double = 0
    var duration: Double = 0
    var artworkURL = ""
    var appName = ""
    var appBundleID: String?
    var artwork: NSImage?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, isPlaying, elapsed, duration, artworkURL
    }

    var artworkKey: String { "\(appBundleID ?? "")|\(title)|\(artist)|\(album)|\(artworkURL)" }
}

/// 每次只允许一个媒体查询，脚本在有超时的子进程中执行，状态只在主队列更新。
final class MediaModule: ObservableObject, NotchModule {
    let id = "media"
    let title = "媒体"
    let systemImage = "waveform"

    struct MediaSource {
        let name: String
        let bundleID: String
        let displayName: String
        let symbol: String
    }

    static let knownSources: [MediaSource] = [
        MediaSource(name: "Music", bundleID: "com.apple.Music", displayName: "Music", symbol: "music.note"),
        MediaSource(name: "Spotify", bundleID: "com.spotify.client", displayName: "Spotify", symbol: "dot.radiowaves.left.and.right"),
    ]

    static var installedSources: [MediaSource] {
        knownSources.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    @Published private(set) var track: MediaTrack?
    private(set) var trackUpdatedAt = Date()
    private let settings = SettingsStore.shared
    private let scriptQueue = DispatchQueue(label: "com.notchdeck.media", qos: .utility)
    private var pollTimer: Timer?
    private var settingsSubscription: AnyCancellable?
    private var cancellation: Shell.Cancellation?
    private var artworkTask: URLSessionDataTask?
    private var artworkCancellation: Shell.Cancellation?
    private var artworkKey = ""
    private var active = false
    private var refreshing = false
    private var generation = 0

    deinit {
        pollTimer?.invalidate()
        cancellation?.cancel()
        artworkCancellation?.cancel()
        artworkTask?.cancel()
    }

    func start() {
        guard !active else { return }
        active = true
        settingsSubscription = settings.$mediaSources.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestRefresh() }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        active = false
        invalidateRefresh()
        pollTimer?.invalidate()
        pollTimer = nil
        settingsSubscription = nil
        track = nil
    }

    func content() -> some View { MediaView(module: self) }
    var noSourceConfigured: Bool { enabledSources.isEmpty }

    private var enabledSources: [MediaSource] {
        Self.installedSources.filter { settings.mediaSources.contains($0.bundleID) }
    }

    func requestRefresh() {
        invalidateRefresh()
        track = nil
        refresh()
    }

    private func invalidateRefresh() {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        artworkCancellation?.cancel()
        artworkCancellation = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = ""
        refreshing = false
    }

    func togglePlayPause() { send("playpause") }
    func playNext() { send("nextTrack") }
    func playPrevious() { send("previousTrack") }

    func openApp() {
        guard let bundleID = track?.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        guard active, let bundleID = track?.appBundleID,
              enabledSources.contains(where: { $0.bundleID == bundleID }) else { return }
        invalidateRefresh()
        let version = generation
        let token = Shell.Cancellation()
        cancellation = token
        refreshing = true
        scriptQueue.async { [weak self] in
            _ = Shell.execute("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e",
                "const app = Application('\(bundleID)'); if (app.running()) app.\(command)();"],
                cancellation: token)
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == version else { return }
                self.refreshing = false
                self.refresh()
            }
        }
    }

    func refresh() {
        guard active, !refreshing else { return }
        // 不向未运行的应用发送事件，避免后台轮询启动应用或弹出授权。
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = enabledSources.filter { runningIDs.contains($0.bundleID) }
        guard !candidates.isEmpty else {
            track = nil
            artworkKey = ""
            artworkTask?.cancel()
            artworkCancellation?.cancel()
            return
        }
        refreshing = true
        let version = generation
        let token = Shell.Cancellation()
        cancellation = token
        scriptQueue.async { [weak self] in
            var chosen: MediaTrack?
            for source in candidates {
                guard !token.isCancelled else { break }
                let result = Shell.execute("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e",
                    Scripting.infoScript(for: source.bundleID)], cancellation: token)
                guard result.completion == .exited(0),
                      var parsed = Scripting.parse(result.output, bundleID: source.bundleID) else { continue }
                parsed.appName = source.displayName
                parsed.appBundleID = source.bundleID
                if chosen == nil || parsed.isPlaying { chosen = parsed }
                if parsed.isPlaying { break }
            }
            let sampledAt = Date()
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == version else { return }
                self.refreshing = false
                self.cancellation = nil
                if var chosen {
                    if chosen.artworkKey == self.track?.artworkKey { chosen.artwork = self.track?.artwork }
                    self.trackUpdatedAt = sampledAt
                    self.track = chosen
                    self.loadArtwork(for: chosen)
                } else {
                    self.track = nil
                    self.artworkKey = ""
                    self.artworkTask?.cancel()
                }
            }
        }
    }

    private func loadArtwork(for track: MediaTrack) {
        let key = track.artworkKey
        guard key != artworkKey else { return }
        artworkKey = key
        artworkTask?.cancel()
        artworkCancellation?.cancel()
        let version = generation
        if track.appBundleID == "com.spotify.client" {
            guard let url = URL(string: track.artworkURL), url.scheme == "https" else { return }
            let request = URLRequest(url: url, timeoutInterval: 6)
            artworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                let valid = (response as? HTTPURLResponse)?.statusCode == 200
                DispatchQueue.main.async {
                    self?.applyArtwork(valid ? data : nil, key: key, version: version)
                }
            }
            artworkTask?.resume()
        } else {
            let token = Shell.Cancellation()
            artworkCancellation = token
            // Music 的 raw data 经 osascript 输出为 «data XXXX十六进制内容»。
            scriptQueue.async { [weak self] in
                let result = Shell.execute("/usr/bin/osascript", arguments: ["-e", """
                    tell application id "com.apple.Music"
                        if it is running then
                            try
                                return raw data of artwork 1 of current track
                            end try
                        end if
                    end tell
                    """], outputLimit: 8 * 1024 * 1024, cancellation: token)
                let data = result.completion == .exited(0) ? Scripting.artworkData(result.output) : nil
                DispatchQueue.main.async { self?.applyArtwork(data, key: key, version: version) }
            }
        }
    }

    private func applyArtwork(_ data: Data?, key: String, version: Int) {
        guard active, generation == version, track?.artworkKey == key,
              let data, data.count <= 4 * 1024 * 1024, let image = NSImage(data: data) else { return }
        track?.artwork = image
    }
}

/// JSON 保留标题中的分隔符、引号和换行；Spotify 的 duration 单位为毫秒。
enum Scripting {
    static func infoScript(for bundleID: String) -> String {
        """
        const app = Application('\(bundleID)');
        if (app.running()) {
            const track = app.currentTrack();
            JSON.stringify({title: track.name(), artist: track.artist(), album: track.album(),
                isPlaying: app.playerState() === 'playing', elapsed: app.playerPosition(),
                duration: track.duration(),
                artworkURL: '\(bundleID)' === 'com.spotify.client' ? track.artworkUrl() : ''});
        } else { ''; }
        """
    }

    static func parse(_ raw: String, bundleID: String) -> MediaTrack? {
        guard var track = try? JSONDecoder().decode(MediaTrack.self, from: Data(raw.utf8)),
              !track.title.isEmpty, track.duration.isFinite, track.elapsed.isFinite else { return nil }
        if bundleID == "com.spotify.client" { track.duration /= 1000 }
        track.duration = max(0, track.duration)
        track.elapsed = min(max(0, track.elapsed), track.duration)
        return track
    }

    static func artworkData(_ raw: String) -> Data? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("«data "), value.hasSuffix("»"), value.count >= 12 else { return nil }
        let hex = Array(value.dropFirst(10).dropLast().utf8)
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }
}
