import Darwin
import Foundation
import LocalAuthentication
import Security

/// 取消既阻断网络/子进程，也供组件屏蔽在途旧结果；取消回调不在持锁时执行。
final class SubscriptionQuotaRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func onCancel(_ action: @escaping () -> Void) {
        lock.lock()
        let run = cancelled
        if !run { self.action = action }
        lock.unlock()
        if run { action() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

typealias SubscriptionQuotaCompletion = (Result<SubscriptionQuotaSnapshot, SubscriptionQuotaError>) -> Void
typealias SubscriptionQuotaFetch = (String, @escaping SubscriptionQuotaCompletion) -> SubscriptionQuotaRequest

struct SubscriptionQuotaClients {
    var glm: SubscriptionQuotaFetch
    var codex: SubscriptionQuotaFetch

    static let live = Self(glm: { key, completion in
        GLMQuotaQuery.start(key: key, completion: completion)
    }, codex: { executable, completion in
        let request = SubscriptionQuotaRequest()
        DispatchQueue.global(qos: .utility).async {
            completion(CodexQuotaQuery.read(executable: executable, cancellation: request))
        }
        return request
    })
}

protocol SubscriptionSecretStore {
    func readGLMKey() throws -> String?
    func saveGLMKey(_ key: String) throws
    func removeGLMKey() throws
}

/// 仅访问 NotchDeck 自己保存的项目；组件未连接时不访问钥匙串，不读取浏览器 Cookie。
struct SubscriptionKeychain: SubscriptionSecretStore {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.notchdeck.app.subscription-quota", kSecAttrAccount as String: "glm-coding-plan"] }

    func readGLMKey() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw SubscriptionQuotaError.keychain
        }
        return key
    }

    func saveGLMKey(_ key: String) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SubscriptionQuotaError.keychain }
        } else if status != errSecSuccess { throw SubscriptionQuotaError.keychain }
    }

    func removeGLMKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SubscriptionQuotaError.keychain }
    }
}

/// 固定使用官方插件的只读接口；禁止重定向，避免把 Authorization 发往其他主机。
/// 来源：github.com/zai-org/zai-coding-plugins 的 glm-plan-usage/query-usage.mjs。
final class GLMQuotaQuery: NSObject, URLSessionDataDelegate {
    private var completion: SubscriptionQuotaCompletion?
    private var buffer = Data()
    private var session: URLSession?

    static func start(key: String, configuration: URLSessionConfiguration = .ephemeral,
                      completion: @escaping SubscriptionQuotaCompletion) -> SubscriptionQuotaRequest {
        let query = GLMQuotaQuery()
        query.completion = completion
        let config = configuration
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: query, delegateQueue: nil)
        query.session = session
        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        let cancellation = SubscriptionQuotaRequest()
        cancellation.onCancel { task.cancel() }
        task.resume()
        return cancellation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(.failure(code == 401 || code == 403 ? .signInRequired : .http(code)))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count + data.count <= 256 * 1024 else { finish(.failure(.invalidResponse)); return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            finish(.failure(error.code == .cancelled ? .cancelled : error.code == .timedOut ? .timeout : .network))
        } else if error != nil { finish(.failure(.network)) }
        else {
            do { finish(.success(try SubscriptionQuotaParser.glm(buffer))) }
            catch let error as SubscriptionQuotaError { finish(.failure(error)) }
            catch { finish(.failure(.invalidResponse)) }
        }
    }

    private func finish(_ result: Result<SubscriptionQuotaSnapshot, SubscriptionQuotaError>) {
        let completion = completion
        self.completion = nil
        session?.invalidateAndCancel()
        session = nil
        completion?(result)
    }
}

enum CodexQuotaQuery {
    static func executable(override: String) -> String? {
        let supplied = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = supplied.isEmpty ? [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ] : [(supplied as NSString).expandingTildeInPath]
        return paths.first { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue &&
                FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// codex-cli 0.163 的 schema 与实机探针验证：initialize → initialized → account/rateLimits/read。
    /// 只请求额度，不创建会话、不读取或复制 auth.json；CLI 使用自身已有登录。
    static func read(executable: String, cancellation: SubscriptionQuotaRequest, timeout: TimeInterval = 12)
        -> Result<SubscriptionQuotaSnapshot, SubscriptionQuotaError> {
        guard !cancellation.isCancelled else { return .failure(.cancelled) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // 对端提前退出时，写入失败应成为普通错误，不能让 SIGPIPE 结束主程序。
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return .failure(.missingCLI) }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        do {
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "notchdeck", "version": "1.0"]]])
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var pending = Data(), total = 0, initialized = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if cancellation.isCancelled { return .failure(.cancelled) }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    total += count
                    guard total <= 256 * 1024 else { return .failure(.invalidResponse) }
                    pending.append(contentsOf: bytes.prefix(count))
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        pending.removeSubrange(...newline)
                        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let id = object["id"] as? Int else { continue }
                        if let error = object["error"] as? [String: Any] {
                            let message = (error["message"] as? String ?? "").lowercased()
                            return .failure(message.contains("auth") || message.contains("login") ? .signInRequired : .invalidResponse)
                        }
                        if id == 1 && !initialized {
                            initialized = true
                            try send(["method": "initialized"])
                            try send(["id": 2, "method": "account/rateLimits/read"])
                        } else if id == 2, let result = object["result"] as? [String: Any] {
                            return .success(try SubscriptionQuotaParser.codex(JSONSerialization.data(withJSONObject: result)))
                        }
                    }
                } else if count == 0 { return .failure(.invalidResponse) }
                else if errno != EAGAIN && errno != EINTR { return .failure(.invalidResponse) }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
            return .failure(.timeout)
        } catch { return .failure(.invalidResponse) }
    }
}
