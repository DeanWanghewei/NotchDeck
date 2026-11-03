import Foundation

enum SubscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case glm, codex
    /// rawValue 落进 UserDefaults，是账号的持久化标识；改名会让旧账号无法识别。
    case minimaxCN = "minimax-cn"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glm: return "GLM Coding Plan"
        case .codex: return "ChatGPT · Codex"
        case .minimaxCN: return "MiniMax M Plan（中国区）"
        }
    }

    /// 卡片角标：标题栏空间有限，只显示服务简称。
    var badge: String {
        switch self {
        case .glm: return "GLM"
        case .codex: return "Codex"
        case .minimaxCN: return "MiniMax"
        }
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
    /// 密钥有效但没有绑定订阅套餐（按量计费 Key 或未开通 M Plan）。
    case notInPlan
    case http(Int)

    func message(for provider: SubscriptionProvider) -> String {
        switch self {
        case .invalidResponse: return "未识别到额度数据，请查看官方用量页"
        case .signInRequired:
            switch provider {
            case .glm: return "密钥无效或无权查询，请检查 Coding Plan 密钥"
            case .codex: return "登录已失效或未使用 ChatGPT 登录，请重新粘贴有效的登录 JSON"
            case .minimaxCN: return "订阅 Key 无效或未通过鉴权，请在 M Plan 控制台重新复制订阅 Key"
            }
        case .notInPlan: return "当前 Key 未开通 M Plan 订阅，额度查询需使用 sk-cp- 开头的订阅 Key"
        case .authFileUnavailable: return "无法读取登录文件，请重新选择 auth.json"
        case .invalidAuthFile: return "登录数据无效，请粘贴完整的 ChatGPT 登录 JSON"
        case .invalidAuthJSON: return "JSON 格式错误：请粘贴完整对象，包含外层大括号，不要填写文件路径或 Markdown 代码围栏"
        case .unsupportedAuthMode: return "这是 API Key 或其他登录方式；查询订阅额度需要 ChatGPT 登录的 JSON"
        case .missingAuthToken: return "JSON 缺少 tokens.access_token，请粘贴完整的 Codex 登录信息"
        case .authJSONTooLarge: return "登录 JSON 超过 256 KiB，请检查是否粘贴了其他内容"
        case .missingKey:
            switch provider {
            case .glm: return "请在组件设置中保存 GLM Coding Plan 密钥"
            case .codex: return "请在组件设置中导入 ChatGPT 登录 JSON"
            case .minimaxCN: return "请在组件设置中保存 MiniMax M Plan 订阅 Key"
            }
        case .missingCLI: return "未找到 Codex CLI，请安装或在组件设置中指定路径"
        case .timeout: return "查询超时，稍后可重试"
        case .cancelled: return "查询已取消"
        case .network: return "无法连接服务，请检查网络后重试"
        case .credentialStorage: return "无法读写本地加密凭据，请检查 Data 目录权限或恢复完整备份"
        case .http(let status): return "服务暂时不可用（HTTP \(status)）"
        }
    }
}

/// MiniMax M Plan 额度响应条目：一个模型桶（general / video 等）的两个额度窗口。
/// 字段名取自官方 CLI 与公开实现记录的实测响应，缺失字段一律按"未提供"处理。
private struct MinimaxEntry: Decodable, Equatable {
    let modelName: String?
    let intervalRemaining: MinimaxPercent?
    let intervalStatus: Int?
    let intervalTotal: Double?
    let weeklyRemaining: MinimaxPercent?
    let weeklyStatus: Int?
    let weeklyTotal: Double?
    let endTime: Double?
    let weeklyEndTime: Double?
    let remainsTime: Double?
    let weeklyRemainsTime: Double?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case intervalRemaining = "current_interval_remaining_percent"
        case intervalStatus = "current_interval_status"
        case intervalTotal = "current_interval_total_count"
        case weeklyRemaining = "current_weekly_remaining_percent"
        case weeklyStatus = "current_weekly_status"
        case weeklyTotal = "current_weekly_total_count"
        case endTime = "end_time"
        case weeklyEndTime = "weekly_end_time"
        case remainsTime = "remains_time"
        case weeklyRemainsTime = "weekly_remains_time"
    }
}

