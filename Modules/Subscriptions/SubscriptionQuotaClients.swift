import Darwin
import Foundation

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

enum CodexQuotaAuth {
    case localCLI
    case file(String)
    case saved(Data)
}

struct CodexQuotaInput {
    var executable: String
    var auth: CodexQuotaAuth = .localCLI
}

struct CodexQuotaResult {
    var quota: Result<SubscriptionQuotaSnapshot, SubscriptionQuotaError>
    var authJSON: Data?
}

typealias CodexQuotaCompletion = (CodexQuotaResult) -> Void

struct SubscriptionQuotaClients {
    var glm: SubscriptionQuotaFetch
    var codex: (CodexQuotaInput, @escaping CodexQuotaCompletion) -> SubscriptionQuotaRequest

    static let live = Self(glm: { key, completion in
        GLMQuotaQuery.start(key: key, completion: completion)
    }, codex: { input, completion in
        let request = SubscriptionQuotaRequest()
        DispatchQueue.global(qos: .utility).async {
            completion(CodexQuotaQuery.query(input, cancellation: request))
        }
        return request
    })
}

protocol SubscriptionSecretStore {
    func readGLMKey(accountID: String) throws -> String?
    func saveGLMKey(_ key: String, accountID: String) throws
    func removeGLMKey(accountID: String) throws
    func readCodexAuth(accountID: String) throws -> Data?
    func saveCodexAuth(_ data: Data, accountID: String) throws
    func removeCodexAuth(accountID: String) throws
}

/// 只在用户导入时读取指定文件；账号元数据不保存 token，原文件不会被修改。
enum CodexAuthDocument {
    static let maximumBytes = 256 * 1024

    static func validate(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              object["auth_mode"] == nil || object["auth_mode"] as? String == "chatgpt" else {
            throw SubscriptionQuotaError.invalidAuthFile
        }
        return data
    }

    static func load(path: String) throws -> Data {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), FileManager.default.isReadableFile(atPath: expanded) else {
            throw SubscriptionQuotaError.authFileUnavailable
        }
        do {
            let url = URL(fileURLWithPath: expanded)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw SubscriptionQuotaError.authFileUnavailable
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try validate(handle.read(upToCount: maximumBytes + 1) ?? Data())
        } catch let error as SubscriptionQuotaError { throw error }
        catch { throw SubscriptionQuotaError.authFileUnavailable }
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

    /// 官方 file 存储使用 CODEX_HOME/auth.json；隔离目录避免回退到用户当前登录。
    /// 本机 0.163 探针完成隔离握手，合成无效 token 返回认证失败；不运行模型或登录切换。
    static func query(_ input: CodexQuotaInput, cancellation: SubscriptionQuotaRequest, timeout: TimeInterval = 12) -> CodexQuotaResult {
        guard !cancellation.isCancelled else { return CodexQuotaResult(quota: .failure(.cancelled)) }
        var home: URL?
        defer { if let home { try? FileManager.default.removeItem(at: home) } }
        do {
            let auth: Data
            switch input.auth {
            case .localCLI:
                return CodexQuotaResult(quota: read(executable: input.executable, cancellation: cancellation, timeout: timeout))
            case .file(let path): auth = try CodexAuthDocument.load(path: path)
            case .saved(let data): auth = try CodexAuthDocument.validate(data)
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchdeck-codex-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            home = directory
            let file = directory.appendingPathComponent("auth.json")
            guard FileManager.default.createFile(atPath: file.path, contents: auth, attributes: [.posixPermissions: 0o600]) else {
                return CodexQuotaResult(quota: .failure(.authFileUnavailable))
            }
            let result = read(executable: input.executable, cancellation: cancellation, timeout: timeout, isolatedHome: directory)
            // CLI 负责刷新 token；即使额度请求失败，也保留已经轮换的登录供下次查询使用。
            let refreshed = try? CodexAuthDocument.load(path: file.path)
            return CodexQuotaResult(quota: result, authJSON: refreshed)
        } catch let error as SubscriptionQuotaError { return CodexQuotaResult(quota: .failure(error)) }
        catch { return CodexQuotaResult(quota: .failure(.authFileUnavailable)) }
    }

    /// initialize → initialized → account/rateLimits/read；不创建会话或调用模型。
    static func read(executable: String, cancellation: SubscriptionQuotaRequest, timeout: TimeInterval = 12,
                     isolatedHome: URL? = nil)
        -> Result<SubscriptionQuotaSnapshot, SubscriptionQuotaError> {
        guard !cancellation.isCancelled else { return .failure(.cancelled) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // 旧版跟随 CLI 的账号也限定文件存储，禁止 CLI 间接触发钥匙串授权。
        process.arguments = ["app-server", "-c", "cli_auth_credentials_store=\"file\""]
        if let isolatedHome {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = isolatedHome.path
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_API_KEY")
            process.environment = environment
            process.arguments! += ["-c", "analytics.enabled=false"]
        }
        process.currentDirectoryURL = isolatedHome ?? FileManager.default.homeDirectoryForCurrentUser
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
                            return .failure(message.contains("auth") || message.contains("login") || message.contains("token") || message.contains("401") ? .signInRequired : .invalidResponse)
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
