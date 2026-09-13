import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel.shared

    private let windowController = NotchWindowController.shared
    private let mouseTracker = MouseTracker()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        windowController.configure(with: appModel)

        mouseTracker.onShouldExpand = { [weak self] in self?.windowController.expand() }
        mouseTracker.onShouldCollapse = { [weak self] in self?.windowController.collapse() }
        mouseTracker.start()

        HotKeyManager.shared.onTrigger = { [weak self] in self?.togglePanel() }
        HotKeyManager.shared.registerDefault()

        setupStatusItem()

        NotificationCenter.default.addObserver(self, selector: #selector(handleHotKeyChange),
                                               name: SettingsStore.hotKeyDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: AppModel.openSettingsRequest, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quitApp),
                                               name: AppModel.quitRequest, object: nil)

        // UI 调试/自动化验证用：-NotchDeckShowPanel 启动即展开面板，-NotchDeckShowSettings 同时打开设置，
        // -NotchDeckTab <id> 指定选中标签页
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-NotchDeckShowPanel") || arguments.contains("-NotchDeckShowSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController.expand()
            }
        }
        if let tabFlagIndex = arguments.firstIndex(of: "-NotchDeckTab"),
           arguments.indices.contains(tabFlagIndex + 1) {
            let tabID = arguments[tabFlagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AppModel.shared.activeTabID = tabID
            }
        }
        if arguments.contains("-NotchDeckShowSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                self?.showSettingsWindow()
            }
        }
        // 无需录屏权限的 UI 验证：把面板/设置窗口内容渲染成 PNG 落盘（两个时刻，供时序验证）
        if arguments.contains("-NotchDeckDumpUI") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                self?.dumpUIToDisk(suffix: "")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                self?.dumpUIToDisk(suffix: "2")
            }
        }
    }

    /// 渲染窗口内容到 /tmp/notchdeck-*.png（cacheDisplay 不需要屏幕录制权限）
    private func dumpUIToDisk(suffix: String) {
        dumpView(windowController.panelContentView, to: "/tmp/notchdeck-panel\(suffix).png")
        if let settingsContentView = settingsWindow?.contentView {
            dumpView(settingsContentView, to: "/tmp/notchdeck-settings\(suffix).png")
        }
    }

    private func dumpView(_ view: NSView?, to path: String) {
        guard let view else { return }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            NSLog("NotchDeck UI dump: \(path)")
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func togglePanel() {
        windowController.toggle()
    }

    @objc private func handleHotKeyChange() {
        HotKeyManager.shared.registerDefault()
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let icon = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                           accessibilityDescription: "NotchDeck")?
            .withSymbolConfiguration(configuration)
        icon?.isTemplate = true
        item.button?.image = icon ?? NSImage(named: NSImage.applicationIconName)
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            let menu = NSMenu()
            let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(.separator())
            let quitItem = menu.addItem(withTitle: "退出 NotchDeck", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem?.menu = nil
            }
        } else {
            togglePanel()
        }
    }

    // MARK: - 设置窗口

    @objc private func openSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "NotchDeck 设置"
            window.isReleasedWhenClosed = false
            window.level = .floating
            // 全屏应用所在 Space 也能呼出
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 560, height: 460)
            window.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
