import Foundation

enum SubscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case glm, codex
    var id: String { rawValue }
    var title: String { self == .glm ? "GLM Coding Plan" : "ChatGPT · Codex" }

}

struct SubscriptionQuotaWindow: Equatable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    var resetsAt: Date?
    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var fraction: Double { min(1, max(0, usedPercent / 100)) }
}

struct SubscriptionQuotaSnapshot: Equatable {
    let plan: String?
    let windows: [SubscriptionQuotaWindow]
    let fetchedAt: Date


}

enum SubscriptionQuotaError: Error, Equatable {
    case invalidResponse, signInRequired, missingKey, missingCLI, timeout, cancelled, network, credentialStorage
    case authFileUnavailable, invalidAuthFile
    case invalidAuthJSON, unsupportedAuthMode, missingAuthToken, authJSONTooLarge
    case http(Int)

    func message(for provider: SubscriptionProvider) -> String {
        switch self {
        case .invalidResponse: return "未识别到额度数据，请查看官方用量页"
        case .signInRequired:
            return provider == .glm ? "密钥无效或无权查询，请检查 Coding Plan 密钥" : "登录已失效或未使用 ChatGPT 登录，请重新粘贴有效的登录 JSON"
        case .authFileUnavailable: return "无法读取登录文件，请重新选择 auth.json"
        case .invalidAuthFile: return "登录数据无效，请粘贴完整的 ChatGPT 登录 JSON"
        case .invalidAuthJSON: return "JSON 格式错误：请粘贴完整对象，包含外层大括号，不要填写文件路径或 Markdown 代码围栏"
        case .unsupportedAuthMode: return "这是 API Key 或其他登录方式；查询订阅额度需要 ChatGPT 登录的 JSON"
        case .missingAuthToken: return "JSON 缺少 tokens.access_token，请粘贴完整的 Codex 登录信息"
        case .authJSONTooLarge: return "登录 JSON 超过 256 KiB，请检查是否粘贴了其他内容"
        case .missingKey: return "请在组件设置中保存 GLM Coding Plan 密钥"
        case .missingCLI: return "未找到 Codex CLI，请安装或在组件设置中指定路径"
        case .timeout: return "查询超时，稍后可重试"
        case .cancelled: return "查询已取消"
        case .network: return "无法连接服务，请检查网络后重试"
        case .credentialStorage: return "无法读写本地加密凭据，请检查 Data 目录权限或恢复完整备份"
        case .http(let status): return "服务暂时不可用（HTTP \(status)）"
        }
    }
}

/// 接口样本来自智谱官方 glm-plan-usage 插件，以及本机 Codex 生成的公开协议 schema。
/// 不用调用次数推算百分比，也不把 API 现金余额、模型独立额度混入订阅主额度。
enum SubscriptionQuotaParser {
    static func glm(_ data: Data, now: Date = Date()) throws -> SubscriptionQuotaSnapshot {
        struct Limit: Decodable {
            let type: String
            let percentage: Double?
            let unit: Int?
            let number: Int?
            var title: String {
                guard type == "TOKENS_LIMIT" else { return "工具调用" }
                if unit == 3, number == 5 { return "5 小时" }
                if unit == 6, number == 1 { return "每周" }
                return "编码额度"
            }
        }
        struct Payload: Decodable { let limits: [Limit]; let level: String? }
        struct Envelope: Decodable { let code: Int?; let success: Bool?; let data: Payload? }
        let decoder = JSONDecoder()
        let envelope = try? decoder.decode(Envelope.self, from: data)
        // 无 Authorization 的官方接口探针返回 HTTP 200 + code 1001，不能仅看 HTTP 状态。
        if let code = envelope?.code, [401, 403, 1001].contains(code) {
            throw SubscriptionQuotaError.signInRequired
        }
        if envelope?.success == false { throw SubscriptionQuotaError.invalidResponse }
        let payload = envelope?.data ?? (try? decoder.decode(Payload.self, from: data))
        guard let payload else { throw SubscriptionQuotaError.invalidResponse }
        // 用户确认 5 小时与周额度独立；公开 CodexBar zai.js 样本映射 unit=3 为小时、6 为周。
        // 只识别已确认的 (3,5)/(6,1)，不按返回顺序判断，其他窗口保留原类别。
        // 参考：https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Resources/Plugins/zai.js
        // 比较完整原始对象，避免忽略尚不认识的字段后误删不同额度。
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let rawPayload = raw?["data"] as? [String: Any] ?? raw
        let rawLimits = rawPayload?["limits"] as? [NSDictionary] ?? []
        var seen: [NSDictionary] = []
        var limits: [Limit] = []
        for (index, limit) in payload.limits.enumerated() {
            guard ["TOKENS_LIMIT", "TIME_LIMIT"].contains(limit.type),
                  let percent = limit.percentage, percent.isFinite, percent >= 0 else { continue }
            if index < rawLimits.count {
                let object = rawLimits[index]
                if seen.contains(where: { $0.isEqual(object) }) { continue }
                seen.append(object)
            }
            limits.append(limit)
        }
        let windows = limits.enumerated().map { index, limit in
            let base = limit.title
            let siblings = limits.filter { $0.title == base }
            let ordinal = limits.prefix(index + 1).filter { $0.title == base }.count
            let title = siblings.count > 1 ? "\(base) \(ordinal)" : base
            return SubscriptionQuotaWindow(id: "\(limit.type)-\(index)", title: title, usedPercent: limit.percentage!)
        }
        guard !windows.isEmpty else { throw SubscriptionQuotaError.invalidResponse }
        return SubscriptionQuotaSnapshot(plan: payload.level, windows: windows, fetchedAt: now)
    }

    static func codex(_ data: Data, now: Date = Date()) throws -> SubscriptionQuotaSnapshot {
        struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Double? }
        struct Bucket: Decodable { let planType: String?; let primary: Window?; let secondary: Window? }
        struct Payload: Decodable { let rateLimits: Bucket?; let rateLimitsByLimitId: [String: Bucket]? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let bucket = payload.rateLimitsByLimitId?["codex"] ?? payload.rateLimits else {
            throw SubscriptionQuotaError.invalidResponse
        }
        let windows = [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { id, value -> SubscriptionQuotaWindow? in
            guard let value, value.usedPercent.isFinite, value.usedPercent >= 0 else { return nil }
            let title: String
            switch value.windowDurationMins {
            case 300: title = "5 小时"
            case 10080: title = "每周"
            case .some(let mins) where mins > 0:
                title = mins % 60 == 0 ? "\(mins / 60) 小时" : "\(mins) 分钟"
            default: title = id == "primary" ? "主要周期" : "次要周期"
            }
            let reset = value.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return SubscriptionQuotaWindow(id: id, title: title, usedPercent: value.usedPercent, resetsAt: reset)
        }
        guard !windows.isEmpty else { throw SubscriptionQuotaError.invalidResponse }
        return SubscriptionQuotaSnapshot(plan: bucket.planType, windows: windows, fetchedAt: now)
    }
}
