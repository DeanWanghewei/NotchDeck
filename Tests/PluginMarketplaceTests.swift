import Combine
import SwiftUI
import XCTest

final class PluginMarketplaceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var catalog: PluginCatalog!

    override func setUpWithError() throws {
        suite = "com.notchdeck.marketplace.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
        catalog = try PluginCatalog.bundled()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        settings = nil
        defaults = nil
    }

    func testBundledDirectoryMatchesTrustedFactoriesWithoutConstructingPlugins() throws {
        XCTAssertEqual(catalog.plugins.map(\.id), ["subscriptions"])
        let definitions = MarketplacePlugins.implementations
        XCTAssertEqual(Set(definitions.map { $0.descriptor.id }).count, definitions.count)
        for implementation in definitions {
            let entry = try XCTUnwrap(catalog.plugins.first { $0.id == implementation.descriptor.id })
            XCTAssertEqual(entry.name, implementation.descriptor.title)
            XCTAssertEqual(entry.version, implementation.version)
            XCTAssertNotNil(PluginVersion(entry.minimumAppVersion))
        }
        XCTAssertEqual(SettingsPage.resolve("插件市场", boxes: []), .marketplace)
        XCTAssertEqual(SettingsPage.resolve("marketplace", boxes: []), .marketplace)
    }

    func testVersionsCompareNumericallyAndRejectUnboundedOrNonNumericInputs() {
        XCTAssertTrue(PluginVersion("1.10")! > PluginVersion("1.9.9")!)
        XCTAssertEqual(PluginVersion("1.0"), PluginVersion("1.0.0"))
        for value in ["", "1..0", "-1.0", "v1.0", "1.0-beta", "1.0.0.0", "9999999999999", "１.０"] {
            XCTAssertNil(PluginVersion(value))
        }
    }

    func testCatalogRejectsDuplicateInvalidIDsVersionsAndNonRepositoryLinks() throws {
        var bad = catalog!
        bad.plugins.append(bad.plugins[0])
        XCTAssertThrowsError(try bad.validated())
        for id in ["", " subscriptions", "../subscriptions", "Subscription", "插件"] {
            bad = catalog
            bad.plugins[0] = listing(id: id)
            XCTAssertThrowsError(try bad.validated())
        }
        for url in ["http://github.com/DeanWanghewei/NotchDeck/test", "https://example.com/test",
                    "https://github.com/another/repository", "https://github.com@evil.example/a"] {
            bad = catalog
            bad.plugins[0].documentationURL = URL(string: url)!
            XCTAssertThrowsError(try bad.validated())
        }
        bad = catalog
        bad.plugins[0].version = "1.0-beta"
        XCTAssertThrowsError(try bad.validated())
        XCTAssertThrowsError(try PluginCatalog.decode(Data("invalid".utf8)))
        XCTAssertThrowsError(try PluginCatalog.decode(Data(repeating: 32, count: PluginCatalog.maximumBytes + 1)))
        XCTAssertThrowsError(try PluginCatalog(schemaVersion: 3, plugins: []).validated()) {
            XCTAssertEqual($0 as? PluginCatalogError, .unsupportedSchema)
        }
    }

    func testCatalogScriptSourceMustComeFromRepositoryRawWithValidSHAAndVersion() throws {
        let valid = try PluginCatalog.bundled()
        XCTAssertNotNil(valid.plugins[0].script)
        XCTAssertNoThrow(try valid.validated())
        for script in [
            PluginScriptSource(url: "https://github.com/DeanWanghewei/NotchDeck/marketplace/scripts/a.js",
                               sha256: valid.plugins[0].script!.sha256, version: "1.0.0"),
            PluginScriptSource(url: "https://raw.githubusercontent.com/another/repo/main/a.js",
                               sha256: valid.plugins[0].script!.sha256, version: "1.0.0"),
            PluginScriptSource(url: "http://raw.githubusercontent.com/DeanWanghewei/NotchDeck/main/a.js",
                               sha256: valid.plugins[0].script!.sha256, version: "1.0.0"),
            PluginScriptSource(url: valid.plugins[0].script!.url, sha256: "ABCDEF", version: "1.0.0"),
            PluginScriptSource(url: valid.plugins[0].script!.url,
                               sha256: String(repeating: "0", count: 64) + "0", version: "1.0.0"),
            PluginScriptSource(url: valid.plugins[0].script!.url,
                               sha256: String(repeating: "z", count: 64), version: "1.0.0"),
            PluginScriptSource(url: valid.plugins[0].script!.url, sha256: valid.plugins[0].script!.sha256, version: "1.0-beta"),
        ] {
            var bad = valid
            bad.plugins[0].script = script
            XCTAssertThrowsError(try bad.validated())
        }
        // v1 目录（无脚本字段）继续有效，旧缓存不因升级被拒。
        var legacy = valid
        legacy.plugins[0].script = nil
        XCTAssertNoThrow(try legacy.validated())
    }

    func testFreshMarketplaceDoesNotInstantiateOrStartOptionalPluginsOrFetch() {
        var creations = 0
        var fetches = 0
        let definition = PluginImplementation(descriptor: MarketplaceFixture.descriptor, version: catalog.plugins[0].version) { _ in
            creations += 1; return ModuleBox(MarketplaceFixture())
        }
        let registry = ModuleRegistry()
        let market = PluginMarketplace(settings: settings, registry: registry, implementations: [definition],
                                       bundledCatalog: catalog, appVersion: catalog.plugins[0].minimumAppVersion, fetch: { _ in
            fetches += 1; return AnyCancellable {}
        })
        XCTAssertEqual(market.listings.count, 1)
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(fetches, 0)
        XCTAssertTrue(registry.boxes.isEmpty)
        XCTAssertTrue(settings.installedPluginIDs.isEmpty)
    }

    func testInstallRemoveReinstallPreservePreferencesAndStopBeforeUnregistering() {
        var instances: [MarketplaceFixture] = []
        let definition = PluginImplementation(descriptor: MarketplaceFixture.descriptor, version: catalog.plugins[0].version) { _ in
            let module = MarketplaceFixture()
            instances.append(module)
            return ModuleBox(module)
        }
        let registry = ModuleRegistry()
        registry.setPanelExpanded(true)
        let market = makeMarket(registry: registry, definitions: [definition])
        let preferences = settings.modulePreferences(for: "subscriptions", default: ClockPreferences())
        preferences.update { $0.showSeconds = false }
        XCTAssertTrue(market.install("subscriptions"))
        XCTAssertFalse(market.install("subscriptions"))
        XCTAssertFalse(market.install("unknown"))
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].events, ["start", "expand"])
        XCTAssertEqual(market.installedVersion("subscriptions"), catalog.plugins[0].version)
        settings.updateConfig(for: "subscriptions") { $0.pinned = true }
        XCTAssertTrue(market.remove("subscriptions"))
        XCTAssertFalse(market.remove("subscriptions"))
        XCTAssertEqual(instances[0].events, ["start", "expand", "collapse", "stop"])
        XCTAssertTrue(registry.boxes.isEmpty)
        XCTAssertTrue(settings.installedPluginIDs.isEmpty)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertFalse(restored.modulePreferences(for: "subscriptions", default: ClockPreferences()).value.showSeconds)
        XCTAssertTrue(restored.config(for: "subscriptions").pinned)
        XCTAssertTrue(market.install("subscriptions"))
        XCTAssertEqual(instances.count, 2)
        XCTAssertEqual(instances[1].events, ["start", "expand"])
        XCTAssertTrue(settings.config(for: "subscriptions").pinned)
    }

    func testLegacyConfigurationMigratesOnceAndRemovalSurvivesRestart() {
        settings.updateConfig(for: "subscriptions") { $0.enabled = false; $0.pinned = true }
        let module = MarketplaceFixture()
        let definition = implementation(module)
        let registry = ModuleRegistry()
        let market = makeMarket(registry: registry, definitions: [definition])
        XCTAssertTrue(market.isInstalled("subscriptions"))
        XCTAssertEqual(registry.boxes.map(\.id), ["subscriptions"])
        registry.updateActivity(settings: settings)
        XCTAssertTrue(module.events.isEmpty)
        market.remove("subscriptions")
        settings = SettingsStore(defaults: defaults)
        let restoredRegistry = ModuleRegistry()
        let restored = makeMarket(registry: restoredRegistry, definitions: [definition])
        XCTAssertFalse(restored.isInstalled("subscriptions"))
        XCTAssertTrue(restoredRegistry.boxes.isEmpty)
        XCTAssertTrue(settings.config(for: "subscriptions").pinned)
    }

    func testLegacyPreferencesAloneAreMigratedAndInstalledStateRestores() {
        settings.modulePreferences(for: "subscriptions", default: ClockPreferences()).update { $0.showSeconds = false }
        let market = makeMarket()
        XCTAssertTrue(market.isInstalled("subscriptions"))
        settings = SettingsStore(defaults: defaults)
        let restored = makeMarket()
        XCTAssertTrue(restored.isInstalled("subscriptions"))
        XCTAssertFalse(settings.config(for: "subscriptions", default: MarketplaceFixture.descriptor.defaultConfig).enabled)
    }

    func testUnknownNewerOrIncompatibleCatalogEntryCannotExecuteFactory() {
        let module = MarketplaceFixture()
        var future = catalog!
        future.plugins[0].version = "2.0.0"
        let newer = makeMarket(definitions: [implementation(module)], bundle: future)
        XCTAssertNotNil(newer.requirement(for: future.plugins[0]))
        XCTAssertFalse(newer.install("subscriptions"))
        future.plugins[0].version = "1.0.0"
        future.plugins[0].minimumAppVersion = "99.0.0"
        let incompatible = makeMarket(bundle: future)
        XCTAssertFalse(incompatible.install("subscriptions"))
        future.plugins[0] = listing(id: "unknown")
        let unknown = makeMarket(bundle: future)
        XCTAssertFalse(unknown.install("unknown"))
        XCTAssertTrue(module.events.isEmpty)
    }

    func testExistingRegistryIDCannotBeReplacedByMarketplaceInstall() {
        let existing = MarketplaceFixture()
        let registry = ModuleRegistry()
        registry.register(existing)
        let market = makeMarket(registry: registry)
        XCTAssertFalse(market.install("subscriptions"))
        XCTAssertFalse(market.isInstalled("subscriptions"))
        XCTAssertEqual(registry.boxes.count, 1)
        settings.setPluginInstalled("removed-from-catalog", installed: true)
        XCTAssertEqual(market.unavailableInstalledIDs, ["removed-from-catalog"])
        XCTAssertFalse(market.hasSettings("removed-from-catalog"))
        XCTAssertTrue(market.remove("removed-from-catalog"))
        XCTAssertTrue(market.unavailableInstalledIDs.isEmpty)
    }

    @MainActor
    func testPublishedNewerVersionDoesNotBlockReaddingBundledVersion() throws {
        let fetcher = CatalogFixtureFetcher()
        let market = makeMarket(fetch: fetcher.fetch)
        var future = catalog!
        future.plugins[0].version = "9.0.0"
        future.plugins[0].minimumAppVersion = "99.0.0"
        market.refresh()
        fetcher.pending[0](.success(try JSONEncoder().encode(future)))
        settleMainQueue()
        XCTAssertTrue(market.hasNativeUpdate(for: market.listings[0]))
        XCTAssertNotNil(market.requirement(for: market.listings[0]))
        XCTAssertEqual(market.installableListing("subscriptions")?.version, catalog.plugins[0].version)
        XCTAssertTrue(market.install("subscriptions"))
        XCTAssertEqual(market.installedVersion("subscriptions"), catalog.plugins[0].version)
        XCTAssertTrue(market.remove("subscriptions"))
        XCTAssertTrue(market.install("subscriptions"))
    }

    @MainActor
    func testOlderNativeCatalogStillDeliversNewerScriptIndependently() throws {
        let fetcher = CatalogFixtureFetcher()
        let market = makeMarket(fetch: fetcher.fetch)
        var published = catalog!
        published.plugins[0].version = "1.0.0"
        let script = try XCTUnwrap(published.plugins[0].script)
        published.plugins[0].script = .init(url: script.url, sha256: script.sha256, version: "9.0.0")
        market.refresh()
        fetcher.pending[0](.success(try JSONEncoder().encode(published)))
        settleMainQueue()
        XCTAssertEqual(market.listings[0].version, catalog.plugins[0].version)
        XCTAssertEqual(market.listings[0].script?.version, "9.0.0")
        XCTAssertFalse(market.hasNativeUpdate(for: market.listings[0]))
    }

    func testCorruptScriptIsRepairableInsteadOfReportedAsInstalled() throws {
        let store = tempScriptStore()
        let source = Data("var adapter = {};".utf8)
        try store.install(pluginID: "subscriptions", data: source,
                          manifest: .init(version: "1.0.0", sha256: String(repeating: "a", count: 64), downloadedAt: Date()))
        let market = makeMarket(scriptStore: store)
        XCTAssertEqual(market.scriptState(for: "subscriptions"), .notInstalled)
    }

    @MainActor
    func testAppReconcilesTabsAndSettingsPagesAfterPluginInstallAndRemoval() {
        let module = MarketplaceFixture()
        let app = AppModel(settings: settings, modules: [], plugins: [implementation(module)],
                           catalog: catalog, appVersion: catalog.plugins[0].minimumAppVersion)
        defer { app.shutdown() }
        app.isExpanded = true
        XCTAssertNil(app.activeTabID)
        XCTAssertTrue(app.marketplace.install("subscriptions"))
        settleMainQueue()
        XCTAssertEqual(app.activeTabID, "subscriptions")
        XCTAssertEqual(module.events, ["start", "expand"])
        app.marketplace.remove("subscriptions")
        settleMainQueue()
        XCTAssertNil(app.activeTabID)
        XCTAssertTrue(app.orderedBoxes.isEmpty)
        XCTAssertEqual(module.events, ["start", "expand", "collapse", "stop"])
    }

    func testSavedInstallRestoresLocalImplementationEvenWhenRemoteCatalogRequiresNewApp() throws {
        let market = makeMarket()
        XCTAssertTrue(market.install("subscriptions"))
        settings = SettingsStore(defaults: defaults)
        let registry = ModuleRegistry()
        var future = catalog!
        future.plugins[0].minimumAppVersion = "99.0.0"
        let restored = makeMarket(registry: registry, bundle: future)
        registry.updateActivity(settings: settings)
        XCTAssertTrue(restored.isInstalled("subscriptions"))
        XCTAssertNotNil(restored.requirement(for: future.plugins[0]))
        XCTAssertEqual(registry.boxes.map(\.id), ["subscriptions"])
        XCTAssertTrue(registry.boxes[0].isActive)
        XCTAssertTrue(restored.remove("subscriptions"))
    }

    @MainActor
    func testRefreshIsExplicitDoesNotOverlapAndCachesValidMetadataWithoutInstalling() throws {
        let fetcher = CatalogFixtureFetcher()
        let market = makeMarket(fetch: fetcher.fetch)
        XCTAssertTrue(fetcher.pending.isEmpty)
        market.refresh()
        market.refresh()
        XCTAssertEqual(fetcher.pending.count, 1)
        var updated = catalog!
        updated.plugins[0].summary = "新版目录介绍"
        fetcher.pending[0](.success(try JSONEncoder().encode(updated)))
        settleMainQueue()
        XCTAssertEqual(market.catalog, updated)
        XCTAssertNotNil(market.lastChecked)
        XCTAssertFalse(market.refreshing)
        XCTAssertFalse(market.isInstalled("subscriptions"))
        let restored = makeMarket()
        XCTAssertEqual(restored.catalog, updated)
        XCTAssertEqual(restored.lastChecked, market.lastChecked)
    }

    @MainActor
    func testFailedRefreshPreservesCatalogCacheAndInstalledPlugin() throws {
        let fetcher = CatalogFixtureFetcher()
        let registry = ModuleRegistry()
        let market = makeMarket(registry: registry, fetch: fetcher.fetch)
        XCTAssertTrue(market.install("subscriptions"))
        market.refresh()
        fetcher.pending[0](.success(try JSONEncoder().encode(catalog)))
        settleMainQueue()
        let cache = settings.cachedPluginCatalog
        let checked = market.lastChecked
        for failure in [Result<Data, PluginCatalogError>.failure(.network), .failure(.http(404)), .success(Data("invalid".utf8))] {
            market.refresh()
            fetcher.pending.last!(failure)
            settleMainQueue()
            XCTAssertEqual(market.catalog, catalog)
            XCTAssertEqual(market.lastChecked, checked)
            XCTAssertEqual(settings.cachedPluginCatalog, cache)
            XCTAssertNotNil(market.errorMessage)
            XCTAssertTrue(market.isInstalled("subscriptions"))
            XCTAssertTrue(registry.boxes[0].isActive)
        }
    }

    @MainActor
    func testOlderRemoteCatalogCannotReplaceNewerBundledPluginVersion() throws {
        let fetcher = CatalogFixtureFetcher()
        let market = makeMarket(fetch: fetcher.fetch)
        var older = catalog!
        older.plugins[0].version = "0.9.0"
        older.plugins[0].details = "过期的插件介绍"
        market.refresh()
        fetcher.pending[0](.success(try JSONEncoder().encode(older)))
        settleMainQueue()
        XCTAssertEqual(market.catalog, older)
        XCTAssertEqual(market.listings, catalog.plugins)
        XCTAssertTrue(market.install("subscriptions"))
        XCTAssertEqual(market.installedVersion("subscriptions"), catalog.plugins[0].version)
    }

    @MainActor
    func testRemoteOmissionCorruptCacheAndShutdownKeepOfflineCatalogUsable() throws {
        settings.cachedPluginCatalog = Data("broken".utf8)
        let fetcher = CatalogFixtureFetcher()
        let market = makeMarket(fetch: fetcher.fetch)
        XCTAssertEqual(market.catalog, catalog)
        market.refresh()
        fetcher.pending[0](.success(try JSONEncoder().encode(PluginCatalog(schemaVersion: 1, plugins: []))))
        settleMainQueue()
        XCTAssertEqual(market.listings.map(\.id), ["subscriptions"])
        market.refresh()
        market.shutdown()
        XCTAssertGreaterThan(fetcher.cancellations, 0)
        fetcher.pending[1](.success(try JSONEncoder().encode(catalog)))
        settleMainQueue()
        XCTAssertTrue(market.catalog.plugins.isEmpty)
        XCTAssertFalse(market.refreshing)
        XCTAssertFalse(market.install("subscriptions"))
        market.refresh()
        XCTAssertEqual(fetcher.pending.count, 2)
    }

    @MainActor
    func testScriptStoreVerifiesChecksumRejectsTamperingAndUninstalls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchdeck-store-\(UUID().uuidString)")
        let store = PluginScriptStore(root: root)
        let source = Data("// adapter v9".utf8)
        let manifest = PluginScriptStore.Manifest(version: "9.0.0", sha256: PluginScriptStore.sha256Hex(source), downloadedAt: Date())
        XCTAssertNil(store.installed(pluginID: "subscriptions"))
        try store.install(pluginID: "subscriptions", data: source, manifest: manifest)
        XCTAssertEqual(store.installed(pluginID: "subscriptions")?.manifest.version, "9.0.0")
        XCTAssertEqual(store.installedManifest(pluginID: "subscriptions"), manifest)
        // 篡改正文后哈希不符，按未安装处理，不进入运行时。
        try Data("// tampered".utf8).write(to: root.appendingPathComponent("subscriptions/adapter.js"))
        XCTAssertNil(store.installed(pluginID: "subscriptions"))
        store.uninstall(pluginID: "subscriptions")
        XCTAssertNil(store.installedManifest(pluginID: "subscriptions"))
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testUpdateScriptDownloadsVerifiesChecksumAndNotifiesModules() throws {
        let scriptSource = try XCTUnwrap(catalog.plugins[0].script)
        let payload = Data("var adapter = { version: '2.0.0' };".utf8)
        let digest = PluginScriptStore.sha256Hex(payload)
        var listing = catalog.plugins[0]
        listing.script = PluginScriptSource(url: scriptSource.url, sha256: digest, version: "2.0.0")
        var custom = catalog!
        custom.plugins[0] = listing
        let store = tempScriptStore()
        try store.install(pluginID: "subscriptions", data: Data("var adapter = { version: '1.0.0' };".utf8),
                          manifest: .init(version: "1.0.0",
                                          sha256: PluginScriptStore.sha256Hex(Data("var adapter = { version: '1.0.0' };".utf8)),
                                          downloadedAt: Date()))
        var completions: [PluginScriptCompletion] = []
        let market = makeMarket(bundle: custom, scriptStore: store) { _, completion in
            completions.append(completion)
            return AnyCancellable {}
        }
        XCTAssertTrue(market.install("subscriptions"))
        if case .updatable(let current, let available) = market.scriptState(for: "subscriptions") {
            XCTAssertEqual(current, "1.0.0")
            XCTAssertEqual(available, "2.0.0")
        } else { XCTFail("应识别为可更新") }
        var notified = false
        // 沙箱环境的 String object 匹配不可靠（实测通配可收到），统一 object: nil + 自行过滤。
        let observer = NotificationCenter.default.addObserver(forName: .pluginScriptDidUpdate, object: nil, queue: nil) { note in
            guard note.object as? String == "subscriptions" else { return }
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(market.updateScript(for: "subscriptions"))
        completions[0](.success(payload))
        settleMainQueue()
        // 下载完成回调与通知同在主队列：settle 后必然已投递。
        XCTAssertTrue(notified, "脚本更新成功后应广播热加载通知")
        XCTAssertEqual(market.scriptState(for: "subscriptions"), .installed(version: "2.0.0"))
        XCTAssertTrue(market.scriptMessage?.contains("2.0.0") == true)
        // 校验不符：保留现有脚本，仅提示；同一 settings 下插件已安装，无需再次 install。
        var mismatchCompletions: [PluginScriptCompletion] = []
        var mismatched = catalog!
        mismatched.plugins[0].script = PluginScriptSource(url: scriptSource.url, sha256: String(repeating: "a", count: 64), version: "3.0.0")
        let mismatchMarket = makeMarket(bundle: mismatched, scriptStore: store) { _, completion in
            mismatchCompletions.append(completion)
            return AnyCancellable {}
        }
        XCTAssertTrue(mismatchMarket.isInstalled("subscriptions"))
        XCTAssertTrue(mismatchMarket.updateScript(for: "subscriptions"))
        mismatchCompletions[0](.success(payload))
        settleMainQueue()
        XCTAssertEqual(mismatchMarket.scriptState(for: "subscriptions"), .updatable(installed: "2.0.0", available: "3.0.0"))
        XCTAssertTrue(mismatchMarket.scriptMessage?.contains("校验不符") == true)
        // 目录未声明脚本或未安装插件时不可更新。
        XCTAssertFalse(market.updateScript(for: "missing"))
        var plain = catalog!
        plain.plugins[0].script = nil
        let bare = makeMarket(bundle: plain, scriptStore: store) { _, _ in AnyCancellable {} }
        XCTAssertFalse(bare.updateScript(for: "subscriptions"))
    }

    @MainActor
    func testAutomaticRefreshThrottlesByHourAndStaysSilentOnFailure() throws {
        let fetcher = CatalogFixtureFetcher()
        let stale = CacheForTests(catalog: catalog!, fetchedAt: Date().addingTimeInterval(-2 * 3600))
        settings.cachedPluginCatalog = try JSONEncoder().encode(stale)
        let market = makeMarket(fetch: fetcher.fetch)
        market.refreshIfStale()
        XCTAssertEqual(fetcher.pending.count, 1)
        // 静默失败：不弹错误横幅，也不更新检查时间。
        fetcher.pending[0](.failure(.network))
        settleMainQueue()
        XCTAssertNil(market.errorMessage)
        XCTAssertEqual(market.lastChecked, stale.fetchedAt)
        // 一小时内不重复自动检查（失败也计入尝试时间）；手动刷新不受节流影响且失败会提示。
        market.refreshIfStale()
        XCTAssertEqual(fetcher.pending.count, 1, "节流跳过不得产生新请求（已消费回调仍在 fixture 中）")
        market.refresh()
        XCTAssertEqual(fetcher.pending.count, 2)
        fetcher.pending[1](.failure(.network))
        settleMainQueue()
        XCTAssertNotNil(market.errorMessage)
        // 成功后自动刷新同样落缓存并清错误。
        market.refresh(automatic: true)
        fetcher.pending[2](.success(try JSONEncoder().encode(catalog)))
        settleMainQueue()
        XCTAssertNil(market.errorMessage)
        XCTAssertGreaterThan(market.lastChecked!, stale.fetchedAt)
    }

    private struct CacheForTests: Codable {
        let catalog: PluginCatalog
        let fetchedAt: Date
    }

    func testCatalogTransportUsesOnlyFixedGitHubURLAndRejectsHTTPAndOversizeResponses() throws {
        let payload = try JSONEncoder().encode(catalog)
        for (status, body, expected) in [(200, payload, Optional<PluginCatalogError>.none),
                                         (404, Data(), .http(404)), (302, Data(), .http(302)),
                                         (200, Data(repeating: 32, count: PluginCatalog.maximumBytes + 1), .invalidCatalog)] {
            let finished = expectation(description: "GitHub 目录响应")
            MarketplaceURLProtocol.response = { request in
                XCTAssertEqual(request.url, PluginCatalog.downloadURL)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return (status, body)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MarketplaceURLProtocol.self]
            let request = PluginCatalogClient.fetch(configuration: configuration) { result in
                switch result {
                case .success(let data): XCTAssertNil(expected); XCTAssertEqual(data, payload)
                case .failure(let error): XCTAssertEqual(error, expected)
                }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
            withExtendedLifetime(request) {}
        }
        MarketplaceURLProtocol.response = nil
    }

    private func makeMarket(registry: ModuleRegistry = ModuleRegistry(), definitions: [PluginImplementation]? = nil,
                            bundle: PluginCatalog? = nil, fetch: @escaping PluginCatalogFetch = { _ in AnyCancellable {} },
                            scriptStore: PluginScriptStore? = nil,
                            scriptFetch: @escaping PluginScriptFetch = { _, _ in AnyCancellable {} }) -> PluginMarketplace {
        PluginMarketplace(settings: settings, registry: registry,
                          implementations: definitions ?? [implementation(MarketplaceFixture())],
                          bundledCatalog: bundle ?? catalog, appVersion: catalog.plugins[0].minimumAppVersion, fetch: fetch,
                          scriptStore: scriptStore ?? tempScriptStore(), scriptFetch: scriptFetch)
    }

    /// 测试一律用临时目录脚本仓，绝不读写用户真实的 Plugins 目录。
    private func tempScriptStore() -> PluginScriptStore {
        PluginScriptStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("notchdeck-scriptstore-\(UUID().uuidString)"))
    }

    private func implementation(_ module: MarketplaceFixture) -> PluginImplementation {
        PluginImplementation(descriptor: MarketplaceFixture.descriptor, version: catalog.plugins[0].version, makeModule: { _ in ModuleBox(module) })
    }

    private func listing(id: String) -> PluginListing {
        var entry = catalog.plugins[0]
        entry = PluginListing(id: id, name: entry.name, summary: entry.summary, details: entry.details,
                              systemImage: entry.systemImage, author: entry.author, version: entry.version,
                              minimumAppVersion: entry.minimumAppVersion, capabilities: entry.capabilities,
                              documentationURL: entry.documentationURL, sourceURL: entry.sourceURL,
                              script: entry.script)
        return entry
    }

    @MainActor private func settleMainQueue() {
        let settled = expectation(description: "目录更新")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }
}

private final class MarketplaceFixture: ObservableObject, NotchModule {
    static let descriptor = ModuleDescriptor(id: "subscriptions", title: "订阅额度", systemImage: "circle", summary: "测试",
                                             defaultConfig: ModuleConfig(enabled: false, pinned: false))
    var events: [String] = []
    func start() { events.append("start") }
    func stop() { events.append("stop") }
    func panelDidExpand() { events.append("expand") }
    func panelDidCollapse() { events.append("collapse") }
    func content() -> some View { Text("测试") }
}

private final class CatalogFixtureFetcher {
    var pending: [PluginCatalogCompletion] = []
    var cancellations = 0
    var fetch: PluginCatalogFetch { { [unowned self] completion in
        self.pending.append(completion)
        return AnyCancellable { [weak self] in self?.cancellations += 1 }
    } }
}

private final class MarketplaceURLProtocol: URLProtocol {
    static var response: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, data) = Self.response?(request), let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
