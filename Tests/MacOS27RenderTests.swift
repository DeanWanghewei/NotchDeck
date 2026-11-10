import AppKit
import Combine
import SwiftUI
import XCTest

/// macOS 27 实机复核自渲染：系统监控卡是色彩与数字展示最敏感的一屏
/// （HeatScale 冷暖色标 + 百分比必显数字 + 悬停明细行式结构），
/// 系统版本变化后必须重新目检深浅两版，不能沿用旧系统的结论。
///
/// 仅在设置 `NOTCHDECK_RENDER_DIR` 时执行；xcodebuild 用 `TEST_RUNNER_` 前缀传入，
/// 直接用 xctest 运行时传 `NOTCHDECK_RENDER_DIR=... xcrun xctest ...`。
@MainActor
final class MacOS27RenderTests: XCTestCase {
    func testRenderSystemMonitorWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "com.notchdeck.macos27.render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let monitor = SystemMonitor(settings: settings)
        monitor.start()
        defer { monitor.stop() }
        // 采样周期 1 秒，等两个周期拿到差分基线与磁盘/电池数据
        Thread.sleep(forTimeInterval: 2.5)

        try render(SystemMonitorView(monitor: monitor, settings: settings),
                   name: "system-monitor", size: NSSize(width: 520, height: 560), directory: directory)
        // 固定 CPU 明细：每核占用是行式明细（标签 + 用量条 + 右对齐数值）的规范样板
        try render(SystemMonitorView(monitor: monitor, settings: settings, initialPinnedDetail: .cpu),
                   name: "system-monitor-cpu-detail", size: NSSize(width: 520, height: 620), directory: directory)
        try render(SystemMonitorView(monitor: monitor, settings: settings, initialPinnedDetail: .memory),
                   name: "system-monitor-memory-detail", size: NSSize(width: 520, height: 620), directory: directory)
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize, directory: String,
                                 padding: CGFloat = 16) throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: view
                .padding(padding).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // 屏幕外呈现窗口，让布局与首帧渲染完成后再缓存，避免截到空白帧。
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            let rendered = expectation(description: "等待首帧渲染完成")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { rendered.fulfill() }
            wait(for: [rendered], timeout: 2)
            host.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("无法渲染"); continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = directory + "/" + name + "-" + (dark ? "dark" : "light") + ".png"
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
