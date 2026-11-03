import Foundation
import JavaScriptCore

/// 市场适配脚本的沙箱运行时。JSContext 默认不提供网络、文件或进程能力，
/// 脚本只产出“请求模板 + 解析函数”；凭据由查询层在发送时替换 "{credential}" 占位，
/// 脚本自身永远拿不到密钥明文。请求主机必须在白名单内，防止被诱导把凭据发往任意主机。
enum GLMScriptAdapter {
    static let allowedHosts: Set<String> = ["open.bigmodel.cn", "api.z.ai", "dev.bigmodel.cn"]
    static let maximumWindows = 8

    struct RequestTemplate {
        let url: URL
        let headers: [String: String]
    }

    /// 解析脚本声明的请求模板；结构或主机不合法返回 nil，由上层回退内置端点。
    static func request(from source: String) -> RequestTemplate? {
        guard let adapter = loadAdapter(source),
              let request = adapter.objectForKeyedSubscript("request"),
              let urlText = request.objectForKeyedSubscript("url").toString(),
              let url = URL(string: urlText),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host, allowedHosts.contains(host), !url.path.isEmpty else { return nil }
        guard let rawHeaders = request.objectForKeyedSubscript("headers")?.toDictionary() as? [String: Any],
              !rawHeaders.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for (name, value) in rawHeaders {
            guard !name.isEmpty, name.count <= 64, let text = value as? String,
                  !text.isEmpty, text.count <= 512 else { return nil }
            headers[name] = text
        }
        return RequestTemplate(url: url, headers: headers)
    }

    /// 每次调用新建 JSContext：解析运行在 URLSession 的后台 delegate 队列，
    /// JSContext 非线程安全，而查询频率低（约 5 分钟一次），重建成本可忽略。
    /// 脚本抛出 "signInRequired" 语义异常时按认证失败透传，其余异常一律视为响应无法识别。
    static func parse(source: String, body: Data, now: Date = Date()) throws -> SubscriptionQuotaSnapshot {
        guard let context = JSContext() else { throw SubscriptionQuotaError.invalidResponse }
        var exceptionText: String?
        context.exceptionHandler = { _, exception in exceptionText = exception?.toString() }
        context.evaluateScript(source)
        guard let adapter = context.globalObject.objectForKeyedSubscript("adapter"), adapter.isObject,
              let parse = adapter.objectForKeyedSubscript("parse"),
              // isFunction/callAsFunction 在当前部署目标的 SDK 不可用，用脚本内 typeof 判定可调用性。
              context.evaluateScript("typeof adapter.parse === 'function'")?.toBool() == true else {
            throw SubscriptionQuotaError.invalidResponse
        }
        let result = parse.call(withArguments: [String(decoding: body, as: UTF8.self)])
        if let exceptionText {
            throw exceptionText.contains("signInRequired")
                ? SubscriptionQuotaError.signInRequired : SubscriptionQuotaError.invalidResponse
        }
        return try snapshot(from: result, now: now)
    }

    /// 把脚本返回值收敛为快照：字段逐一校验，任何缺失或越界都拒绝，不猜、不补零。
    static func snapshot(from value: JSValue?, now: Date) throws -> SubscriptionQuotaSnapshot {
        guard let value, value.isObject,
              let dictionary = value.toDictionary() as? [String: Any],
              let rawWindows = dictionary["windows"] as? [[String: Any]],
              (1...maximumWindows).contains(rawWindows.count) else {
            throw SubscriptionQuotaError.invalidResponse
        }
        var windows: [SubscriptionQuotaWindow] = []
        for (index, raw) in rawWindows.enumerated() {
            guard let title = raw["title"] as? String, !title.isEmpty, title.count <= 32,
                  let percent = raw["usedPercent"] as? Double, percent.isFinite, percent >= 0 else {
                throw SubscriptionQuotaError.invalidResponse
            }
            var resetsAt: Date?
            if let milliseconds = raw["resetsAtMs"] as? Double, milliseconds.isFinite, milliseconds > 0 {
                let seconds = milliseconds / 1000
                // 与内置解析一致的上限（2100 年前），防把任意大数字当成有效时刻。
                if seconds < 4_102_444_800 { resetsAt = Date(timeIntervalSince1970: seconds) }
            }
            windows.append(SubscriptionQuotaWindow(id: "script-\(index)", title: title,
                                                   usedPercent: percent, resetsAt: resetsAt))
        }
        let plan = (dictionary["plan"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        return SubscriptionQuotaSnapshot(plan: plan, windows: windows, fetchedAt: now)
    }

    /// 求值脚本并取出全局 adapter 对象；语法错误或契约缺失返回 nil。
    private static func loadAdapter(_ source: String) -> JSValue? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, _ in }
        context.evaluateScript(source)
        guard let adapter = context.globalObject.objectForKeyedSubscript("adapter"), adapter.isObject else { return nil }
        return adapter
    }
}
