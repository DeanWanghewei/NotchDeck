import Combine
import Foundation
import SwiftUI

struct SubscriptionQuotaPreferences: Codable, Equatable {
    var demoMode = true
    var glmEnabled = false
    var codexEnabled = false
    var codexExecutable = ""
}

/// 默认关闭；演示模式完全离线，真实查询仅在用户连接并启用组件后启动。
final class SubscriptionQuotaModule: ObservableObject, NotchModule {
    static let descriptor = ModuleDescriptor(id: "subscriptions", title: "订阅额度", systemImage: "chart.bar.xaxis",
        summary: "查看 GLM Coding Plan 与 ChatGPT · Codex 套餐额度",
        defaultConfig: ModuleConfig(enabled: false, placement: .tab, displayModeID: "cards"),
        presentation: ModulePresentationOptions(displayModes: [
            ModuleDisplayMode(id: "cards", title: "用量卡片"),
            ModuleDisplayMode(id: "compact", title: "紧凑列表"),
        ], showsSectionHeader: false))

    let preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @Published private(set) var snapshots: [SubscriptionProvider: SubscriptionQuotaSnapshot] = [:]
    @Published private(set) var errors: [SubscriptionProvider: SubscriptionQuotaError] = [:]
    @Published private(set) var refreshing: Set<SubscriptionProvider> = []
    @Published private(set) var settingsMessage: String?
    @Published private(set) var active = false

    private let clients: SubscriptionQuotaClients
    private let secrets: SubscriptionSecretStore
    private var subscription: AnyCancellable?
    private var requests: [SubscriptionProvider: SubscriptionQuotaRequest] = [:]
    private var generation = 0
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private var appliedPreferences: SubscriptionQuotaPreferences?

    init(settings: SettingsStore = .shared, clients: SubscriptionQuotaClients = .live,
         secrets: SubscriptionSecretStore = SubscriptionKeychain()) {
        preferences = settings.modulePreferences(for: Self.descriptor.id, default: SubscriptionQuotaPreferences())
        self.clients = clients
        self.secrets = secrets
    }

    deinit {
        timer?.invalidate()
        requests.values.forEach { $0.cancel() }
    }

    func start() {
        guard !active else { return }
        active = true
        subscription = preferences.$value.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configure() }
        configure()
    }

    func stop() {
        guard active else { return }
        active = false
        subscription = nil
        reset()
    }

    private func reset() {
        generation += 1
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        timer?.invalidate()
        timer = nil
        refreshing = []
        snapshots = [:]
        errors = [:]
        appliedPreferences = nil
    }

    private func configure(force: Bool = false) {
        guard active, force || appliedPreferences != preferences.value else { return }
        reset()
        appliedPreferences = preferences.value
        if preferences.value.demoMode {
            snapshots = Dictionary(uniqueKeysWithValues: SubscriptionProvider.allCases.map { ($0, .demo(for: $0)) })
        } else {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
            timer?.tolerance = 20
        }
    }

    func panelDidExpand() {
        if Date().timeIntervalSince(lastAttempt) >= 60 { refresh() }
    }

    func refresh() {
        guard active, !preferences.value.demoMode else { return }
        lastAttempt = Date()
        for provider in SubscriptionProvider.allCases where isConnected(provider) && !refreshing.contains(provider) {
            refreshing.insert(provider)
            let generation = generation
            let completion: SubscriptionQuotaCompletion = { [weak self] result in
                // 包括同步测试 client；统一延后到主队列，避免请求句柄与回调的先后竞争。
                DispatchQueue.main.async {
                    guard let self, self.active, self.generation == generation else { return }
                    self.requests.removeValue(forKey: provider)
                    self.refreshing.remove(provider)
                    switch result {
                    case .success(let snapshot): self.snapshots[provider] = snapshot; self.errors.removeValue(forKey: provider)
                    case .failure(let error): self.errors[provider] = error
                    }
                }
            }
            switch provider {
            case .glm:
                do {
                    guard let key = try secrets.readGLMKey(), !key.isEmpty else {
                        completion(.failure(.missingKey)); continue
                    }
                    requests[provider] = clients.glm(key, completion)
                } catch { completion(.failure(.keychain)) }
            case .codex:
                guard let path = CodexQuotaQuery.executable(override: preferences.value.codexExecutable) else {
                    completion(.failure(.missingCLI)); continue
                }
                requests[provider] = clients.codex(path, completion)
            }
        }
    }

    func isConnected(_ provider: SubscriptionProvider) -> Bool {
        provider == .glm ? preferences.value.glmEnabled : preferences.value.codexEnabled
    }

    @discardableResult
    func saveGLMKey(_ supplied: String) -> Bool {
        let key = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            settingsMessage = "请输入有效的 GLM Coding Plan 密钥。"
            return false
        }
        do {
            try secrets.saveGLMKey(key)
            guard preferences.update({ $0.glmEnabled = true }) else { return false }
            settingsMessage = "GLM 密钥已保存到本机钥匙串。"
            // 替换密钥时配置值可能未变，仍要取消旧账号查询和缓存。
            if active { configure(force: true) }
            return true
        } catch { settingsMessage = SubscriptionQuotaError.keychain.message(for: .glm); return false }
    }

    func removeGLMKey() {
        do {
            try secrets.removeGLMKey()
            preferences.update { $0.glmEnabled = false }
            if active { configure() }
            settingsMessage = "GLM 密钥已移除。"
        } catch { settingsMessage = SubscriptionQuotaError.keychain.message(for: .glm) }
    }

    func content() -> some View { SubscriptionQuotaView(module: self, preferences: preferences) }
    func settingsContent() -> some View { SubscriptionQuotaSettingsView(module: self, preferences: preferences) }
}
