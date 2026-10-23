import Foundation

enum SubscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case glm, codex
    var id: String { rawValue }
    var title: String { self == .glm ? "GLM Coding Plan" : "ChatGPT · Codex" }
    var usageURL: URL {
        URL(string: self == .glm ? "https://www.bigmodel.cn/coding-plan/personal/usage" :
            "https://chatgpt.com/codex/settings/usage")!
    }
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

    static func demo(for provider: SubscriptionProvider, now: Date = Date()) -> Self {
        Self(plan: provider == .glm ? "Pro · 示例" : "Plus · 示例", windows: [
            SubscriptionQuotaWindow(id: "short", title: "5 小时", usedPercent: provider == .glm ? 32 : 68,
                resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
            SubscriptionQuotaWindow(id: "weekly", title: "每周", usedPercent: provider == .glm ? 57 : 24,
                resetsAt: now.addingTimeInterval(3 * 86400 + 3600)),
        ], fetchedAt: now)
    }
}

enum SubscriptionQuotaError: Error, Equatable {
    case invalidResponse, signInRequired, missingKey, missingCLI, timeout, cancelled, network, credentialStorage
    case authFileUnavailable, invalidAuthFile
    case http(Int)

    func message(for provider: SubscriptionProvider) -> String {
        switch self {
        case .invalidResponse: return "未识别到额度数据，请查看官方用量页"
        case .signInRequired:
            return provider == .glm ? "密钥无效或无权查询，请检查 Coding Plan 密钥" : "登录已失效或未使用 ChatGPT 登录，请重新导入 auth.json"
        case .authFileUnavailable: return "无法读取登录文件，请重新选择 auth.json"
        case .invalidAuthFile: return "登录文件无效，请选择 ChatGPT 登录生成的 auth.json"
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
        struct Limit: Decodable { let type: String; let percentage: Double? }
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
        var windows: [SubscriptionQuotaWindow] = []
        for (index, limit) in payload.limits.enumerated() {
            guard let percent = limit.percentage, percent.isFinite, percent >= 0 else { continue }
            let title: String
            switch limit.type {
            // 官方插件未提供稳定的周期/重置字段契约；不用旧版“5 小时”标签猜测新版周额度。
            case "TOKENS_LIMIT": title = "编码额度"
            case "TIME_LIMIT": title = "工具调用"
            default: continue
            }
            windows.append(SubscriptionQuotaWindow(id: "\(limit.type)-\(index)", title: title, usedPercent: percent))
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
