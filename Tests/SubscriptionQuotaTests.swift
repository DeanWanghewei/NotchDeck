import Foundation
import XCTest

final class SubscriptionQuotaTests: XCTestCase {
    func testCodexUsesMainBucketAndServerDurationsWithoutMixingModelQuotas() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":57,"windowDurationMins":10080}},"review":{"primary":{"usedPercent":100}}}}"#.utf8)
        let snapshot = try SubscriptionQuotaParser.codex(data)
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.windows.map(\.title), ["5 小时", "每周"])
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [68, 43])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1900000000))
        XCTAssertNil(snapshot.windows.last?.resetsAt)
    }

    func testCodexLegacyPayloadPreservesOverageAndDoesNotInventMissingWindows() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":15,"resetsAt":1},"secondary":null}}"#.utf8)
        let snapshot = try SubscriptionQuotaParser.codex(data)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].title, "15 分钟")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 120)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 0)
        XCTAssertEqual(snapshot.windows[0].fraction, 1)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1))
        XCTAssertThrowsError(try SubscriptionQuotaParser.codex(Data(#"{"rateLimits":{"primary":null}}"#.utf8)))
    }

    func testGLMReadsOfficialPluginFieldsWithoutGuessingResetPeriods() throws {
        let data = Data(#"{"code":200,"success":true,"data":{"level":"pro","limits":[{"type":"TOKENS_LIMIT","percentage":28},{"type":"TIME_LIMIT","percentage":60},{"type":"FUTURE_LIMIT","percentage":10}]}}"#.utf8)
        let snapshot = try SubscriptionQuotaParser.glm(data)
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.windows.map(\.title), ["编码额度", "工具调用"])
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [72, 40])
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt == nil })
    }

    func testMissingInvalidAndUnauthorizedPayloadsNeverBecomeZeroUsage() {
        for input in ["{}", "invalid", #"{"limits":[{"type":"TOKENS_LIMIT"}]}"#,
                      #"{"limits":[{"type":"TOKENS_LIMIT","percentage":-1}]}"#,
                      #"{"success":false,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":0}]}}"#] {
            XCTAssertThrowsError(try SubscriptionQuotaParser.glm(Data(input.utf8)))
        }
        XCTAssertThrowsError(try SubscriptionQuotaParser.glm(Data(#"{"code":1001,"success":false}"#.utf8))) {
            XCTAssertEqual($0 as? SubscriptionQuotaError, .signInRequired)
        }
        XCTAssertThrowsError(try SubscriptionQuotaParser.codex(Data(#"{"rateLimitsByLimitId":{"review":{"primary":{"usedPercent":0}}}}"#.utf8)))
    }

    func testGLMTransportUsesFixedHostAndRecognizesBusinessAuthenticationFailure() {
        let finished = expectation(description: "业务认证失败")
        QuotaURLProtocol.response = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-only-key")
            return (200, Data(#"{"code":1001,"success":false}"#.utf8))
        }
        defer { QuotaURLProtocol.response = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaURLProtocol.self]
        let request = GLMQuotaQuery.start(key: "test-only-key", configuration: config) { result in
            self.assertFailure(result, .signInRequired)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        withExtendedLifetime(request) {}
    }

    func testGLMTransportRejectsHTTPFailuresAndExcessiveBodies() {
        for (status, body, expected) in [(403, Data(), SubscriptionQuotaError.signInRequired),
                                      (503, Data(), .http(503)),
                                      (200, Data(repeating: 32, count: 300 * 1024), .invalidResponse)] {
            let finished = expectation(description: "HTTP 或响应上限")
            QuotaURLProtocol.response = { _ in (status, body) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [QuotaURLProtocol.self]
            let request = GLMQuotaQuery.start(key: "test-only-key", configuration: config) { result in
                self.assertFailure(result, expected)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
            withExtendedLifetime(request) {}
        }
        QuotaURLProtocol.response = nil
    }

    func testCodexTransportCompletesHandshakeAndReadsOnlyQuotaResponse() throws {
        let executable = try script(#"""
        IFS= read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        case "$initialized" in *initialized*) ;; *) exit 8;; esac
        IFS= read -r query
        case "$query" in *rateLimits*) ;; *) exit 9;; esac
        printf '%s\n' '{"method":"notice","params":{}}'
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":41,"windowDurationMins":300}}}}'
        while IFS= read -r line; do :; done
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let result = CodexQuotaQuery.read(executable: executable.path, cancellation: SubscriptionQuotaRequest(), timeout: 2)
        XCTAssertEqual(try result.get().windows.first?.remainingPercent, 59)
    }

    func testCodexTransportHasHardDeadlineOutputLimitAndCancellation() throws {
        let silent = try script("while IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: silent.deletingLastPathComponent()) }
        let start = Date()
        assertFailure(CodexQuotaQuery.read(executable: silent.path, cancellation: SubscriptionQuotaRequest(), timeout: 0.1), .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let cancelled = SubscriptionQuotaRequest()
        cancelled.cancel()
        assertFailure(CodexQuotaQuery.read(executable: silent.path, cancellation: cancelled), .cancelled)
        let duringRead = SubscriptionQuotaRequest()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { duringRead.cancel() }
        assertFailure(CodexQuotaQuery.read(executable: silent.path, cancellation: duringRead, timeout: 2), .cancelled)
        let noisy = try script("while :; do printf '%0500d' 0; done")
        defer { try? FileManager.default.removeItem(at: noisy.deletingLastPathComponent()) }
        assertFailure(CodexQuotaQuery.read(executable: noisy.path, cancellation: SubscriptionQuotaRequest(), timeout: 2), .invalidResponse)
    }

    func testCodexTransportHandlesExitAndSanitizesAuthenticationError() throws {
        let executable = try script(#"""
        IFS= read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r query
        printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"chatgpt authentication required"}}'
        while IFS= read -r line; do :; done
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        assertFailure(CodexQuotaQuery.read(executable: executable.path, cancellation: SubscriptionQuotaRequest(), timeout: 2), .signInRequired)
        assertFailure(CodexQuotaQuery.read(executable: "/usr/bin/false", cancellation: SubscriptionQuotaRequest(), timeout: 1), .invalidResponse)
    }

    @MainActor
    func testDefaultDemoAndDisabledLifecycleNeverTouchCredentialsOrNetwork() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            XCTAssertTrue(module.snapshots.isEmpty)
            XCTAssertEqual(secrets.readCount, 0)
            module.refresh()
            XCTAssertTrue(client.pending.isEmpty)
            module.start()
            module.start()
            XCTAssertEqual(module.snapshots.count, 2)
            XCTAssertEqual(secrets.readCount, 0)
            XCTAssertTrue(client.pending.isEmpty)
            module.stop()
            XCTAssertTrue(module.snapshots.isEmpty)
        }
    }

    @MainActor
    func testStopAndAccountChangesDiscardLateResultsAndCancelRequests() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.demoMode = false; $0.codexEnabled = true; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            XCTAssertEqual(client.pending.count, 1)
            let old = client.pending[0]
            module.preferences.update { $0.demoMode = true }
            settle()
            XCTAssertTrue(old.request.isCancelled)
            old.completion(.success(SubscriptionQuotaSnapshot(plan: "旧账号", windows: [], fetchedAt: Date())))
            settle()
            XCTAssertTrue(module.snapshots[.codex]?.plan?.contains("示例") == true)
            module.preferences.update { $0.demoMode = false }
            settle()
            let current = client.pending.last!
            module.stop()
            current.completion(.success(.demo(for: .codex)))
            settle()
            XCTAssertTrue(current.request.isCancelled)
            XCTAssertTrue(module.snapshots.isEmpty)
        }
    }

    @MainActor
    func testRefreshFailureRetainsLastSnapshotWithErrorAndPreventsOverlap() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.demoMode = false; $0.codexEnabled = true; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            module.refresh()
            XCTAssertEqual(client.pending.count, 1)
            let snapshot = SubscriptionQuotaSnapshot.demo(for: .codex)
            client.pending[0].completion(.success(snapshot))
            settle()
            module.refresh()
            client.pending[1].completion(.failure(.network))
            settle()
            XCTAssertEqual(module.snapshots[.codex], snapshot)
            XCTAssertEqual(module.errors[.codex], .network)
            XCTAssertTrue(module.refreshing.isEmpty)
        }
    }

    @MainActor
    func testGLMKeyUsesSecretStoreAndReplacementCancelsOldAccountOnlyOnce() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.demoMode = false }
            module.start()
            defer { module.stop() }
            XCTAssertTrue(module.saveGLMKey("test-only-not-a-real-key"))
            settle()
            XCTAssertEqual(client.pending.count, 1)
            XCTAssertEqual(secrets.key, "test-only-not-a-real-key")
            XCTAssertTrue(module.saveGLMKey("replacement-test-key"))
            settle()
            XCTAssertEqual(client.pending.count, 2)
            XCTAssertTrue(client.pending[0].request.isCancelled)
            XCTAssertFalse(module.saveGLMKey("invalid\nheader"))
            module.removeGLMKey()
            settle()
            XCTAssertNil(secrets.key)
            XCTAssertFalse(module.preferences.value.glmEnabled)
            XCTAssertTrue(client.pending[1].request.isCancelled)
        }
    }

    private func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchdeck-quota-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex-fixture")
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func assertFailure(_ result: Result<SubscriptionQuotaSnapshot, SubscriptionQuotaError>, _ expected: SubscriptionQuotaError,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else { return XCTFail("预期查询失败", file: file, line: line) }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    @MainActor
    private func withFixture(_ test: (SettingsStore, QuotaTestSecrets, QuotaTestClient) -> Void) {
        let suite = "com.notchdeck.quotas.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        test(SettingsStore(defaults: defaults), QuotaTestSecrets(), QuotaTestClient())
        let saved = defaults.data(forKey: "modules.preferences.subscriptions") ?? Data()
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("test-only-not-a-real-key"))
    }

    @MainActor
    private func settle() {
        let ready = expectation(description: "主队列完成配置与查询回调")
        DispatchQueue.main.async { DispatchQueue.main.async { ready.fulfill() } }
        wait(for: [ready], timeout: 1)
    }
}

private final class QuotaTestSecrets: SubscriptionSecretStore {
    var key: String?
    var readCount = 0
    func readGLMKey() throws -> String? { readCount += 1; return key }
    func saveGLMKey(_ key: String) throws { self.key = key }
    func removeGLMKey() throws { key = nil }
}

private final class QuotaTestClient {
    struct Pending { let request: SubscriptionQuotaRequest; let completion: SubscriptionQuotaCompletion }
    var pending: [Pending] = []
    var clients: SubscriptionQuotaClients { SubscriptionQuotaClients(glm: fetch, codex: fetch) }
    private func fetch(_ input: String, completion: @escaping SubscriptionQuotaCompletion) -> SubscriptionQuotaRequest {
        let request = SubscriptionQuotaRequest()
        pending.append(Pending(request: request, completion: completion))
        return request
    }
}

private final class QuotaURLProtocol: URLProtocol {
    static var response: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.response, let url = request.url else { return }
        let (status, body) = response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
