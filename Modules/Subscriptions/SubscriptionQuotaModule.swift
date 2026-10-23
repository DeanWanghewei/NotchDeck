import Combine
import Foundation
import SwiftUI

/// 每个账号独立持有查询与结果；别名、样式和其他账号的改动不重启已有查询。
final class SubscriptionQuotaModule: ObservableObject, NotchModule {
    static let descriptor = ModuleDescriptor(id: "subscriptions", title: "订阅额度", systemImage: "chart.bar.xaxis",
        summary: "查看多个 GLM Coding Plan 与 ChatGPT · Codex 账号的套餐额度",
        defaultConfig: ModuleConfig(enabled: false, placement: .tab, displayModeID: "cards"),
        presentation: ModulePresentationOptions(displayModes: [
            ModuleDisplayMode(id: "cards", title: "百分比长条"),
            ModuleDisplayMode(id: "rings", title: "百分比圆环"),
            ModuleDisplayMode(id: "compact", title: "紧凑长条"),
        ], showsSectionHeader: false))

    let preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @Published private(set) var snapshots: [String: SubscriptionQuotaSnapshot] = [:]
    @Published private(set) var errors: [String: SubscriptionQuotaError] = [:]
    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var settingsMessage: String?
    @Published private(set) var verifying = false
    @Published private(set) var active = false

    var displayedAccounts: [SubscriptionAccount] {
        preferences.value.accounts.filter(\.enabled)
    }

    private let notifications: AppNotificationSending
    private var alertGate = ThresholdAlertGate()
    private let clients: SubscriptionQuotaClients
    private let secrets: SubscriptionSecretStore
    private var subscription: AnyCancellable?
    private var requests: [String: SubscriptionQuotaRequest] = [:]
    private var queryIDs: [String: UUID] = [:]
    private var pendingIDs: [String] = []
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private var appliedPreferences: SubscriptionQuotaPreferences?
    private var verificationRequest: SubscriptionQuotaRequest?
    private var verificationID: UUID?
    private var verifyingAccountID: String?

    init(settings: SettingsStore = .shared, clients: SubscriptionQuotaClients = .live,
         secrets: SubscriptionSecretStore = SubscriptionFileSecretStore(),
         notifications: AppNotificationSending = AppNotificationService.shared) {
        preferences = settings.modulePreferences(for: Self.descriptor.id, default: SubscriptionQuotaPreferences())
        self.notifications = notifications
        self.clients = clients
        self.secrets = secrets
    }

    deinit {
        timer?.invalidate()
        requests.values.forEach { $0.cancel() }
        verificationRequest?.cancel()
    }

