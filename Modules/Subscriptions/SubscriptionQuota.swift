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

extension SubscriptionQuotaWindow {
    /// 距重置的剩余时长（分钟粒度），供文字与悬浮提示共用。
    func remainingDuration(now: Date = Date()) -> String? {
        guard let reset = resetsAt else { return nil }
        let remaining = reset.timeIntervalSince(now)
        // 不足一分钟按 1 分钟显示，避免与“已到期”之间来回跳。
        let minutes = remaining > 0 ? max(1, Int(remaining / 60)) : 0
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 1440 {
            let (hours, rest) = (minutes / 60, minutes % 60)
            return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
        }
        let (days, hours) = (minutes / 1440, minutes % 1440 / 60)
        return hours == 0 ? "\(days) 天" : "\(days) 天 \(hours) 小时"
    }

    /// 行内重置说明：剩余时长与绝对时间点同现，便于直接对照官方用量页；
    /// 今天的重置只显时分，跨天补月日。
    func resetDescription(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let reset = resetsAt else { return "服务未提供重置时间" }
        guard let duration = remainingDuration(now: now) else { return "周期已到，等待刷新" }
        let style: Date.FormatStyle = calendar.isDate(reset, inSameDayAs: now)
            ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute()
        return "还剩 \(duration) · \(reset.formatted(style)) 重置"
    }

    /// 悬浮提示始终带月日，与行内（今天只显时分）互补。
    func resetHelpDescription(now: Date = Date()) -> String {
        guard let reset = resetsAt else { return "服务未提供重置时间" }
        guard let duration = remainingDuration(now: now) else { return "周期已到，等待刷新" }
        return "还剩 \(duration)，重置于 \(reset.formatted(.dateTime.month().day().hour().minute()))"
    }
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
        // 去重会跳过部分条目，过滤后的下标不再对应原始数组，须与原始对象一并携带，
        // 否则 nextResetTime 会错配到别的窗口。
        var kept: [(limit: Limit, raw: NSDictionary?)] = []
        for (index, limit) in payload.limits.enumerated() {
            guard ["TOKENS_LIMIT", "TIME_LIMIT"].contains(limit.type),
                  let percent = limit.percentage, percent.isFinite, percent >= 0 else { continue }
            let object = index < rawLimits.count ? rawLimits[index] : nil
            if let object {
                if seen.contains(where: { $0.isEqual(object) }) { continue }
                seen.append(object)
            }
            kept.append((limit, object))
        }
        let windows = kept.enumerated().map { index, entry in
            let base = entry.limit.title
            let siblings = kept.filter { $0.limit.title == base }
            let ordinal = kept.prefix(index + 1).filter { $0.limit.title == base }.count
            let title = siblings.count > 1 ? "\(base) \(ordinal)" : base
            let reset = entry.raw.flatMap { Self.glmResetTime($0["nextResetTime"]) }
            return SubscriptionQuotaWindow(id: "\(entry.limit.type)-\(index)", title: title,
                                           usedPercent: entry.limit.percentage!, resetsAt: reset)
        }
        guard !windows.isEmpty else { throw SubscriptionQuotaError.invalidResponse }
        return SubscriptionQuotaSnapshot(plan: payload.level, windows: windows, fetchedAt: now)
    }

    /// 重置时间直接来自条目的 nextResetTime，不调用推理接口、不从 429 错误文本估算。
    /// 已实证形态（zai-org/ZCode、Raycast agent-usage、zai-rs 等公开实现的响应样本）：
    /// epoch 毫秒数字与 RFC3339 字符串，另有数字字符串与按秒计的数字；
    /// ≥1e10 视为毫秒、否则按秒，超出合理年代范围或无法解析一律视为未提供。
    static func glmResetTime(_ value: Any?) -> Date? {
        let numeric: Double?
        switch value {
        case is Bool: return nil
        case let number as NSNumber: numeric = number.doubleValue
        case let text as String:
            if let date = glmDateFormatters.compactMap({ $0.date(from: text) }).first { return date }
            numeric = Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
        guard let numeric, numeric.isFinite, numeric > 0 else { return nil }
        let seconds = numeric >= 10_000_000_000 ? numeric / 1000 : numeric
        // 上限取 2100 年之前，防止把任意大数字当成有效重置时刻。
        guard seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// ISO8601DateFormatter 线程安全；需两个实例分别覆盖带与不带小数秒的 RFC3339。
    private static let glmDateFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = ISO8601DateFormatter()
        base.formatOptions = [.withInternetDateTime]
        return [fractional, base]
    }()

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
