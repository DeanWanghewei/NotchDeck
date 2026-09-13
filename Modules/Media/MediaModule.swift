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
    /// 实验性系统级检测的运行状态：连续失败后置 false，定期自动重试
    @Published private(set) var experimentalAvailable = true
    /// 当前曲目是否来自实验性系统级检测（决定控制指令的走向）
    private(set) var trackViaAdapter = false
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
    /// 实验性：常驻事件流进程（stream --no-diff），曲目/进度变化即时推送
    private var streamProcess: Process?
    private var streamPipe: Pipe?
    private var streamBuffer = Data()
    private var streamStartedAt = Date.distantPast
    private var streamRestartAttempts = 0

    deinit {
        pollTimer?.invalidate()
        cancellation?.cancel()
        artworkCancellation?.cancel()
        artworkTask?.cancel()
        streamProcess?.terminationHandler = nil
        streamProcess?.terminate()
    }

    func start() {
        guard !active else { return }
        active = true
        settingsSubscription = settings.$mediaSources.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestRefresh() }
        settings.$experimentalNowPlaying.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startStreamIfNeeded()
                } else {
                    self.stopStream()
                }
                self.requestRefresh()
            }
        if settings.experimentalNowPlaying { startStreamIfNeeded() }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        active = false
        invalidateRefresh()
        stopStream()
        pollTimer?.invalidate()
        pollTimer = nil
        settingsSubscription = nil
        track = nil
    }

    func content() -> some View { MediaView(module: self) }
    var noSourceConfigured: Bool { enabledSources.isEmpty }
    /// 实验性系统级检测是否处于开启状态（决定空态的呈现）
    var experimentalActive: Bool { settings.experimentalNowPlaying }

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
        guard active else { return }
        // 实验性路径：当前曲目来自系统级检测时，控制指令同样经适配器发送
        if trackViaAdapter {
            guard settings.experimentalNowPlaying, experimentalAvailable,
                  let paths = Self.adapterPaths else { return }
            let id: Int
            switch command {
            case "playpause": id = 2   // kMRTogglePlayPause
            case "nextTrack": id = 4   // kMRNextTrack
            default: id = 5            // kMRPreviousTrack
            }
            scriptQueue.async { [weak self] in
                Shell.execute(paths.perl, arguments: [paths.script, paths.framework, "send", String(id)], timeout: 4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.requestRefresh()
                }
            }
            return
        }
        guard let bundleID = track?.appBundleID,
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
        // 实验性系统级检测：事件流常驻时由流推送驱动，无需轮询
        if settings.experimentalNowPlaying {
            if streamProcess != nil { return }
            if experimentalAvailable {
                if startStreamIfNeeded() { return }
            } else if Date().timeIntervalSince(lastAdapterFailure) > 60 {
                experimentalAvailable = true
                adapterFailures = 0
                if startStreamIfNeeded() { return }
            }
        }
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

    // MARK: - 实验性：系统级正在播放（mediaremote-adapter，BSD-3，见 Vendor/mediaremote-adapter）

    private var adapterFailures = 0
    private var lastAdapterFailure = Date.distantPast

    /// 资源目录中的 perl 脚本与适配器框架（随 App 打包）
    static var adapterPaths: (perl: String, script: String, framework: String)? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let script = resourceURL.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = resourceURL.appendingPathComponent("MediaRemoteAdapter.framework").path
        let perl = "/usr/bin/perl"
        let fm = FileManager.default
        guard fm.fileExists(atPath: script), fm.fileExists(atPath: framework), fm.fileExists(atPath: perl) else {
            return nil
        }
        return (perl, script, framework)
    }

    /// 经系统 Perl（com.apple.perl5，mediaremoted 仅信任 com.apple.* 客户端）读取系统正在播放
    /// 启动常驻事件流（stream --no-diff）：曲目/进度变化即时推送 JSON 行；
    /// 已在运行则直接返回 true；无法启动返回 false（调用方走失败处理）
    @discardableResult
    private func startStreamIfNeeded() -> Bool {
        guard streamProcess == nil, active else { return streamProcess != nil }
        guard let paths = Self.adapterPaths else {
            handleAdapterFailure()
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.perl)
        process.arguments = [paths.script, paths.framework, "stream", "--no-diff"]
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        streamBuffer = Data()
        streamStartedAt = Date()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeStreamData(data)
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                guard let self, self.streamProcess === terminatedProcess else { return }
                // 稳定运行 30 秒后重置重启计数
                if Date().timeIntervalSince(self.streamStartedAt) > 30 { self.streamRestartAttempts = 0 }
                self.streamProcess = nil
                self.streamPipe = nil
                self.streamBuffer = Data()
                guard self.active, self.settings.experimentalNowPlaying else { return }
                self.streamRestartAttempts += 1
                if self.streamRestartAttempts <= 5 {
                    let delay = min(8.0, pow(2.0, Double(self.streamRestartAttempts)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.startStreamIfNeeded()
                    }
                } else {
                    self.experimentalAvailable = false
                    self.lastAdapterFailure = Date()
                }
            }
        }
        do {
            try process.run()
        } catch {
            handleAdapterFailure()
            return false
        }
        streamProcess = process
        streamPipe = pipe
        return true
    }

    private func stopStream() {
        streamProcess?.terminationHandler = nil
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamProcess?.terminate()
        streamProcess = nil
        streamPipe = nil
        streamBuffer = Data()
    }

    /// 解析事件流行（按 \n 分帧），逐条派发主线程更新
    private func consumeStreamData(_ data: Data) {
        streamBuffer.append(data)
        while let newline = streamBuffer.range(of: Data([0x0A])) {
            let lineData = streamBuffer.subdata(in: streamBuffer.startIndex..<newline.lowerBound)
            streamBuffer.removeSubrange(streamBuffer.startIndex...newline.lowerBound)
            guard let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            let track = Self.track(fromAdapterJSON: payload)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.settings.experimentalNowPlaying else { return }
                self.applyAdapterTrack(track)
            }
        }
    }

    /// 应用事件流推送的曲目状态（主线程）
    private func applyAdapterTrack(_ incoming: MediaTrack?) {
        var chosen = incoming
        if chosen != nil, chosen!.artworkKey == track?.artworkKey { chosen!.artwork = track?.artwork }
        if chosen != nil, chosen!.appName.isEmpty { chosen!.appName = "正在播放" }
        trackViaAdapter = chosen != nil
        if chosen != nil {
            trackUpdatedAt = Date()
            track = chosen
        } else {
            track = nil
            artworkKey = ""
            artworkTask?.cancel()
        }
    }

    /// 适配器 JSON → MediaTrack；无播放（无标题）时返回 nil
    static func track(fromAdapterJSON json: [String: Any]) -> MediaTrack? {
        guard let title = json["title"] as? String, !title.isEmpty else { return nil }
        var track = MediaTrack()
        track.title = title
        track.artist = json["artist"] as? String ?? ""
        track.album = json["album"] as? String ?? ""
        if let playing = json["playing"] as? Bool {
            track.isPlaying = playing
        } else {
            track.isPlaying = (json["playbackRate"] as? Double ?? 0) > 0
        }
        track.duration = json["duration"] as? Double ?? 0
        track.elapsed = min(max(0, json["elapsedTime"] as? Double ?? 0), max(0, json["duration"] as? Double ?? .greatestFiniteMagnitude))
        track.appBundleID = json["bundleIdentifier"] as? String
        if let pid = json["processIdentifier"] as? Int,
           let running = NSRunningApplication(processIdentifier: pid_t(pid)),
           let name = running.localizedName {
            track.appName = name
        } else if let bundleID = track.appBundleID {
            track.appName = (bundleID as NSString).lastPathComponent
        }
        if let base64 = json["artworkData"] as? String,
           let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            track.artwork = image
        }
        return track
    }

    private func handleAdapterFailure() {
        adapterFailures += 1
        lastAdapterFailure = Date()
        if adapterFailures >= 3 { experimentalAvailable = false }
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
