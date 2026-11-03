import Combine
import CryptoKit
import Foundation

/// 脚本更新完成后的热加载信号；object 为插件 id，模块据此重载并立即刷新。
extension Notification.Name {
    static let pluginScriptDidUpdate = Notification.Name("NotchDeck.pluginScriptDidUpdate")
}

struct PluginImplementation {
    let descriptor: ModuleDescriptor
    let version: String
    let makeModule: (SettingsStore) -> ModuleBox
}

/// 已安装脚本相对目录声明的状态；版本比较复用 PluginVersion 的数值语义。
enum PluginScriptState: Equatable {
    case none, notInstalled, installed(version: String), updatable(installed: String, available: String)
}

/// 目录更新不改变运行代码或安装状态；工厂、用户配置与模块生命周期分别管理。
/// 适配脚本是唯一的应用内更新物：下载后经 sha256 校验落盘，以通知驱动模块热加载。
final class PluginMarketplace: ObservableObject {
    static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// 打开市场页时距上次成功检查超过该间隔才自动刷新；后台从不联网。
    static let automaticCheckInterval: TimeInterval = 3600

    @Published private(set) var catalog: PluginCatalog
    @Published private(set) var lastChecked: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatingScript = false
    @Published private(set) var scriptMessage: String?

    private let bundledCatalog: PluginCatalog
    private let implementations: [PluginImplementation]
    private let settings: SettingsStore
    private let registry: ModuleRegistry
    private let appVersion: PluginVersion?
    private let fetch: PluginCatalogFetch
    private let scriptStore: PluginScriptStore
    private let scriptFetch: PluginScriptFetch
    private var lastAutomaticAttempt: Date?
    private var request: AnyCancellable?
    private var scriptRequest: AnyCancellable?
    private var generation = 0
    private var stopped = false

    private struct Cache: Codable {
        let catalog: PluginCatalog
        let fetchedAt: Date
    }

    init(settings: SettingsStore, registry: ModuleRegistry, implementations: [PluginImplementation],
         bundledCatalog: PluginCatalog? = nil,
         appVersion: String = PluginMarketplace.applicationVersion,
         fetch: @escaping PluginCatalogFetch = { PluginCatalogClient.fetch(completion: $0) },
         scriptStore: PluginScriptStore = .shared,
         scriptFetch: @escaping PluginScriptFetch = { PluginScriptClient.fetch(url: $0, completion: $1) }) {
        self.settings = settings
        self.registry = registry
        self.implementations = implementations
        self.appVersion = PluginVersion(appVersion)
        self.fetch = fetch
        self.scriptStore = scriptStore
        self.scriptFetch = scriptFetch
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

    deinit {
        request?.cancel()
        scriptRequest?.cancel()
    }

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

    func refresh(automatic: Bool = false) {
        guard !stopped, !refreshing else { return }
        refreshing = true
        // 自动检查是静默的：失败不弹错误横幅、不覆盖此前的提示；手动刷新保持原有反馈。
        if !automatic { errorMessage = nil }
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
                    self.errorMessage = nil
                } catch {
                    if !automatic {
                        self.errorMessage = (error as? PluginCatalogError ?? .invalidCatalog).message
                    }
                }
            }
        }
    }

    /// 打开市场页时调用：距上次成功检查或上次自动尝试超过阈值才静默刷新，
    /// 避免 GitHub 不可用时每次翻页都重试，也避免每次打开都联网。
    func refreshIfStale() {
        let now = Date()
        let checked = lastChecked.map { now.timeIntervalSince($0) } ?? .infinity
        let attempted = lastAutomaticAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        guard checked >= Self.automaticCheckInterval, attempted >= Self.automaticCheckInterval else { return }
        lastAutomaticAttempt = now
        refresh(automatic: true)
    }

    func scriptState(for id: String) -> PluginScriptState {
        guard let entry = listings.first(where: { $0.id == id }), let script = entry.script else { return .none }
        guard let manifest = scriptStore.installedManifest(pluginID: id) else { return .notInstalled }
        guard let current = PluginVersion(manifest.version), let available = PluginVersion(script.version),
              current < available else { return .installed(version: manifest.version) }
        return .updatable(installed: manifest.version, available: script.version)
    }

    /// 显式动作：下载目录声明的脚本，sha256 比对通过才落盘；失败保留现有脚本并提示。
    @discardableResult
    func updateScript(for id: String) -> Bool {
        guard !stopped, isInstalled(id), !updatingScript,
              let entry = listings.first(where: { $0.id == id }), let script = entry.script,
              let url = URL(string: script.url) else { return false }
        updatingScript = true
        scriptMessage = nil
        scriptRequest = scriptFetch(url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.updatingScript = false
                self.scriptRequest = nil
                do {
                    let data = try result.get()
                    let digest = PluginScriptStore.sha256Hex(data)
                    guard digest == script.sha256, data.count <= PluginScriptClient.maximumBytes else {
                        self.scriptMessage = PluginScriptError.checksumMismatch.message
                        return
                    }
                    try self.scriptStore.install(pluginID: id, data: data,
                                                 manifest: .init(version: script.version, sha256: digest, downloadedAt: Date()))
                    self.scriptMessage = "解析脚本已更新到 v\(script.version)"
                    NotificationCenter.default.post(name: .pluginScriptDidUpdate, object: id)
                } catch let error as PluginScriptError {
                    self.scriptMessage = error.message
                } catch {
                    self.scriptMessage = PluginScriptError.network.message
                }
            }
        }
        return true
    }

    func shutdown() {
        stopped = true
        generation += 1
        request?.cancel()
        request = nil
        scriptRequest?.cancel()
        scriptRequest = nil
        refreshing = false
        updatingScript = false
    }
}
