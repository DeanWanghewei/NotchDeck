import AppKit
import Combine
import Foundation

struct TrackInfo: Equatable {
    enum Source: String {
        case appleMusic = "Music"
        case spotify = "Spotify"
    }

    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var source: Source = .appleMusic
    var artwork: NSImage?

    static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist &&
            lhs.album == rhs.album && lhs.source == rhs.source &&
            lhs.isPlaying == rhs.isPlaying
    }
}

/// 音乐播放监听：DistributedNotificationCenter 推送 + AppleScript 轮询兜底
final class MusicMonitor: ObservableObject {
    @Published private(set) var track: TrackInfo?

    private var pollTimer: Timer?
    private var refreshWorkItem: DispatchWorkItem?
    private var artworkKey = ""
    private var observers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "com.notchdeck.music", qos: .utility)

    deinit {
        pollTimer?.invalidate()
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
    }

    func start() {
        guard pollTimer == nil else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main) { [weak self] _ in self?.refreshSoon() })
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main) { [weak self] _ in self?.refreshSoon() })

        refreshSoon()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
    }

    private func refreshSoon() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func refresh() {
        scriptQueue.async { [weak self] in
            guard let self else { return }

            let appleMusic = Self.parse(Self.runScript(Self.infoScript(for: "Music")), source: .appleMusic)
            let spotify = Self.parse(Self.runScript(Self.infoScript(for: "Spotify")), source: .spotify)

            let chosen: TrackInfo?
            switch (appleMusic, spotify) {
            case (nil, nil):
                chosen = nil
            case let (music?, nil):
                chosen = music
            case let (nil, spotify?):
                chosen = spotify
            case let (music?, spotify?):
                if music.isPlaying == spotify.isPlaying {
                    chosen = music
                } else {
                    chosen = music.isPlaying ? music : spotify
                }
            }

            guard var newTrack = chosen else {
                DispatchQueue.main.async {
                    self.track = nil
                    self.artworkKey = ""
                }
                return
            }

            let key = "\(newTrack.source.rawValue)|\(newTrack.title)|\(newTrack.album)"
            if key != self.artworkKey {
                self.artworkKey = key
                if let data = Self.runScriptData(Self.artworkScript(for: newTrack.source)),
                   let image = NSImage(data: data) {
                    newTrack.artwork = image
                }
            } else if let current = self.track,
                      current.title == newTrack.title, current.source == newTrack.source {
                newTrack.artwork = current.artwork
            }

            DispatchQueue.main.async { self.track = newTrack }
        }
    }

    // MARK: - AppleScript

    private static func infoScript(for app: String) -> String {
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
                    return theName & "|" & theArtist & "|" & theAlbum & "|" & st
                on error
                    return ""
                end try
            end if
            return ""
        end tell
        """
    }

    private static func artworkScript(for source: TrackInfo.Source) -> String {
        switch source {
        case .appleMusic:
            return """
            tell application "Music"
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
        case .spotify:
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
        }
    }

    private static func parse(_ raw: String?, source: TrackInfo.Source) -> TrackInfo? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 4, !parts[0].isEmpty else { return nil }
        var track = TrackInfo()
        track.title = parts[0]
        track.artist = parts[1]
        track.album = parts[2]
        track.isPlaying = parts[3] == "playing"
        track.source = source
        return track
    }

    private static func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("NotchDeck AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }

    private static func runScriptData(_ source: String) -> Data? {
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
}
