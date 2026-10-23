import Combine
import SwiftUI
import XCTest

final class ModuleFrameworkTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: SettingsStore!

    override func setUp() {
        suite = "com.notchdeck.components.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        settings = nil
        defaults = nil
    }

    func testComponentDefaultsApplyWithoutCentralRegistrationAndSavedConfigWins() {
        let registry = ModuleRegistry()
        let disabled = DisabledComponent()
        let pinned = PinnedComponent()
        registry.register(disabled)
        registry.register(pinned)
        registry.updateActivity(settings: settings)
        XCTAssertTrue(disabled.events.isEmpty)
        XCTAssertEqual(pinned.events, ["start"])
        XCTAssertTrue(settings.config(for: pinned.id, default: PinnedComponent.descriptor.defaultConfig).pinned)
        settings.updateConfig(for: pinned.id, default: PinnedComponent.descriptor.defaultConfig) { $0.enabled = false }
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.config(for: pinned.id, default: PinnedComponent.descriptor.defaultConfig),
                       ModuleConfig(enabled: false, pinned: true))
        registry.updateActivity(settings: restored)
        XCTAssertEqual(pinned.events, ["start", "stop"])
    }

    func testDuplicateAndInvalidIDsAreRejectedBeforeStarting() {
        let registry = ModuleRegistry()
        let first = FixtureComponent()
        let duplicate = FixtureComponent()
        XCTAssertTrue(registry.register(first))
        XCTAssertFalse(registry.register(duplicate))
        XCTAssertFalse(registry.register(InvalidComponent()))
        registry.updateActivity(settings: settings)
        XCTAssertEqual(registry.boxes.count, 1)
        XCTAssertEqual(first.events, ["start"])
        XCTAssertTrue(duplicate.events.isEmpty)
    }

    func testPanelEventsReachOnlyActiveComponentsAndAreIdempotent() {
        let registry = ModuleRegistry()
        let module = FixtureComponent()
        let disabled = DisabledComponent()
        registry.register(module)
        registry.register(disabled)
        registry.setPanelExpanded(true)
        XCTAssertTrue(module.events.isEmpty)
        registry.updateActivity(settings: settings)
        registry.setPanelExpanded(true)
        registry.updateActivity(settings: settings)
        registry.setPanelExpanded(false)
        registry.setPanelExpanded(false)
        XCTAssertEqual(module.events, ["start", "expand", "collapse"])
        XCTAssertTrue(disabled.events.isEmpty)
    }

    func testEnableWhilePanelOpenGetsExpansionAndDisableClosesBeforeStop() {
        let registry = ModuleRegistry()
        let module = DisabledComponent()
        registry.register(module)
        registry.setPanelExpanded(true)
        registry.updateActivity(settings: settings)
        settings.updateConfig(for: module.id) { $0.enabled = true }
        registry.updateActivity(settings: settings)
        settings.updateConfig(for: module.id) { $0.enabled = false }
        registry.updateActivity(settings: settings)
        registry.updateActivity(settings: settings)
        XCTAssertEqual(module.events, ["start", "expand", "collapse", "stop"])
    }

    func testUnavailableComponentRetainsSettingsAndReason() throws {
        let registry = ModuleRegistry()
        let module = FixtureComponent()
        module.isAvailable = false
        registry.register(module)
        registry.updateActivity(settings: settings)
        let box = try XCTUnwrap(registry.boxes.first)
        XCTAssertNotNil(box.makeSettings)
        XCTAssertEqual(box.unavailableReason(), "待配置")
        XCTAssertTrue(module.events.isEmpty)
    }

    func testUnregisterStopsAndDisconnectsPublisherButPreservesUserConfiguration() {
        let registry = ModuleRegistry()
        let module = FixtureComponent()
        registry.register(module)
        settings.updateConfig(for: module.id) { $0.pinned = true }
        registry.updateActivity(settings: settings)
        registry.setPanelExpanded(true)
        var notifications = 0
        let subscription = registry.objectWillChange.sink { notifications += 1 }
        XCTAssertTrue(registry.unregister(module.id))
        let countAfterRemoval = notifications
        module.isAvailable = false
        XCTAssertEqual(notifications, countAfterRemoval)
        XCTAssertEqual(module.events, ["start", "expand", "collapse", "stop"])
        XCTAssertTrue(registry.boxes.isEmpty)
        XCTAssertFalse(registry.unregister(module.id))
        XCTAssertTrue(SettingsStore(defaults: defaults).config(for: module.id).pinned)
        withExtendedLifetime(subscription) {}
    }

    func testRegistryReleaseAndRepeatedShutdownStopExactlyOnce() {
        let module = FixtureComponent()
        var registry: ModuleRegistry? = ModuleRegistry()
        registry?.register(module)
        registry?.updateActivity(settings: settings)
        registry?.stopAll()
        registry?.stopAll()
        registry = nil
        XCTAssertEqual(module.events, ["start", "stop"])
        let other = FixtureComponent()
        registry = ModuleRegistry()
        registry?.register(other)
        registry?.updateActivity(settings: settings)
        registry = nil
        XCTAssertEqual(other.events, ["start", "stop"])
    }

    func testBuiltInCatalogHasNoStartupEffectsAndPreservesLegacyDefaults() {
        let boxes = BuiltInModules.make(settings: settings)
        XCTAssertEqual(boxes.map(\.id), ["media", "volume", "apps", "system", "node", "custom", "clock"])
        XCTAssertTrue(boxes.allSatisfy { !$0.isActive })
        XCTAssertEqual(boxes.filter { $0.descriptor.defaultConfig.pinned }.map(\.id), ["media", "volume"])
        XCTAssertEqual(boxes.filter { !$0.descriptor.defaultConfig.enabled }.map(\.id), ["clock"])
        XCTAssertEqual(boxes.filter { $0.makeSettings != nil }.map(\.id), ["media", "apps", "system", "node", "custom", "clock"])
        XCTAssertTrue(settings.mediaSources.isEmpty)
    }

    func testSettingsNavigationDiscoversComponentPagesByIDOrTitle() {
        let box = ModuleBox(FixtureComponent())
        XCTAssertEqual(SettingsPage.resolve(box.id, boxes: [box]), .module(box.id))
        XCTAssertEqual(SettingsPage.resolve(box.title, boxes: [box]), .module(box.id))
        let volume = ModuleBox(VolumeModule())
        XCTAssertEqual(SettingsPage.resolve(volume.id, boxes: [volume]), .modules)
        XCTAssertEqual(SettingsPage.resolve("removed", boxes: [box]), .modules)
        XCTAssertEqual(SettingsPage.resolve("通用", boxes: [box]), .general)
    }

    @MainActor
    func testInjectedAppUpdatesAvailabilitySelectionAndLateRegistration() {
        let first = FixtureComponent()
        let second = DisabledComponent()
        settings.updateConfig(for: second.id) { $0.enabled = true }
        let app = AppModel(settings: settings, modules: [ModuleBox(first), ModuleBox(second)])
        defer { app.shutdown() }
        XCTAssertEqual(app.activeTabID, first.id)
        app.isExpanded = true
        first.isAvailable = false
        settleMainQueue()
        XCTAssertEqual(app.activeTabID, second.id)
        XCTAssertEqual(first.events, ["start", "expand", "collapse", "stop"])
        XCTAssertTrue(app.registry.unregister(second.id))
        settleMainQueue()
        XCTAssertNil(app.activeTabID)
        let late = PinnedComponent()
        app.registry.register(late)
        settleMainQueue()
        XCTAssertEqual(app.pinnedModules.map(\.id), [late.id])
        XCTAssertEqual(late.events, ["start", "expand"])
    }

    @MainActor
    func testShutdownDiscardsQueuedSettingsChangesAndDoesNotRestartComponents() {
        let module = FixtureComponent()
        let app = AppModel(settings: settings, modules: [ModuleBox(module)])
        settings.updateConfig(for: module.id) { $0.enabled = false }
        app.shutdown()
        settings.updateConfig(for: module.id) { $0.enabled = true }
        settleMainQueue()
        XCTAssertEqual(module.events, ["start", "stop"])
    }

    func testComponentPreferencesAreIsolatedAndSurviveRestart() {
        let first = settings.modulePreferences(for: "first", default: ClockPreferences())
        let second = settings.modulePreferences(for: "second", default: ClockPreferences())
        first.binding(for: \.showSeconds).wrappedValue = false
        XCTAssertFalse(first.value.showSeconds)
        XCTAssertTrue(first.value.showTimeZone)
        XCTAssertTrue(second.value.showSeconds)
        let restored = SettingsStore(defaults: defaults).modulePreferences(for: "first", default: ClockPreferences())
        XCTAssertEqual(restored.value, first.value)
        XCTAssertNil(first.saveError)
    }

    func testMissingOrCorruptComponentPreferencesFallBackWithoutWriting() {
        let key = "modules.preferences.clock"
        let initial = settings.modulePreferences(for: "clock", default: ClockPreferences())
        XCTAssertEqual(initial.value, ClockPreferences())
        XCTAssertNil(defaults.object(forKey: key))
        defaults.set(Data("invalid".utf8), forKey: key)
        let restored = settings.modulePreferences(for: "clock", default: ClockPreferences())
        XCTAssertEqual(restored.value, ClockPreferences())
    }

    func testInvalidPreferenceUpdateKeepsPreviousValueAndSavedData() {
        let preferences = settings.modulePreferences(for: "number", default: 1.0)
        XCTAssertTrue(preferences.update { $0 = 2.0 })
        XCTAssertFalse(preferences.update { $0 = .infinity })
        XCTAssertEqual(preferences.value, 2.0)
        XCTAssertNotNil(preferences.saveError)
        let restored = settings.modulePreferences(for: "number", default: 1.0)
        XCTAssertEqual(restored.value, 2.0)
        XCTAssertTrue(preferences.update { $0 = 2.0 })
        XCTAssertNil(preferences.saveError)
    }

    @MainActor
    private func settleMainQueue() {
        let settled = expectation(description: "组件配置与可用性更新")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }
}

private class FixtureComponent: ObservableObject, NotchModule {
    class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "fixture", title: "示例组件", systemImage: "circle", summary: "扩展测试")
    }
    @Published var isAvailable = true
    var unavailableReason: String? { isAvailable ? nil : "待配置" }
    var events: [String] = []
    func start() { events.append("start") }
    func stop() { events.append("stop") }
    func panelDidExpand() { events.append("expand") }
    func panelDidCollapse() { events.append("collapse") }
    func content() -> some View { Text("内容") }
    func settingsContent() -> some View { Text("设置") }
}

private final class DisabledComponent: FixtureComponent {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "disabled", title: "可选组件", systemImage: "circle", summary: "默认关闭",
                         defaultConfig: ModuleConfig(enabled: false, pinned: false))
    }
}

private final class PinnedComponent: FixtureComponent {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: "pinned", title: "常驻组件", systemImage: "circle", summary: "默认常驻",
                         defaultConfig: ModuleConfig(enabled: true, pinned: true))
    }
}

private final class InvalidComponent: FixtureComponent {
    override class var descriptor: ModuleDescriptor {
        ModuleDescriptor(id: " ", title: "无效组件", systemImage: "circle", summary: "无效 ID")
    }
}
