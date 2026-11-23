import AppKit
import Combine
import SwiftUI
import XCTest

/// 实机截图（仅在设置 NOTCHDECK_LIVE_CAPTURE_DIR 时执行）：在真实屏幕的刘海位置上呈现真实的
/// 窗口控制器与面板，截取**屏幕区域**合成后的图像——这是唯一看得到 Liquid Glass 材质的方式。
/// `cacheDisplay` 把材质画成全透明，`ImageRenderer` 根本画不出，单窗口截图又不含玻璃对背后
/// 内容的采样（见 docs/macos-notes.md）。
///
/// 两组画面：
/// - 表面：两种面板样式 × 两种外观 × 玻璃开关，各取形变中间两帧与稳定帧；
/// - 内容：接壤 + 玻璃下逐个插件的样子（应用 / 自定义 / 时钟 / 进程 / 订阅额度三种样式），
///   订阅额度用测试替身喂样例账号，不触网。
///
/// **需要运行测试的进程拥有「屏幕录制」权限**（例如从已授权的终端运行）；没有权限时先用一块
/// 小窗口探明并立刻失败，不会把面板在屏幕上摆很久，也不会静默产出黑图。
/// 面板后面垫一块测试自带的渐变窗口，既压测玻璃上的文字可读性，也不把屏幕上的其他内容截进来。
@MainActor
final class PanelLiveCaptureTests: XCTestCase {
    func testCaptureLivePanelWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_LIVE_CAPTURE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let backdrop = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        backdrop.isOpaque = false
        backdrop.backgroundColor = .clear
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        defer { backdrop.orderOut(nil) }

        // 先用一块不透明的小窗口确认能不能截到内容。
        showBackdrop(backdrop, content: Color.red, frame: NSRect(x: 400, y: 400, width: 40, height: 40))
        settle(0.3)
        guard let probe = captureRegion(backdrop.frame), hasContent(probe) else {
            XCTFail("截图内容为空：运行测试的进程没有「屏幕录制」权限，无法取得屏幕合成后的图像")
            return
        }

        // 直接注册随附插件的模块（不走市场自动添加），订阅额度接测试替身。
        let suite = "com.notchdeck.panel.live.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let quotas = QuotaTestClient()
        let quotaSecrets = QuotaTestSecrets()
        let quota = SubscriptionQuotaModule(settings: settings, clients: quotas.clients, secrets: quotaSecrets,
                                            notifications: QuotaTestNotifications())
        let app = AppModel(settings: settings, modules: [
            ModuleBox(MediaModule(settings: settings)), ModuleBox(VolumeModule()),
            ModuleBox(AppLauncherModule(settings: settings)), ModuleBox(SystemMonitor(settings: settings)),
            ModuleBox(NodeProcessScanner(settings: settings)), ModuleBox(CustomItemsModule(settings: settings)),
            ModuleBox(ClockModule(settings: settings)), ModuleBox(quota),
        ], plugins: [], catalogFetch: { _ in
            XCTFail("实机截图不应发起目录请求")
            return AnyCancellable {}
        })
        let controller = NotchWindowController.shared
        controller.configure(with: app)
        defer {
            controller.collapse()
            settle(0.8)
            app.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }

        // MARK: 表面：两种样式 × 两种外观 × 玻璃开关
        // 悬浮卡片跟随"系统"外观，这里用进程外观代替系统外观；接壤卡片由控制器强制深色。
        let surfaces: [(name: String, attached: Bool, dark: Bool, glass: Bool)] = [
            ("attached-solid-light", true, false, false), ("attached-glass-light", true, false, true),
            ("attached-solid-dark", true, true, false), ("attached-glass-dark", true, true, true),
            ("floating-solid-light", false, false, false), ("floating-glass-light", false, false, true),
            ("floating-solid-dark", false, true, false), ("floating-glass-dark", false, true, true),
        ]
        // 形变约 0.34s 首次到位：取两帧中间轮廓与一帧稳定画面。
        let beats: [(label: String, delay: TimeInterval)] = [("0-120ms", 0.09), ("1-250ms", 0.13), ("2-settled", 1.2)]
        for surface in surfaces {
            controller.collapse()
            settle(0.8)
            NSApplication.shared.appearance = NSAppearance(named: surface.dark ? .darkAqua : .aqua)
            settings.notchAttached = surface.attached
            settings.liquidGlass = surface.glass
            controller.expand()
            settle(0.03)
            let frame = controller.panelFrame
            // 接壤面板贴着屏幕顶缘：不成立就说明样式没切过去，后面的截图名不副实。
            if surface.attached, let screen = PanelMetrics.targetScreen {
                XCTAssertEqual(frame.maxY, screen.frame.maxY, "接壤样式没有生效")
            }
            showBackdrop(backdrop, content: desktop(dark: surface.dark),
                         frame: frame.insetBy(dx: -160, dy: -160))
            for beat in beats {
                settle(beat.delay)
                let settled = beat.label == "2-settled"
                try savePanel(frame: frame, to: "\(directory)/live-surface-\(surface.name)-\(beat.label).png",
                              requiresCardBelow: settled ? frame.height / 2 : nil)
            }
        }

