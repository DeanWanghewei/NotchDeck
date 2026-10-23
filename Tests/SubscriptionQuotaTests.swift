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
        [ "$1" = "app-server" ] || exit 6
        [ "$2" = "-c" ] || exit 6
        [ "$3" = 'cli_auth_credentials_store="file"' ] || exit 6
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
        let result = CodexQuotaQuery.read(executable: executable.path, cancellation: SubscriptionQuotaRequest(), timeout: 5)
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
        assertFailure(CodexQuotaQuery.read(executable: noisy.path, cancellation: SubscriptionQuotaRequest(), timeout: 5), .invalidResponse)
    }

    func testCodexTransportHandlesExitAndSanitizesAuthenticationError() throws {
        let executable = try script(#"""
        IFS= read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r query
        printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"token has expired; fixture credentials must not reach the UI"}}'
        while IFS= read -r line; do :; done
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        assertFailure(CodexQuotaQuery.read(executable: executable.path, cancellation: SubscriptionQuotaRequest(), timeout: 5), .signInRequired)
        assertFailure(CodexQuotaQuery.read(executable: "/usr/bin/false", cancellation: SubscriptionQuotaRequest(), timeout: 1), .invalidResponse)
    }

    func testLegacyAccountsMigrateWithoutReadingCredentialsAndRoundTripMetadata() throws {
        let old = Data(#"{"demoMode":false,"glmEnabled":true,"codexEnabled":true,"codexExecutable":"/usr/bin/true"}"#.utf8)
        let value = try JSONDecoder().decode(SubscriptionQuotaPreferences.self, from: old)
        XCTAssertEqual(value.accounts.map(\.id), [SubscriptionAccount.legacyGLMID, SubscriptionAccount.legacyCodexID])
        XCTAssertEqual(value.accounts.map(\.provider), [.glm, .codex])
        XCTAssertFalse(value.accounts[1].codexAuthStored)
        XCTAssertEqual(try JSONDecoder().decode(SubscriptionQuotaPreferences.self, from: JSONEncoder().encode(value)), value)
    }

    func testOptionalAliasesAndDuplicateNamesDoNotChangeAccountIdentity() throws {
        let one = SubscriptionAccount(provider: .glm)
        var two = SubscriptionAccount(provider: .glm, alias: "  工作  ")
        XCTAssertEqual(one.displayName(in: [one, two]), "GLM 账号 1")
        XCTAssertEqual(two.displayName(in: [one, two]), "工作")
        two.alias = " "
        XCTAssertEqual(two.displayName(in: [one, two]), "GLM 账号 2")
        var value = SubscriptionQuotaPreferences()
        value.accounts = [one, one, two]
        let loaded = try JSONDecoder().decode(SubscriptionQuotaPreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(loaded.accounts.map(\.id), [one.id, two.id])
    }

    func testAuthDocumentRejectsAPIKeysMalformedLargeAndMissingFiles() throws {
        XCTAssertEqual(try CodexAuthDocument.validate(authData()), authData())
        for data in [Data(), Data("invalid".utf8), Data(#"{"OPENAI_API_KEY":"fixture"}"#.utf8),
                     Data(#"{"tokens":{"access_token":""}}"#.utf8), Data(repeating: 32, count: CodexAuthDocument.maximumBytes + 1)] {
            XCTAssertThrowsError(try CodexAuthDocument.validate(data))
        }
        XCTAssertThrowsError(try CodexAuthDocument.load(path: "/tmp/notchdeck-missing-\(UUID())/auth.json")) {
            XCTAssertEqual($0 as? SubscriptionQuotaError, .authFileUnavailable)
        }
    }

    func testImportedAuthUsesPrivateHomePreservesSourceAndReturnsRotatedTokens() throws {
        let executable = try script(#"""
        test -n "$CODEX_HOME" || exit 21
        test "$(cd "$CODEX_HOME" && pwd -P)" = "$(pwd -P)" || exit 22
        test "$(stat -f%Lp "$CODEX_HOME")" = 700 || exit 23
        test "$(stat -f%Lp "$CODEX_HOME/auth.json")" = 600 || exit 24
        test -z "$OPENAI_API_KEY" || exit 25
        case "$*" in *'cli_auth_credentials_store="file"'*) ;; *) exit 26;; esac
        printf '%s' "$CODEX_HOME" > "$0.home"
        printf '%s' '{"tokens":{"access_token":"rotated-test-token"}}' > "$CODEX_HOME/auth.json"
        IFS= read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r query
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":41}}}}'
        while IFS= read -r line; do :; done
        """#)
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("account backup.json")
        try authData().write(to: source)
        let response = CodexQuotaQuery.query(CodexQuotaInput(executable: executable.path, auth: .file(source.path)),
                                             cancellation: SubscriptionQuotaRequest(), timeout: 5)
        XCTAssertEqual(try response.quota.get().windows.first?.usedPercent, 41)
        XCTAssertEqual(response.authJSON, authData("rotated-test-token"))
        XCTAssertEqual(try Data(contentsOf: source), authData())
        let privateHome = try String(contentsOfFile: executable.path + ".home", encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateHome))
        try FileManager.default.removeItem(at: source)
        let restored = CodexQuotaQuery.query(CodexQuotaInput(executable: executable.path, auth: .saved(response.authJSON!)),
                                             cancellation: SubscriptionQuotaRequest(), timeout: 5)
        XCTAssertEqual(try restored.quota.get().windows.first?.usedPercent, 41)
    }

    @MainActor
    func testDefaultDemoAndDisabledLifecycleNeverTouchCredentialsOrNetwork() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.refresh()
            XCTAssertTrue(module.snapshots.isEmpty)
            module.start()
            module.start()
            XCTAssertEqual(module.snapshots.count, 4)
            XCTAssertEqual(module.displayedAccounts.filter { $0.provider == .glm }.count, 2)
            XCTAssertEqual(module.displayedAccounts.filter { $0.provider == .codex }.count, 2)
            XCTAssertEqual(secrets.readCount, 0)
            XCTAssertEqual(client.count, 0)
            module.stop()
            XCTAssertTrue(module.snapshots.isEmpty)
        }
    }

    @MainActor
    func testMultipleAccountsHaveIndependentQueriesAndBoundedConcurrency() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let glm = [SubscriptionAccount(provider: .glm), SubscriptionAccount(provider: .glm)]
            let codex = [SubscriptionAccount(provider: .codex), SubscriptionAccount(provider: .codex)]
            secrets.keys = [glm[0].id: "test-first-key", glm[1].id: "test-second-key"]
            module.preferences.update { $0.demoMode = false; $0.accounts = glm + codex; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            XCTAssertEqual(client.glm.map(\.key), ["test-first-key", "test-second-key"])
            XCTAssertEqual(client.codex.count, 1)
            XCTAssertEqual(module.refreshing.count, 4)
            module.refresh()
            XCTAssertEqual(client.count, 3)
            client.glm[0].completion(.success(.demo(for: .glm)))
            settle()
            XCTAssertEqual(client.codex.count, 2)
            client.glm[1].completion(.failure(.signInRequired))
            client.codex[0].completion(CodexQuotaResult(quota: .success(.demo(for: .codex))))
            settle()
            XCTAssertNotNil(module.snapshots[glm[0].id])
            XCTAssertNotNil(module.snapshots[codex[0].id])
            XCTAssertEqual(module.errors[glm[1].id], .signInRequired)
            XCTAssertNil(module.errors[codex[0].id])
        }
    }

    @MainActor
    func testAliasesDoNotRestartQueriesAndFailureKeepsOnlyThatAccountsSnapshot() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let account = SubscriptionAccount(provider: .codex)
            module.preferences.update { $0.demoMode = false; $0.accounts = [account]; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            module.preferences.update { $0.accounts[0].alias = "工作" }
            settle()
            XCTAssertEqual(client.count, 1)
            XCTAssertFalse(client.codex[0].request.isCancelled)
            let snapshot = SubscriptionQuotaSnapshot.demo(for: .codex)
            client.codex[0].completion(CodexQuotaResult(quota: .success(snapshot)))
            settle()
            module.refresh()
            client.codex[1].completion(CodexQuotaResult(quota: .failure(.network)))
            settle()
            XCTAssertEqual(module.snapshots[account.id], snapshot)
            XCTAssertEqual(module.errors[account.id], .network)
            XCTAssertTrue(module.refreshing.isEmpty)
        }
    }

    @MainActor
    func testRemovalDisablingAndStopDiscardLateAccountResults() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let accounts = [SubscriptionAccount(provider: .glm), SubscriptionAccount(provider: .glm)]
            secrets.keys = [accounts[0].id: "test-one", accounts[1].id: "test-two"]
            module.preferences.update { $0.demoMode = false; $0.accounts = accounts }
            module.start()
            module.removeAccount(accounts[0].id)
            XCTAssertNil(secrets.keys[accounts[0].id])
            XCTAssertEqual(secrets.keys[accounts[1].id], "test-two")
            module.preferences.update { $0.accounts[0].enabled = false }
            settle()
            XCTAssertTrue(client.glm.allSatisfy { $0.request.isCancelled })
            client.glm.forEach { $0.completion(.success(.demo(for: .glm))) }
            settle()
            XCTAssertTrue(module.snapshots.isEmpty)
            module.preferences.update { $0.accounts[0].enabled = true }
            settle()
            let current = client.glm.last!
            module.stop()
            current.completion(.success(.demo(for: .glm)))
            settle()
            XCTAssertTrue(current.request.isCancelled)
            XCTAssertTrue(module.snapshots.isEmpty)
        }
    }

    @MainActor
    func testGLMReplacementOnlyCancelsSelectedAccountAndNeverStoresKeysInPreferences() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.demoMode = false }
            module.start()
            defer { module.stop() }
            let one = SubscriptionAccount(provider: .glm), two = SubscriptionAccount(provider: .glm)
            XCTAssertTrue(module.saveGLMAccount(one, key: "test-only-not-a-real-key"))
            XCTAssertTrue(module.saveGLMAccount(two, key: "test-second-key"))
            settle()
            XCTAssertEqual(client.glm.count, 2)
            XCTAssertTrue(module.saveGLMAccount(one, key: "replacement-test-key"))
            settle()
            XCTAssertEqual(client.glm.count, 3)
            XCTAssertTrue(client.glm[0].request.isCancelled)
            XCTAssertFalse(client.glm[1].request.isCancelled)
            XCTAssertFalse(module.saveGLMAccount(one, key: "invalid\nheader"))
            XCTAssertEqual(secrets.keys[one.id], "replacement-test-key")
        }
    }

    @MainActor
    func testCodexImportValidatesBeforeSavingAndRestoresWithoutSourceFile() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.demoMode = false; $0.codexExecutable = "/usr/bin/true" }
            let account = SubscriptionAccount(provider: .codex, alias: "工作")
            var saved: Bool?
            module.saveCodexAccount(account, authPath: "/tmp/account auth.json") { saved = $0 }
            XCTAssertTrue(module.verifying)
            XCTAssertTrue(module.preferences.value.accounts.isEmpty)
            XCTAssertTrue(secrets.auth.isEmpty)
            if case .file(let path) = client.codex[0].input.auth { XCTAssertEqual(path, "/tmp/account auth.json") }
            else { XCTFail("导入必须验证指定文件") }
            client.codex[0].completion(CodexQuotaResult(quota: .success(.demo(for: .codex)), authJSON: authData()))
            settle()
            XCTAssertEqual(saved, true)
            XCTAssertEqual(secrets.auth[account.id], authData())
            XCTAssertTrue(module.preferences.value.accounts[0].codexAuthStored)
            module.start()
            module.stop()
            let restored = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            restored.start()
            defer { restored.stop() }
            if case .saved(let data) = client.codex.last!.input.auth { XCTAssertEqual(data, authData()) }
            else { XCTFail("重启后应使用独立保存的登录") }
            XCTAssertEqual(restored.preferences.value.accounts[0].alias, "工作")
        }
    }

    @MainActor
    func testFailedOrCancelledCodexImportDoesNotReplaceSavedAccount() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let account = SubscriptionAccount(provider: .codex, alias: "旧账号", codexAuthStored: true)
            secrets.auth[account.id] = authData()
            module.preferences.update { $0.codexExecutable = "/usr/bin/true"; $0.accounts = [account] }
            var replacement = account
            replacement.alias = "新账号"
            var saved: Bool?
            module.saveCodexAccount(replacement, authPath: "/tmp/new.json") { saved = $0 }
            client.codex[0].completion(CodexQuotaResult(quota: .failure(.signInRequired), authJSON: authData("invalid-login")))
            settle()
            XCTAssertEqual(saved, false)
            XCTAssertEqual(secrets.auth[account.id], authData())
            XCTAssertEqual(module.preferences.value.accounts, [account])
            module.saveCodexAccount(replacement, authPath: "/tmp/new.json") { saved = $0 }
            module.cancelAccountVerification()
            client.codex[1].completion(CodexQuotaResult(quota: .success(.demo(for: .codex)), authJSON: authData("new-login")))
            settle()
            XCTAssertTrue(client.codex[1].request.isCancelled)
            XCTAssertEqual(secrets.auth[account.id], authData())
            XCTAssertEqual(module.preferences.value.accounts, [account])
        }
    }

    @MainActor
    func testRefreshedCodexLoginIsPersistedEvenWhenQuotaFailsAndNeverFallsBackToCurrentLogin() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let account = SubscriptionAccount(provider: .codex, codexAuthStored: true)
            secrets.auth[account.id] = authData()
            module.preferences.update { $0.demoMode = false; $0.accounts = [account]; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            client.codex[0].completion(CodexQuotaResult(quota: .failure(.network), authJSON: authData("rotated-token")))
            settle()
            XCTAssertEqual(secrets.auth[account.id], authData("rotated-token"))
            module.refresh()
            if case .saved(let data) = client.codex[1].input.auth { XCTAssertEqual(data, authData("rotated-token")) }
            else { XCTFail("不得回退到本机当前登录") }
            module.stop()
            secrets.auth.removeAll()
            module.start()
            settle()
            XCTAssertEqual(module.errors[account.id], .signInRequired)
            XCTAssertEqual(client.codex.count, 2)
        }
    }

    @MainActor
    func testSwitchingDemoModeCancelsQueriesAndRejectsStaleCredentials() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let account = SubscriptionAccount(provider: .codex, codexAuthStored: true)
            secrets.auth[account.id] = authData()
            module.preferences.update { $0.demoMode = false; $0.accounts = [account]; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            module.preferences.update { $0.demoMode = true }
            settle()
            client.codex[0].completion(CodexQuotaResult(quota: .success(.demo(for: .codex)), authJSON: authData("stale-token")))
            settle()
            XCTAssertTrue(client.codex[0].request.isCancelled)
            XCTAssertEqual(module.snapshots.count, 4)
            XCTAssertEqual(secrets.auth[account.id], authData())
        }
    }

    @MainActor
    func testTwoImportedCodexAccountsStayIndependentAcrossCLIChanges() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.demoMode = false; $0.codexExecutable = "/usr/bin/true" }
            let accounts = [SubscriptionAccount(provider: .codex, alias: "相同别名"), SubscriptionAccount(provider: .codex, alias: "相同别名")]
            for (index, account) in accounts.enumerated() {
                module.saveCodexAccount(account, authPath: "/tmp/fixture-\(index).json") { XCTAssertTrue($0) }
                client.codex[index].completion(CodexQuotaResult(quota: .success(.demo(for: .codex)), authJSON: authData("account-\(index)-test-token")))
                settle()
            }
            module.start()
            defer { module.stop() }
            XCTAssertEqual(client.codex.count, 4)
            module.preferences.update { $0.codexExecutable = "/usr/bin/false" }
            settle()
            XCTAssertEqual(client.codex.count, 6)
            XCTAssertTrue(client.codex[2].request.isCancelled)
            XCTAssertTrue(client.codex[3].request.isCancelled)
            for (index, pending) in client.codex.suffix(2).enumerated() {
                if case .saved(let data) = pending.input.auth { XCTAssertEqual(data, authData("account-\(index)-test-token")) }
                else { XCTFail("CLI 路径改变不得改变已保存的账号登录") }
            }
            XCTAssertEqual(module.preferences.value.accounts.map(\.id), accounts.map(\.id))
            XCTAssertEqual(secrets.auth.count, 2)
        }
    }

    @MainActor
    func testCodexStorageSaveFailureDoesNotReportSuccessfulImport() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.codexExecutable = "/usr/bin/true" }
            secrets.failCodexSave = true
            var saved: Bool?
            module.saveCodexAccount(SubscriptionAccount(provider: .codex), authPath: "/tmp/fixture.json") { saved = $0 }
            client.codex[0].completion(CodexQuotaResult(quota: .success(.demo(for: .codex)), authJSON: authData()))
            settle()
            XCTAssertEqual(saved, false)
            XCTAssertTrue(module.preferences.value.accounts.isEmpty)
            XCTAssertTrue(secrets.auth.isEmpty)
            XCTAssertFalse(module.verifying)
            XCTAssertNotNil(module.settingsMessage)
        }
    }

    private func authData(_ token: String = "synthetic-test-token") -> Data {
        Data("{\"tokens\":{\"access_token\":\"\(token)\"}}".utf8)
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
        for secret in ["test-only-not-a-real-key", "replacement-test-key", "synthetic-test-token", "rotated-token"] {
            XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(secret))
        }
    }

    @MainActor
    private func settle() {
        let ready = expectation(description: "主队列完成配置与查询回调")
        DispatchQueue.main.async { DispatchQueue.main.async { DispatchQueue.main.async { DispatchQueue.main.async { ready.fulfill() } } } }
        wait(for: [ready], timeout: 1)
    }
}

private final class QuotaTestSecrets: SubscriptionSecretStore {
    var keys: [String: String] = [:]
    var auth: [String: Data] = [:]
    var readCount = 0
    var failCodexSave = false
    func readGLMKey(accountID: String) throws -> String? { readCount += 1; return keys[accountID] }
    func saveGLMKey(_ key: String, accountID: String) throws { keys[accountID] = key }
    func removeGLMKey(accountID: String) throws { keys.removeValue(forKey: accountID) }
    func readCodexAuth(accountID: String) throws -> Data? { readCount += 1; return auth[accountID] }
    func saveCodexAuth(_ data: Data, accountID: String) throws {
        if failCodexSave { throw SubscriptionQuotaError.credentialStorage }
        auth[accountID] = data
    }
    func removeCodexAuth(accountID: String) throws { auth.removeValue(forKey: accountID) }
}

private final class QuotaTestClient {
    struct GLM { let key: String; let request: SubscriptionQuotaRequest; let completion: SubscriptionQuotaCompletion }
    struct Codex { let input: CodexQuotaInput; let request: SubscriptionQuotaRequest; let completion: CodexQuotaCompletion }
    var glm: [GLM] = []
    var codex: [Codex] = []
    var count: Int { glm.count + codex.count }
    var clients: SubscriptionQuotaClients {
        SubscriptionQuotaClients(glm: { key, completion in
            let request = SubscriptionQuotaRequest()
            self.glm.append(GLM(key: key, request: request, completion: completion))
            return request
        }, codex: { input, completion in
            let request = SubscriptionQuotaRequest()
            self.codex.append(Codex(input: input, request: request, completion: completion))
            return request
        })
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