/// 百分比在实测响应里出现过数字、数字字符串与带百分号字符串三种形态，
/// 统一收敛为可选 Double，避免因类型差异把有效额度判成无效响应。
private struct MinimaxPercent: Decodable, Equatable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil; return }
        if let number = try? container.decode(Double.self) { value = number; return }
        var text = (try? container.decode(String.self)) ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("%") { text.removeLast() }
        value = Double(text)
    }
}

private struct MinimaxBaseResp: Decodable {
    let statusCode: Int?
    enum CodingKeys: String, CodingKey { case statusCode = "status_code" }
}

/// 套餐名可能出现在根层或 data 层，字段名有多个历史别名，按顺序取第一个非空值。
private struct MinimaxPlanFields {
    let currentSubscribeTitle: String?
    let planName: String?
    let comboTitle: String?
    let currentPlanTitle: String?

    var resolved: String? {
        [currentSubscribeTitle, planName, comboTitle, currentPlanTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

/// 额度列表既可能在根层，也可能在 data 包裹层（控制台口径），两种都要认。
private struct MinimaxData: Decodable {
    let modelRemains: [MinimaxEntry]?
    let planTitle: String?

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelRemains = try container.decodeIfPresent([MinimaxEntry].self, forKey: .modelRemains)
        planTitle = MinimaxPlanFields(
            currentSubscribeTitle: try? container.decodeIfPresent(String.self, forKey: .currentSubscribeTitle),
            planName: try? container.decodeIfPresent(String.self, forKey: .planName),
            comboTitle: try? container.decodeIfPresent(String.self, forKey: .comboTitle),
            currentPlanTitle: try? container.decodeIfPresent(String.self, forKey: .currentPlanTitle)
        ).resolved
    }
}

private struct MinimaxEnvelope: Decodable {
    let baseResp: MinimaxBaseResp?
    let modelRemains: [MinimaxEntry]?
    let data: MinimaxData?
    let planTitle: String?

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case modelRemains = "model_remains"
        case data
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseResp = try container.decodeIfPresent(MinimaxBaseResp.self, forKey: .baseResp)
        modelRemains = try container.decodeIfPresent([MinimaxEntry].self, forKey: .modelRemains)
        data = try container.decodeIfPresent(MinimaxData.self, forKey: .data)
        planTitle = MinimaxPlanFields(
            currentSubscribeTitle: try? container.decodeIfPresent(String.self, forKey: .currentSubscribeTitle),
            planName: try? container.decodeIfPresent(String.self, forKey: .planName),
            comboTitle: try? container.decodeIfPresent(String.self, forKey: .comboTitle),
            currentPlanTitle: try? container.decodeIfPresent(String.self, forKey: .currentPlanTitle)
        ).resolved
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

    /// MiniMax M Plan（中国区）只读额度接口 `GET /v1/token_plan/remains`。
    /// 端点、请求头与响应结构来自官方文档、官方 CLI（mmx-cli）与公开实现的实测样本：
    /// 顶层为 `base_resp` + `model_remains`（控制台口径会再包一层 data），
    /// 每个条目按模型桶（general / video 等）给出 5 小时窗口与每周窗口的剩余百分比。
    /// 接口只给"剩余百分比"，已用百分比由 100 减去得到；计数常年为 0，不参与推算。
    static func minimax(_ data: Data, now: Date = Date()) throws -> SubscriptionQuotaSnapshot {
        guard let envelope = try? JSONDecoder().decode(MinimaxEnvelope.self, from: data) else {
            throw SubscriptionQuotaError.invalidResponse
        }
        // 接口恒返回 HTTP 200，鉴权与业务失败都放在 base_resp 里，必须看业务码。
        if let code = envelope.baseResp?.statusCode, code != 0 {
            switch code {
            case 1004, 1016: throw SubscriptionQuotaError.signInRequired
            case 2062: throw SubscriptionQuotaError.notInPlan
            default: throw SubscriptionQuotaError.invalidResponse
            }
        }
        let entries = envelope.modelRemains ?? envelope.data?.modelRemains ?? []
        guard !entries.isEmpty else { throw SubscriptionQuotaError.invalidResponse }
        // 不在套餐内的条目：两个窗口都不适用且计数为 0，按官方 CLI 的判定口径跳过。
        let usable = entries.filter { !Self.minimaxNotInPlan($0) }
        guard !usable.isEmpty else { throw SubscriptionQuotaError.notInPlan }
        // general 桶同时带 5 小时与每周窗口，是套餐主额度；缺失时退回第一个可用条目。
        let primaryIndex = usable.firstIndex { $0.modelName == "general" } ?? 0
        var windows: [SubscriptionQuotaWindow] = []
        for (index, entry) in usable.enumerated() {
            let isPrimary = index == primaryIndex
            let prefix = isPrimary ? "" : "\(Self.minimaxBucketName(entry.modelName)) · "
            // 5 小时窗口只对非视频模型生效；状态 3 表示该窗口不在套餐内，不补零展示。
            if let percent = entry.intervalRemaining?.value, percent.isFinite, entry.intervalStatus != 3 {
                windows.append(SubscriptionQuotaWindow(id: "interval-\(index)",
                    title: prefix + "5 小时", usedPercent: Self.minimaxUsedPercent(remaining: percent),
                    resetsAt: Self.minimaxReset(end: entry.endTime, remains: entry.remainsTime, now: now)))
            }
            if let percent = entry.weeklyRemaining?.value, percent.isFinite {
                windows.append(SubscriptionQuotaWindow(id: "weekly-\(index)",
                    title: prefix + "每周", usedPercent: Self.minimaxUsedPercent(remaining: percent),
                    resetsAt: Self.minimaxReset(end: entry.weeklyEndTime, remains: entry.weeklyRemainsTime, now: now)))
            }
        }
        guard !windows.isEmpty else { throw SubscriptionQuotaError.notInPlan }
        let plan = envelope.planTitle ?? envelope.data?.planTitle
        return SubscriptionQuotaSnapshot(plan: plan, windows: windows, fetchedAt: now)
    }

    /// 两个窗口都不在套餐内且计数为 0：官方 CLI 判定为"不在当前套餐中"。
    private static func minimaxNotInPlan(_ entry: MinimaxEntry) -> Bool {
        entry.intervalStatus == 3 && entry.weeklyStatus == 3 &&
            (entry.intervalTotal ?? 0) == 0 && (entry.weeklyTotal ?? 0) == 0
    }

    /// 模型桶名：官方只区分 general（通用）与 video（视频），其余按服务端原名截断显示。
    private static func minimaxBucketName(_ name: String?) -> String {
        switch name {
        case "general": return "通用"
        case "video": return "视频"
        case .some(let value) where !value.isEmpty: return String(value.prefix(16))
        default: return "其他"
        }
    }

    /// 接口给的是剩余百分比，展示口径统一为已用；越界值夹紧到 0…100，不外推。
    private static func minimaxUsedPercent(remaining: Double) -> Double {
        min(100, max(0, 100 - remaining))
    }

    /// 重置时刻优先取窗口结束的绝对时刻（epoch 毫秒）；
    /// 缺失时用"距重置剩余毫秒"推算，两种形态都来自官方 CLI 的同一响应。
    private static func minimaxReset(end: Double?, remains: Double?, now: Date) -> Date? {
        if let end, end.isFinite, end > 0 {
            let seconds = end >= 10_000_000_000 ? end / 1000 : end
            // 上限取 2100 年之前，防止把任意大数字当成有效重置时刻。
            if seconds < 4_102_444_800 { return Date(timeIntervalSince1970: seconds) }
        }
        if let remains, remains.isFinite, remains > 0 { return now.addingTimeInterval(remains / 1000) }
        return nil
    }
}
