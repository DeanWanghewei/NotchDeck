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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.title = "NotchDeck 设置"
            window.isReleasedWhenClosed = false
            window.level = .floating
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
