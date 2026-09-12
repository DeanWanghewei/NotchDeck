import AppKit
import Combine
import SwiftUI

/// 音量模块：StandardAdditions 脚本读写系统音量，无需任何权限
final class VolumeModule: ObservableObject, NotchModule {
    let id = "volume"
    let title = "音量"
    let systemImage = "speaker.wave.2.fill"

    @Published private(set) var volume: Double = 50
    @Published private(set) var muted = false

    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "com.notchdeck.volume", qos: .utility)
    private var lastSent = Date.distantPast

    deinit {
        pollTimer?.invalidate()
    }

    func start() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func content() -> some View {
        VolumeView(module: self)
    }

    // MARK: - 控制

    /// 拖动滑杆设置音量（节流发送）；editing 结束时 immediate 补发最终值
    func setVolume(_ value: Double, immediate: Bool) {
        volume = value
        let now = Date()
        guard immediate || now.timeIntervalSince(lastSent) > 0.25 else { return }
        lastSent = now
        let rounded = Int(value.rounded())
        queue.async { Self.run("set volume output volume \(rounded)") }
    }

    func toggleMute() {
        muted.toggle()
        queue.async {
            Self.run("set volume output muted (not output muted of (get volume settings))")
        }
        pollSoon()
    }

    // MARK: - 读取

    private func poll() {
        queue.async { [weak self] in
            guard let raw = Self.run("""
            set v to output volume of (get volume settings)
            set m to output muted of (get volume settings)
            return (v as text) & "|" & (m as text)
            """) else { return }
            let parts = raw.components(separatedBy: "|")
            guard parts.count == 2,
                  let volume = Double(parts[0]) else { return }
            DispatchQueue.main.async {
                self?.volume = volume
                self?.muted = parts[1] == "true"
            }
        }
    }

    private func pollSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.poll()
        }
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("NotchDeck AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }
}
