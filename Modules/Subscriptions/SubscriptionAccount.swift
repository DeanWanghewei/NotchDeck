import Foundation

struct SubscriptionAccount: Codable, Equatable, Identifiable {
    static let legacyGLMID = "legacy-glm"
    static let legacyCodexID = "legacy-codex"

    var id = UUID().uuidString
    var provider: SubscriptionProvider
    var alias = ""
    var enabled = true
    var codexAuthStored = false

    func displayName(in accounts: [Self]) -> String {
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let peers = accounts.filter { $0.provider == provider }
        let number = (peers.firstIndex { $0.id == id } ?? 0) + 1
        return "\(provider.badge) 账号 \(number)"
    }


}

struct SubscriptionQuotaPreferences: Codable, Equatable {
    var notificationsEnabled = false
    var notificationThreshold = 100
    var effectiveNotificationThreshold: Int { min(100, max(1, notificationThreshold)) }
    var codexExecutable = ""
    /// 排障开关：停用市场解析脚本，回退内置解析；不影响脚本文件与市场更新。
    var glmScriptDisabled = false
    var accounts: [SubscriptionAccount] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, notificationThreshold, codexExecutable, glmScriptDisabled, accounts, glmEnabled, codexEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        notificationThreshold = min(100, max(1, try values.decodeIfPresent(Int.self, forKey: .notificationThreshold) ?? 100))
        codexExecutable = try values.decodeIfPresent(String.self, forKey: .codexExecutable) ?? ""
        glmScriptDisabled = try values.decodeIfPresent(Bool.self, forKey: .glmScriptDisabled) ?? false
        if let saved = try values.decodeIfPresent([SubscriptionAccount].self, forKey: .accounts) {
            var ids = Set<String>()
            accounts = saved.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }
        } else {
            // 固定旧账号 id 保留设置关联；配置迁移不读取旧凭据，用户重新保存后转为加密文件。
            if try values.decodeIfPresent(Bool.self, forKey: .glmEnabled) == true {
                accounts.append(SubscriptionAccount(id: SubscriptionAccount.legacyGLMID, provider: .glm))
            }
            if try values.decodeIfPresent(Bool.self, forKey: .codexEnabled) == true {
                accounts.append(SubscriptionAccount(id: SubscriptionAccount.legacyCodexID, provider: .codex))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try values.encode(effectiveNotificationThreshold, forKey: .notificationThreshold)
        try values.encode(codexExecutable, forKey: .codexExecutable)
        try values.encode(glmScriptDisabled, forKey: .glmScriptDisabled)
        try values.encode(accounts, forKey: .accounts)
    }
}
