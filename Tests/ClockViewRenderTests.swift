import AppKit
import Combine
import SwiftUI
import XCTest

/// 时钟与插件市场自渲染：时间 / 日期格式改动必须目检深浅两版。
/// 渲染仅在设置 `NOTCHDECK_RENDER_DIR` 时执行；xcodebuild 用 `TEST_RUNNER_` 前缀传入。
@MainActor
final class ClockViewRenderTests: XCTestCase {
    func testRenderClockViewWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "com.notchdeck.clock.render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let module = ClockModule(settings: settings)
        module.start()
        defer { module.stop() }
        try render(ClockView(module: module, preferences: module.preferences),
                   name: "clock", size: NSSize(width: 320, height: 150), directory: directory)
        module.preferences.update { $0.showSeconds = false }
        try render(ClockView(module: module, preferences: module.preferences),
                   name: "clock-minutes", size: NSSize(width: 320, height: 150), directory: directory)
    }

    func testRenderMarketplaceTimeWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "com.notchdeck.marketplace.time.render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let catalog = try PluginCatalog.bundled()
        struct CachedCatalog: Encodable {
            let catalog: PluginCatalog
            let fetchedAt: Date
        }
        // 用临时目录缓存展示更新时间，截图不依赖网络或用户已有配置。
        settings.cachedPluginCatalog = try JSONEncoder().encode(CachedCatalog(catalog: catalog, fetchedAt: Date()))
        let marketplace = PluginMarketplace(settings: settings, registry: ModuleRegistry(), implementations: [],
                                            bundledCatalog: catalog, fetch: { _ in
            XCTFail("自渲染不应发起目录请求")
            return AnyCancellable {}
        })
        try render(PluginMarketplaceView(marketplace: marketplace, settings: settings, openSettings: { _ in }),
                   name: "marketplace-time", size: NSSize(width: 560, height: 760), directory: directory)
    }

    func testRenderMarketplaceFlowsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "com.notchdeck.marketplace.flows.render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let catalog = try PluginCatalog.bundled()
        struct CachedCatalog: Encodable {
            let catalog: PluginCatalog
            let fetchedAt: Date
        }
        settings.cachedPluginCatalog = try JSONEncoder().encode(CachedCatalog(catalog: catalog, fetchedAt: Date()))
        let definition = PluginImplementation(descriptor: MarketplaceRenderModule.descriptor,
                                              version: catalog.plugins[0].version,
                                              makeModule: { _ in ModuleBox(MarketplaceRenderModule()) })
        let app = AppModel(settings: settings, modules: [], plugins: [definition], catalog: catalog,
                           appVersion: "0.23.0", catalogFetch: { _ in
            XCTFail("自渲染不应发起目录请求"); return AnyCancellable {}
        })
        defer { app.shutdown() }
        for size in [NSSize(width: 980, height: 700), NSSize(width: 820, height: 560)] {
            try render(SettingsView(app: app, page: .marketplace), name: "settings-market-\(Int(size.width))",
                       size: size, directory: directory, padding: 0)
        }
        XCTAssertTrue(app.marketplace.install("subscriptions"))
        try render(PluginMarketplaceView(marketplace: app.marketplace, settings: settings,
                                        selectedID: "subscriptions", openSettings: { _ in }),
                   name: "market-detail-current", size: NSSize(width: 760, height: 1050), directory: directory)

        // 模拟正式版 0.22 遇到更高的目录版本：旧插件仍能设置、移除与重新添加。
        var old = catalog
        old.plugins[0].version = "1.2.0"
        old.plugins[0].minimumAppVersion = "0.22.0"
        let oldDefinition = PluginImplementation(descriptor: MarketplaceRenderModule.descriptor, version: "1.2.0",
                                                 makeModule: { _ in ModuleBox(MarketplaceRenderModule()) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("market-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginScriptStore(root: root)
        let source = Data("var adapter = {};".utf8)
        try store.install(pluginID: "subscriptions", data: source,
                          manifest: .init(version: "0.5.0", sha256: PluginScriptStore.sha256Hex(source), downloadedAt: Date()))
        let market = PluginMarketplace(settings: settings, registry: ModuleRegistry(), implementations: [oldDefinition],
                                        bundledCatalog: old, appVersion: "0.22.0", fetch: { _ in
            XCTFail("自渲染不应发起目录请求"); return AnyCancellable {}
        }, scriptStore: store)
        defer { market.shutdown() }
        try render(PluginMarketplaceView(marketplace: market, settings: settings,
                                        selectedID: "subscriptions", openSettings: { _ in }),
                   name: "market-detail-update", size: NSSize(width: 640, height: 1100), directory: directory)
        XCTAssertTrue(market.remove("subscriptions"))
        try render(PluginMarketplaceView(marketplace: market, settings: settings,
                                        selectedID: "subscriptions", openSettings: { _ in }),
                   name: "market-detail-readd", size: NSSize(width: 640, height: 1050), directory: directory)
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

private final class MarketplaceRenderModule: ObservableObject, NotchModule {
    static let descriptor = ModuleDescriptor(id: "subscriptions", title: "订阅额度", systemImage: "chart.bar.xaxis",
                                            summary: "截图占位组件", defaultConfig: ModuleConfig(enabled: false, pinned: false))
    func start() {}
    func stop() {}
    func content() -> some View { Text("测试") }
    func settingsContent() -> some View { Text("测试设置") }
}
