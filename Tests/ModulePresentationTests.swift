import SwiftUI
import XCTest

final class ModulePresentationTests: XCTestCase {
    func testLegacyPinnedConfigurationMigratesAndNewFieldsRoundTrip() throws {
        let decoder = JSONDecoder()
        for (pinned, placement) in [(true, ModulePlacement.top), (false, .tab)] {
            let old = Data("{\"enabled\":false,\"pinned\":\(pinned)}".utf8)
            let config = try decoder.decode(ModuleConfig.self, from: old)
            XCTAssertFalse(config.enabled)
            XCTAssertEqual(config.placement, placement)
            XCTAssertNil(config.displayModeID)
        }
        let config = ModuleConfig(enabled: true, placement: .bottom, displayModeID: "compact")
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try decoder.decode(ModuleConfig.self, from: data), config)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(legacy["pinned"] as? Bool, true)
    }

    func testFuturePlacementAndStyleDoNotInvalidateOtherSavedModules() throws {
        let data = Data(#"{"known":{"enabled":true,"pinned":false},"future":{"enabled":false,"pinned":true,"placement":"future-area","displayModeID":"future-mode"}}"#.utf8)
        let configs = try JSONDecoder().decode([String: ModuleConfig].self, from: data)
        XCTAssertEqual(configs["known"]?.placement, .tab)
        XCTAssertEqual(configs["future"]?.placement, .top)
        XCTAssertEqual(configs["future"]?.displayModeID, "future-mode")
        XCTAssertEqual(configs["future"]?.enabled, false)
    }

    func testPluginDefaultsUserOverridesAndUnsupportedOptionsResolveWithoutRewritingPreferences() {
        var descriptor = PresentationFixture.descriptor
        descriptor.defaultConfig = ModuleConfig(enabled: false, placement: .bottom, displayModeID: "compact")
        XCTAssertEqual(descriptor.presentationContext(for: descriptor.defaultConfig),
                       ModulePresentationContext(placement: .bottom, displayModeID: "compact"))
        let saved = ModuleConfig(enabled: true, placement: .top, displayModeID: "standard")
        XCTAssertEqual(descriptor.presentationContext(for: saved),
                       ModulePresentationContext(placement: .top, displayModeID: "standard"))
        descriptor.presentation.placements = [.tab]
        let future = ModuleConfig(enabled: true, placement: .bottom, displayModeID: "future-mode")
        XCTAssertEqual(descriptor.presentationContext(for: future),
                       ModulePresentationContext(placement: .tab, displayModeID: "compact"))
        XCTAssertEqual(future.displayModeID, "future-mode")
        descriptor.presentation.displayModes = [.standard]
        XCTAssertEqual(descriptor.presentationContext(for: future).displayModeID, "standard")
    }

    func testInvalidPresentationDeclarationsAreRejectedBeforeStarting() {
        let registry = ModuleRegistry()
        let module = InvalidPresentationFixture()
        XCTAssertFalse(registry.register(module))
        XCTAssertTrue(module.events.isEmpty)
        let invalid = [
            ModulePresentationOptions(placements: []),
            ModulePresentationOptions(placements: [.tab, .tab]),
            ModulePresentationOptions(displayModes: []),
            ModulePresentationOptions(displayModes: [.standard, .standard]),
            ModulePresentationOptions(displayModes: [ModuleDisplayMode(id: "Bad ID", title: "无效")]),
            ModulePresentationOptions(displayModes: [ModuleDisplayMode(id: "valid", title: " ")]),
        ]
        XCTAssertTrue(invalid.allSatisfy { !$0.isValid })
        XCTAssertTrue(PresentationFixture.descriptor.presentation.isValid)
    }

    @MainActor
    func testThreeRegionsKeepIndependentOrderAndOnlyTabsParticipateInSelection() {
        withSettings { settings in
            let tab = PresentationFixture()
            let top = TopPresentationFixture()
            let bottom = BottomPresentationFixture()
            let app = AppModel(settings: settings, modules: [ModuleBox(tab), ModuleBox(top), ModuleBox(bottom)])
            defer { app.shutdown() }
            settings.moduleOrder = [bottom.id, tab.id, top.id]
            settleMainQueue()
            XCTAssertEqual(app.orderedBoxes.map(\.id), [bottom.id, tab.id, top.id])
            XCTAssertEqual(app.pinnedModules.map(\.id), [top.id])
            XCTAssertEqual(app.tabModules.map(\.id), [tab.id])
            XCTAssertEqual(app.bottomModules.map(\.id), [bottom.id])
            XCTAssertEqual(app.activeTabID, tab.id)
            settings.updateConfig(for: tab.id) { $0.placement = .bottom }
            settleMainQueue()
            XCTAssertTrue(app.tabModules.isEmpty)
            XCTAssertNil(app.activeTabID)
            XCTAssertEqual(app.bottomModules.map(\.id), [bottom.id, tab.id])
        }
    }

    @MainActor
    func testMovingAndChangingStyleDoesNotRestartAnActiveCollector() {
        withSettings { settings in
            let module = PresentationFixture()
            let box = ModuleBox(module)
            let app = AppModel(settings: settings, modules: [box])
            defer { app.shutdown() }
            app.isExpanded = true
            settings.updateConfig(for: module.id) { $0.placement = .bottom; $0.displayModeID = "compact" }
            settleMainQueue()
            XCTAssertEqual(app.presentationContext(for: box), ModulePresentationContext(placement: .bottom, displayModeID: "compact"))
            XCTAssertEqual(module.events, ["start", "expand"])
            XCTAssertTrue(box.isActive)
            settings.updateConfig(for: module.id) { $0.placement = .tab }
            settleMainQueue()
            XCTAssertEqual(app.activeTabID, module.id)
            app.isExpanded = false
            XCTAssertEqual(module.events, ["start", "expand", "collapse"])
        }
    }

    @MainActor
    func testPluginPlacementAndStyleSurviveRemovalReinstallationAndRestart() throws {
        let suite = "com.notchdeck.presentation.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let app = AppModel(settings: settings, modules: [], plugins: MarketplacePlugins.implementations,
                           catalog: try PluginCatalog.bundled(), appVersion: "99.0.0")
        defer { app.shutdown() }
        XCTAssertTrue(app.marketplace.install("subscriptions"))
        settings.updateConfig(for: "subscriptions") { $0.placement = .bottom; $0.displayModeID = "compact" }
        settleMainQueue()
        XCTAssertEqual(app.bottomModules.map(\.id), ["subscriptions"])
        XCTAssertTrue(app.marketplace.remove("subscriptions"))
        XCTAssertTrue(app.marketplace.install("subscriptions"))
        settleMainQueue()
        let box = try XCTUnwrap(app.registry.boxes.first)
        XCTAssertEqual(app.presentationContext(for: box), ModulePresentationContext(placement: .bottom, displayModeID: "compact"))
        app.shutdown()
        let restored = AppModel(settings: SettingsStore(defaults: defaults), modules: [],
                                plugins: MarketplacePlugins.implementations,
                                catalog: try PluginCatalog.bundled(), appVersion: "99.0.0")
        defer { restored.shutdown() }
        XCTAssertEqual(restored.bottomModules.map(\.id), ["subscriptions"])
        XCTAssertEqual(restored.presentationContext(for: try XCTUnwrap(restored.registry.boxes.first)),
                       ModulePresentationContext(placement: .bottom, displayModeID: "compact"))
    }

    @MainActor
    func testUnsupportedSavedRegionUsesPluginDefaultForLayout() {
        withSettings { settings in
            let module = TabOnlyPresentationFixture()
            settings.updateConfig(for: module.id) { $0.placement = .bottom; $0.displayModeID = "unknown" }
            let app = AppModel(settings: settings, modules: [ModuleBox(module)])
            defer { app.shutdown() }
            XCTAssertEqual(app.tabModules.map(\.id), [module.id])
            XCTAssertTrue(app.bottomModules.isEmpty)
            XCTAssertEqual(settings.config(for: module.id).placement, .bottom)
        }
    }

    func testReorderingWithinOneRegionPreservesOtherRegionsAndIgnoresBoundary() {
        withSettings { settings in
            let ids = ["top-a", "tab-a", "top-b", "bottom-a", "tab-b"]
            settings.moduleOrder = ids
            settings.moveModule("top-a", offset: 1, registryIDs: ids, within: ["top-a", "top-b"])
            XCTAssertEqual(settings.moduleOrder, ["top-b", "tab-a", "top-a", "bottom-a", "tab-b"])
            let before = settings.moduleOrder
            settings.moveModule("top-a", offset: 1, registryIDs: ids, within: ["top-a", "top-b"])
            XCTAssertEqual(settings.moduleOrder, before)
            settings.moveModule("tab-b", offset: -1, registryIDs: ids, within: ["tab-a", "tab-b"])
            XCTAssertEqual(settings.moduleOrder, ["top-b", "tab-b", "top-a", "bottom-a", "tab-a"])
        }
    }

    private func withSettings(_ body: (SettingsStore) throws -> Void) rethrows {
        let suite = "com.notchdeck.presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SettingsStore(defaults: defaults))
    }

    @MainActor private func settleMainQueue() {
        let settled = expectation(description: "布局选择更新")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }
}

