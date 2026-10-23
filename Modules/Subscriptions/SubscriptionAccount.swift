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
        return "\(provider == .glm ? "GLM" : "Codex") 账号 \(number)"
    }

    static let demoAccounts: [Self] = [
        Self(id: "demo-glm-personal", provider: .glm, alias: "个人"),
        Self(id: "demo-glm-work", provider: .glm, alias: "工作"),
        Self(id: "demo-codex-personal", provider: .codex, alias: "个人"),
        Self(id: "demo-codex-work", provider: .codex),
    ]
}

struct SubscriptionQuotaPreferences: Codable, Equatable {
    var demoMode = true
    var codexExecutable = ""
    var accounts: [SubscriptionAccount] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case demoMode, codexExecutable, accounts, glmEnabled, codexEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        demoMode = try values.decodeIfPresent(Bool.self, forKey: .demoMode) ?? true
        codexExecutable = try values.decodeIfPresent(String.self, forKey: .codexExecutable) ?? ""
        if let saved = try values.decodeIfPresent([SubscriptionAccount].self, forKey: .accounts) {
            var ids = Set<String>()
            accounts = saved.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }
        } else {
            // 固定旧账号 id 对应旧钥匙串项目，迁移配置不需要读取或复制凭据。
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
        try values.encode(demoMode, forKey: .demoMode)
        try values.encode(codexExecutable, forKey: .codexExecutable)
        try values.encode(accounts, forKey: .accounts)
    }
}
