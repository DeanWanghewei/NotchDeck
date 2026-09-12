import Foundation

/// MediaRemote 私有框架桥接：系统级"正在播放"（覆盖 Music / Spotify / 浏览器视频等）
/// 全部经 dlopen 动态解析；不可用时上层自动回退 AppleScript 方案
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private var handle: UnsafeMutableRawPointer?
    private(set) var isLoaded = false

    private var getNowPlayingInfo: (@convention(c) (@escaping (CFDictionary?) -> Void) -> Void)?
    private var getPlaying: (@convention(c) (@escaping (Bool) -> Void) -> Void)?
    private var copyNowPlayingApp: (@convention(c) (@escaping (CFString?) -> Void) -> Void)?
    private var sendMediaCommand: (@convention(c) (Int32, CFDictionary?) -> Void)?
    private var registerForNotifications: (@convention(c) (DispatchQueue) -> Void)?

    let infoDidChange: Notification.Name?
    let playingStateDidChange: Notification.Name?
    let nowPlayingAppDidChange: Notification.Name?

    private init() {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else {
            infoDidChange = nil
            playingStateDidChange = nil
            nowPlayingAppDidChange = nil
            return
        }
        handle = framework
        getNowPlayingInfo = Self.symbol(framework, "MRMediaRemoteGetNowPlayingInfo")
        getPlaying = Self.symbol(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        copyNowPlayingApp = Self.symbol(framework, "MRMediaRemoteCopyNowPlayingApplicationBundleIdentifier")
        sendMediaCommand = Self.symbol(framework, "MRMediaRemoteSendCommand")
        registerForNotifications = Self.symbol(framework, "MRMediaRemoteRegisterForNowPlayingNotifications")

        infoDidChange = Self.notificationName(framework, "kMRMediaRemoteNowPlayingInfoDidChangeNotification")
        playingStateDidChange = Self.notificationName(framework, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
        nowPlayingAppDidChange = Self.notificationName(framework, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification")

        isLoaded = getNowPlayingInfo != nil && sendMediaCommand != nil && registerForNotifications != nil
        if isLoaded {
            registerForNotifications?(.main)
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    // MARK: - 对外 API（均在主线程回调）

    func requestNowPlayingInfo(_ completion: @escaping ([String: Any]?) -> Void) {
        guard let getNowPlayingInfo else {
            completion(nil)
            return
        }
        getNowPlayingInfo { dictionary in
            DispatchQueue.main.async {
                guard let dictionary else {
                    completion(nil)
                    return
                }
                completion(dictionary as NSDictionary as? [String: Any])
            }
        }
    }

    func requestIsPlaying(_ completion: @escaping (Bool) -> Void) {
        guard let getPlaying else {
            completion(false)
            return
        }
        getPlaying { playing in
            DispatchQueue.main.async { completion(playing) }
        }
    }

    func requestNowPlayingApp(_ completion: @escaping (String?) -> Void) {
        guard let copyNowPlayingApp else {
            completion(nil)
            return
        }
        copyNowPlayingApp { bundleID in
            DispatchQueue.main.async { completion(bundleID as String?) }
        }
    }

    func send(_ command: Command) {
        sendMediaCommand?(command.rawValue, nil)
    }

    /// 探测 mediaremoted 是否响应本进程：部分系统版本（macOS 15.4+）会静默忽略第三方调用，
    /// 超时未收到回调即视为不可用，上层回退 AppleScript 方案
    func probe(timeout: TimeInterval = 2, completion: @escaping (Bool) -> Void) {
        guard isLoaded else {
            completion(false)
            return
        }
        var answered = false
        requestIsPlaying { _ in
            answered = true
            completion(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !answered else { return }
            completion(false)
        }
    }

    // MARK: - 符号解析

    private static func symbol<T>(_ framework: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func notificationName(_ framework: UnsafeMutableRawPointer, _ symbolName: String) -> Notification.Name? {
        guard let pointer = dlsym(framework, symbolName) else { return nil }
        let cfString = pointer.assumingMemoryBound(to: CFString.self).pointee
        return Notification.Name(cfString as String)
    }
}