private class PresentationFixture: ObservableObject, NotchModule {
    class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "presentation", title: "布局组件", systemImage: "circle", summary: "测试",
            presentation: ModulePresentationOptions(displayModes: [.standard, ModuleDisplayMode(id: "compact", title: "紧凑")]))
    }
    var events: [String] = []
    func start() { events.append("start") }
    func stop() { events.append("stop") }
    func panelDidExpand() { events.append("expand") }
    func panelDidCollapse() { events.append("collapse") }
    func content() -> some View { Text("示例") }
}

private final class TopPresentationFixture: PresentationFixture {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "top", title: "顶部", systemImage: "circle", summary: "测试",
                         defaultConfig: ModuleConfig(enabled: true, placement: .top))
    }
}
private final class BottomPresentationFixture: PresentationFixture {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "bottom", title: "底部", systemImage: "circle", summary: "测试",
                         defaultConfig: ModuleConfig(enabled: true, placement: .bottom))
    }
}
private final class TabOnlyPresentationFixture: PresentationFixture {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "tab-only", title: "仅标签页", systemImage: "circle", summary: "测试",
                         presentation: ModulePresentationOptions(placements: [.tab]))
    }
}
private final class InvalidPresentationFixture: PresentationFixture {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "invalid-options", title: "无效", systemImage: "circle", summary: "测试",
                         presentation: ModulePresentationOptions(displayModes: []))
    }
}