        // MARK: 内容：接壤 + 玻璃下逐个插件
        controller.collapse()
        settle(0.8)
        settings.notchAttached = true
        settings.liquidGlass = true
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        // 样例内容：应用与自定义子项为空时插件不显示，所以先喂一些。
        settings.panelApps = [
            PanelApp(bundleID: "com.apple.finder", name: "Finder", path: "/System/Library/CoreServices/Finder.app"),
            PanelApp(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
            PanelApp(bundleID: "com.apple.Terminal", name: "终端", path: "/System/Applications/Utilities/Terminal.app"),
            PanelApp(bundleID: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app"),
        ]
        settings.customItems = CustomItemPresets.all
            .filter { [.system, .network, .development].contains($0.category) }
            .prefix(7).map(\.item)
        settings.updateConfig(for: "clock") { $0.enabled = true }
        settings.updateConfig(for: "subscriptions") { $0.enabled = true }
        let glm = [SubscriptionAccount(provider: .glm, alias: "工作"), SubscriptionAccount(provider: .glm, alias: "个人")]
        let codex = [SubscriptionAccount(provider: .codex, alias: "主账号")]
        let minimax = [SubscriptionAccount(provider: .minimaxCN, alias: "个人")]
        quotaSecrets.keys = [glm[0].id: "test-first-key", glm[1].id: "test-second-key"]
        quotaSecrets.minimaxKeys = [minimax[0].id: "test-only-not-a-real-key"]
        quota.preferences.update { $0.accounts = glm + codex + minimax; $0.codexExecutable = "/usr/bin/true" }

        controller.expand()
        settle(0.3)
        showBackdrop(backdrop, content: desktop(dark: false),
                     frame: controller.panelFrame.insetBy(dx: -160, dy: -160))
        // 系统监控要两个采样周期才有差分读数；进程扫描与自定义命令各自异步出结果。
        settle(2.8)

        func snapshot(_ scene: String) throws {
            try savePanel(frame: controller.panelFrame, to: "\(directory)/live-content-\(scene).png",
                          requiresCardBelow: controller.panelFrame.height / 2)
        }
        try snapshot("default-system")
        app.activeTabID = "node"
        settle(1.6)
        try snapshot("node")
        app.activeTabID = "apps"
        settle(0.7)
        try snapshot("apps")
        app.activeTabID = "custom"
        settle(1.2)
        try snapshot("custom")
        app.activeTabID = "clock"
        settle(0.7)
        try snapshot("clock")

        // 订阅额度：查询有并发上限，应答一轮后才会发出下一批，所以反复应答到没有新请求。
        app.activeTabID = "subscriptions"
        // 账号卡片依次入场：切到这一页后的头三帧。
        settle(0.03)
        try snapshot("quota-entrance-0")
        settle(0.07)
        try snapshot("quota-entrance-1")
        settle(0.08)
        try snapshot("quota-entrance-2")
        for (mode, name) in [("cards", "cards"), ("rings", "rings"), ("compact", "compact")] {
            settings.updateConfig(for: "subscriptions") { $0.displayModeID = mode }
            for _ in 0..<4 {
                answerPendingQuotas(quotas)
                settle(0.35)
            }
            try snapshot("quota-\(name)")
        }

        // 读数变化：回到长条样式，触发一次刷新并用不同的读数应答，在过渡中途截两帧——
        // 长条扫向新值、数字逐位滚动、刷新图标转一圈，都在这两帧里。
        settings.updateConfig(for: "subscriptions") { $0.displayModeID = "cards" }
        settle(0.5)
        nextReading = (47, 71)
        quota.refresh()
        settle(0.05)
        answerPendingQuotas(quotas)
        settle(0.09)
        try snapshot("quota-rolling-0")
        settle(0.1)
        try snapshot("quota-rolling-1")
    }

    // MARK: - 工具

    /// 用样例快照应答所有还没应答的订阅额度查询。
    private func answerPendingQuotas(_ quotas: QuotaTestClient) {
        for index in answeredGLM..<quotas.glm.count {
            quotas.glm[index].completion(.success(quotaFixture(for: .glm)))
        }
        answeredGLM = quotas.glm.count
        for index in answeredCodex..<quotas.codex.count {
            quotas.codex[index].completion(CodexQuotaResult(quota: .success(quotaFixture(for: .codex))))
        }
        answeredCodex = quotas.codex.count
        for index in answeredMiniMax..<quotas.minimax.count {
            quotas.minimax[index].completion(.success(quotaFixture(for: .minimaxCN)))
        }
        answeredMiniMax = quotas.minimax.count
    }

    private var answeredGLM = 0
    private var answeredCodex = 0
    private var answeredMiniMax = 0
    /// 设定后，之后应答的读数改用这一组（5 小时 / 每周），用来拍"读数变化"的过渡。
    private var nextReading: (Double, Double)?

    private func quotaFixture(for provider: SubscriptionProvider) -> SubscriptionQuotaSnapshot {
        guard let nextReading else { return .fixture(for: provider) }
        let now = Date()
        return SubscriptionQuotaSnapshot(plan: "Pro · 示例", windows: [
            .init(id: "short", title: "5 小时", usedPercent: nextReading.0,
                  resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
            .init(id: "weekly", title: "每周", usedPercent: nextReading.1,
                  resetsAt: now.addingTimeInterval(3 * 86400 + 3600)),
        ], fetchedAt: now)
    }

    /// 垫在面板后面的"桌面"。sizingOptions 置空：窗口尺寸由这里的 frame 决定，
    /// 不让 SwiftUI 的理想尺寸反向撑大窗口。
    private func showBackdrop(_ window: NSWindow, content: some View, frame: CGRect) {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        let bounded = PanelMetrics.targetScreen.map { frame.intersection($0.frame) } ?? frame
        window.setFrame(bounded, display: true)
        window.orderFront(nil)
    }

    /// 截取面板所在的那一块屏幕区域（窗口服务器合成后的样子，含玻璃对背后内容的采样）。
    /// `requiresCardBelow` 给出卡片中部某一点的 y：稳定帧必须在那里截到内容。
    private func savePanel(frame: CGRect, to path: String, requiresCardBelow: CGFloat?) throws {
        let image = try XCTUnwrap(captureRegion(screenRegion(frame)), "无法截取面板区域 \(path)")
        if let requiresCardBelow {
            let rep = NSBitmapImageRep(cgImage: image)
            let x = rep.pixelsWide / 2
            let y = Int(Double(rep.pixelsHigh) * requiresCardBelow / max(frame.height, 1))
            // 宁可失败，也不产出看起来像"面板没画出来"的截图。
            guard (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.99 else {
                XCTFail("截图内容为空：\(path)")
                return
            }
        }
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }

    /// AppKit 坐标（原点在主屏左下）换到截屏坐标（原点在主屏左上）。
    private func screenRegion(_ frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// 屏幕区域截图会包含这块区域里所有窗口：垫底窗口是不透明的，完全盖住了面板所在的区域，
    /// 所以截到的只有"测试背景 + 面板"。接口自 macOS 14 起标记为弃用（替代者 ScreenCaptureKit
    /// 同样需要授权），这里就地压掉弃用告警。
    @available(macOS, deprecated: 14.0)
    private func captureRegion(_ region: CGRect) -> CGImage? {
        CGWindowListCreateImage(region, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    private func hasContent(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        return (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.99
    }

    private func settle(_ seconds: TimeInterval) {
        let done = expectation(description: "等待 \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 3)
    }

    /// 测试自带的"桌面"：亮暗两套带纵横变化的渐变，玻璃透出来的明暗与文字是否可读一眼可见。
    private func desktop(dark: Bool) -> some View {
        LinearGradient(colors: dark
                       ? [Color(red: 0.32, green: 0.10, blue: 0.45), Color(red: 0.05, green: 0.35, blue: 0.55),
                          Color(red: 0.95, green: 0.55, blue: 0.15)]
                       : [Color(red: 1.00, green: 0.82, blue: 0.55), Color(red: 0.55, green: 0.85, blue: 0.95),
                          Color(red: 0.98, green: 0.45, blue: 0.55)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
