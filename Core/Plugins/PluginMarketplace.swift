import Combine
import Foundation

struct PluginImplementation {
    let descriptor: ModuleDescriptor
    let version: String
    let makeModule: (SettingsStore) -> ModuleBox
}

/// 目录更新不改变运行代码或安装状态；工厂、用户配置与模块生命周期分别管理。
final class PluginMarketplace: ObservableObject {
    static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    @Published private(set) var catalog: PluginCatalog
    @Published private(set) var lastChecked: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var errorMessage: String?

    private let bundledCatalog: PluginCatalog
    private let implementations: [PluginImplementation]
    private let settings: SettingsStore
    private let registry: ModuleRegistry
    private let appVersion: PluginVersion?
    private let fetch: PluginCatalogFetch
    private var request: AnyCancellable?
    private var generation = 0
    private var stopped = false

    private struct Cache: Codable {
        let catalog: PluginCatalog
        let fetchedAt: Date
    }

    init(settings: SettingsStore, registry: ModuleRegistry, implementations: [PluginImplementation],
         bundledCatalog: PluginCatalog? = nil,
         appVersion: String = PluginMarketplace.applicationVersion,
         fetch: @escaping PluginCatalogFetch = { PluginCatalogClient.fetch(completion: $0) }) {
        self.settings = settings
        self.registry = registry
        self.implementations = implementations
        self.appVersion = PluginVersion(appVersion)
        self.fetch = fetch
        let bundle: PluginCatalog
        do { bundle = try (bundledCatalog ?? PluginCatalog.bundled()).validated() }
        catch {
            bundle = PluginCatalog(schemaVersion: 1, plugins: [])
            errorMessage = (error as? PluginCatalogError ?? .invalidCatalog).message
        }
        self.bundledCatalog = bundle
        catalog = bundle
        if let data = settings.cachedPluginCatalog,
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           let valid = try? cache.catalog.validated() {
            catalog = valid
            lastChecked = cache.fetchedAt
        }
        settings.migratePluginInstallations(legacyIDs: implementations.map { $0.descriptor.id })
        for implementation in implementations where settings.installedPluginIDs.contains(implementation.descriptor.id) {
            let box = implementation.makeModule(settings)
            if box.id == implementation.descriptor.id { registry.register(box) }
        }
    }

    deinit { request?.cancel() }

    var listings: [PluginListing] {
        let ids = Set(catalog.plugins.map(\.id))
        // 远端暂时下架或漏列不应让本地已有能力消失，仍可查看、添加和移除。
        let current = catalog.plugins.map { entry -> PluginListing in
            if let shipped = bundledCatalog.plugins.first(where: { $0.id == entry.id }),
               let bundledVersion = PluginVersion(shipped.version), let remoteVersion = PluginVersion(entry.version),
               bundledVersion > remoteVersion { return shipped }
            return entry
        }
        return current + bundledCatalog.plugins.filter { !ids.contains($0.id) }
    }

    var unavailableInstalledIDs: [String] {
        let listed = Set(listings.map(\.id))
        return settings.installedPluginIDs.filter { !listed.contains($0) }
    }

    func hasSettings(_ id: String) -> Bool { registry.boxes.first { $0.id == id }?.makeSettings != nil }

    func isInstalled(_ id: String) -> Bool { settings.installedPluginIDs.contains(id) }

    func installedVersion(_ id: String) -> String? {
        guard isInstalled(id) else { return nil }
        return implementations.first { $0.descriptor.id == id }?.version
    }

    func requirement(for entry: PluginListing) -> String? {
        guard let minimum = PluginVersion(entry.minimumAppVersion), let appVersion, appVersion >= minimum else {
            return "需要 NotchDeck \(entry.minimumAppVersion) 或更新版本"
        }
        guard let implementation = implementations.first(where: { $0.descriptor.id == entry.id }),
              let available = PluginVersion(implementation.version), let advertised = PluginVersion(entry.version),
              available >= advertised else { return "更新 NotchDeck 后可用" }
        return nil
    }

    /// 添加即明确启用；重新添加沿用原有位置和组件配置，不覆盖凭据。
    @discardableResult
    func install(_ id: String) -> Bool {
        guard !stopped, !isInstalled(id), let entry = listings.first(where: { $0.id == id }),
              requirement(for: entry) == nil,
              let implementation = implementations.first(where: { $0.descriptor.id == id }) else { return false }
        let box = implementation.makeModule(settings)
        guard box.id == id, registry.register(box) else { return false }
        settings.updateConfig(for: id, default: implementation.descriptor.defaultConfig) { $0.enabled = true }
        settings.setPluginInstalled(id, installed: true)
        registry.updateActivity(settings: settings)
        return true
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        guard !stopped, isInstalled(id) else { return false }
        registry.unregister(id)
        settings.setPluginInstalled(id, installed: false)
        return true
    }

    func refresh() {
        guard !stopped, !refreshing else { return }
        refreshing = true
        errorMessage = nil
        let currentGeneration = generation
        request = fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == currentGeneration else { return }
                self.refreshing = false
                self.request = nil
                do {
                    let catalog = try PluginCatalog.decode(result.get())
                    let now = Date()
                    self.settings.cachedPluginCatalog = try JSONEncoder().encode(Cache(catalog: catalog, fetchedAt: now))
                    self.catalog = catalog
                    self.lastChecked = now
                } catch {
                    self.errorMessage = (error as? PluginCatalogError ?? .invalidCatalog).message
                }
            }
        }
    }

    func shutdown() {
        stopped = true
        generation += 1
        request?.cancel()
        request = nil
        refreshing = false
    }
}