    func start() {
        guard !active else { return }
        active = true
        subscription = preferences.$value.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configure() }
        configure()
    }

    func stop() {
        active = false
        subscription = nil
        cancelAccountVerification()
        reset()
    }

    private func invalidate(_ id: String) {
        queryIDs.removeValue(forKey: id)
        requests.removeValue(forKey: id)?.cancel()
        pendingIDs.removeAll { $0 == id }
        refreshing.remove(id)
        snapshots.removeValue(forKey: id)
        errors.removeValue(forKey: id)
    }

    private func reset() {
        queryIDs.removeAll()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        pendingIDs.removeAll()
        timer?.invalidate()
        timer = nil
        refreshing = []
        snapshots = [:]
        errors = [:]
        appliedPreferences = nil
    }

    private func configure(seed: (String, SubscriptionQuotaSnapshot)? = nil) {
        guard active else { return }
        let next = preferences.value
        let previous = appliedPreferences
        if let previous {
            for account in previous.accounts {
                let current = next.accounts.first { $0.id == account.id }
                if current?.provider != account.provider || current?.enabled != account.enabled ||
                    current?.codexAuthStored != account.codexAuthStored ||
                    (account.provider == .codex && previous.codexExecutable != next.codexExecutable) {
                    invalidate(account.id)
                }
            }
        }
        appliedPreferences = next
        if let (id, snapshot) = seed {
            snapshots[id] = snapshot
            notifyIfNeeded(accountID: id, snapshot: snapshot)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
            timer?.tolerance = 20
        }
        for account in displayedAccounts where snapshots[account.id] == nil && errors[account.id] == nil {
            enqueue(account.id)
        }
        if previous?.notificationsEnabled != next.notificationsEnabled || previous?.notificationThreshold != next.notificationThreshold {
            for (id, snapshot) in snapshots where errors[id] == nil { notifyIfNeeded(accountID: id, snapshot: snapshot) }
        }
        pumpQueries()
    }

    private func notifyIfNeeded(accountID: String, snapshot: SubscriptionQuotaSnapshot) {
        guard preferences.value.notificationsEnabled,
              let account = displayedAccounts.first(where: { $0.id == accountID }) else { return }
        let threshold = preferences.value.effectiveNotificationThreshold
        for window in snapshot.windows {
            // 过期快照不能当作新周期的用量，也不能因网络失败重复提醒。
            guard window.resetsAt.map({ $0 > Date() }) ?? true else { continue }
            let key = accountID + ":" + window.id
            guard alertGate.shouldNotify(key: key, value: window.usedPercent, threshold: Double(threshold), cycle: window.resetsAt) else { continue }
            notifications.send(AppNotification(id: "subscriptions." + key, title: "订阅额度提醒",
                body: "\(account.displayName(in: displayedAccounts)) · \(account.provider.title) · \(window.title)已用 \(window.usedPercent.formatted())%（阈值 \(threshold)%）")) { [weak self] delivered in
                if !delivered { self?.alertGate.retry(key: key) }
            }
        }
    }

    func panelDidExpand() {
        if Date().timeIntervalSince(lastAttempt) >= 60 { refresh() }
    }

    func refresh() {
        guard active else { return }
        lastAttempt = Date()
        displayedAccounts.forEach { enqueue($0.id) }
        pumpQueries()
    }

    private func enqueue(_ id: String) {
        guard !refreshing.contains(id) else { return }
        refreshing.insert(id)
        pendingIDs.append(id)
    }

    private func pumpQueries() {
        guard active else { return }
        // 避免大量账号同时启动 CLI；排队中的账号仍可单独取消。
        while requests.count < 3, !pendingIDs.isEmpty {
            let id = pendingIDs.removeFirst()
            guard let account = displayedAccounts.first(where: { $0.id == id }) else { refreshing.remove(id); continue }
            let queryID = UUID()
            queryIDs[id] = queryID
            requests[id] = SubscriptionQuotaRequest()
            let completion: SubscriptionQuotaCompletion = { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.active, self.queryIDs[id] == queryID,
                          self.preferences.value.accounts.contains(where: { $0.id == id && $0.enabled }) else { return }
                    self.requests.removeValue(forKey: id)
                    self.queryIDs.removeValue(forKey: id)
                    self.refreshing.remove(id)
                    switch result {
                    case .success(let snapshot):
                        self.snapshots[id] = snapshot
                        self.errors.removeValue(forKey: id)
                        self.notifyIfNeeded(accountID: id, snapshot: snapshot)
                    case .failure(let error): self.errors[id] = error
                    }
                    self.pumpQueries()
                }
            }
            do {
                switch account.provider {
                case .glm:
                    guard let key = try secrets.readGLMKey(accountID: id), !key.isEmpty else {
                        completion(.failure(.missingKey)); continue
                    }
                    requests[id] = clients.glm(key, completion)
                case .codex:
                    guard let executable = CodexQuotaQuery.executable(override: preferences.value.codexExecutable) else {
                        completion(.failure(.missingCLI)); continue
                    }
                    let auth: CodexQuotaAuth
                    if account.codexAuthStored {
                        guard let saved = try secrets.readCodexAuth(accountID: id) else {
                            completion(.failure(.signInRequired)); continue
                        }
                        auth = .saved(saved)
                    } else { auth = .localCLI }
                    requests[id] = clients.codex(CodexQuotaInput(executable: executable, auth: auth)) { [weak self] response in
                        DispatchQueue.main.async {
                            guard let self, self.active, self.queryIDs[id] == queryID else { return }
                            do {
                                if account.codexAuthStored, let data = response.authJSON {
                                    try self.secrets.saveCodexAuth(data, accountID: id)
                                }
                                completion(response.quota)
                            } catch { completion(.failure(.credentialStorage)) }
                        }
                    }
                }
            } catch { completion(.failure(.credentialStorage)) }
        }
    }

    @discardableResult
    func saveGLMAccount(_ account: SubscriptionAccount, key supplied: String) -> Bool {
        guard account.provider == .glm, validAlias(account.alias) else { return false }
        let key = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = preferences.value.accounts.contains { $0.id == account.id && $0.provider == .glm }
        if !key.isEmpty || !exists {
            guard !key.isEmpty, key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
                settingsMessage = "请输入有效的 GLM Coding Plan 密钥。"; return false
            }
            do { try secrets.saveGLMKey(key, accountID: account.id) }
            catch { settingsMessage = SubscriptionQuotaError.credentialStorage.message(for: .glm); return false }
            invalidate(account.id)
        }
        guard storeAccount(account) else { return false }
        configure()
        settingsMessage = "GLM 账号已保存，密钥已加密保存在应用 Data 目录。"
        return true
    }

    func saveCodexAccount(_ account: SubscriptionAccount, authJSON: String, completion: @escaping (Bool) -> Void) {
        guard account.provider == .codex, validAlias(account.alias), !verifying else { completion(false); return }
        let json = authJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.isEmpty, let existing = preferences.value.accounts.first(where: { $0.id == account.id && $0.provider == .codex }) {
            var next = account
            next.codexAuthStored = existing.codexAuthStored
            let saved = storeAccount(next)
            configure()
            if saved { settingsMessage = "Codex 账号设置已保存。" }
            completion(saved)
            return
        }
        let auth: Data
        do { auth = try CodexAuthDocument.parsePastedJSON(json) }
        catch let error as SubscriptionQuotaError { settingsMessage = error.message(for: .codex); completion(false); return }
        catch { settingsMessage = "无法解析登录 JSON。"; completion(false); return }
        guard let executable = CodexQuotaQuery.executable(override: preferences.value.codexExecutable) else {
            settingsMessage = SubscriptionQuotaError.missingCLI.message(for: .codex); completion(false); return
        }
        let verificationID = UUID()
        self.verificationID = verificationID
        verifyingAccountID = account.id
        verifying = true
        settingsMessage = "JSON 格式已通过，正在验证登录并查询订阅额度…"
        verificationRequest = clients.codex(CodexQuotaInput(executable: executable, auth: .saved(auth))) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.verificationID == verificationID else { return }
                self.verifying = false
                self.verificationRequest = nil
                self.verificationID = nil
                self.verifyingAccountID = nil
                switch response.quota {
                case .failure(let error):
                    self.settingsMessage = error.message(for: .codex)
                    completion(false)
                case .success(let snapshot):
                    guard let data = response.authJSON, (try? CodexAuthDocument.validate(data)) != nil else {
                        self.settingsMessage = SubscriptionQuotaError.invalidAuthFile.message(for: .codex)
                        completion(false); return
                    }
                    do { try self.secrets.saveCodexAuth(data, accountID: account.id) }
                    catch {
                        self.settingsMessage = SubscriptionQuotaError.credentialStorage.message(for: .codex)
                        completion(false); return
                    }
                    var next = account
                    next.codexAuthStored = true
                    self.invalidate(account.id)
                    guard self.storeAccount(next) else { completion(false); return }
                    self.configure(seed: (account.id, snapshot))
                    self.settingsMessage = "验证成功，登录已独立保存；切换 Codex 账号不会影响此账号。"
                    completion(true)
                }
            }
        }
    }

    func cancelAccountVerification() {
        if verifying { settingsMessage = "验证已取消，未更改已保存账号。" }
        verificationID = nil
        verifyingAccountID = nil
        verificationRequest?.cancel()
        verificationRequest = nil
        verifying = false
    }

    func removeAccount(_ id: String) {
        guard let account = preferences.value.accounts.first(where: { $0.id == id }) else { return }
        do {
            if account.provider == .glm { try secrets.removeGLMKey(accountID: id) }
            else { try secrets.removeCodexAuth(accountID: id) }
            if verifyingAccountID == id { cancelAccountVerification() }
            invalidate(id)
            preferences.update { $0.accounts.removeAll { $0.id == id } }
            configure()
            settingsMessage = "账号与本软件保存的凭据已移除，原始登录文件保持不变。"
        } catch { settingsMessage = SubscriptionQuotaError.credentialStorage.message(for: account.provider) }
    }

    func clearSettingsMessage() { settingsMessage = nil }

    private func validAlias(_ alias: String) -> Bool {
        guard alias.count <= 80 else { settingsMessage = "别名最多 80 个字符。"; return false }
        return true
    }

    private func storeAccount(_ account: SubscriptionAccount) -> Bool {
        preferences.update {
            if let index = $0.accounts.firstIndex(where: { $0.id == account.id }) { $0.accounts[index] = account }
            else { $0.accounts.append(account) }
        }
    }

    func content() -> some View { SubscriptionQuotaView(module: self, preferences: preferences) }
    func settingsContent() -> some View { SubscriptionQuotaSettingsView(module: self, preferences: preferences) }
}
