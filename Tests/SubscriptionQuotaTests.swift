import Foundation
import XCTest
import SwiftUI
import AppKit

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

    func testGLMDistinguishesWindowsAndOnlyRemovesExactDuplicates() throws {
        let data = Data(#"{"limits":[{"type":"TOKENS_LIMIT","percentage":28,"unit":3,"number":5},{"type":"TOKENS_LIMIT","percentage":28,"unit":3,"number":5},{"type":"TOKENS_LIMIT","percentage":28,"unit":6,"number":1},{"type":"TIME_LIMIT","percentage":12}]}"#.utf8)
        let result = try SubscriptionQuotaParser.glm(data)
        XCTAssertEqual(result.windows.map(\.title), ["5 小时", "每周", "工具调用"])
        XCTAssertEqual(result.windows.map(\.usedPercent), [28, 28, 12])
        let reverse = Data(#"{"limits":[{"type":"TOKENS_LIMIT","percentage":73,"unit":6,"number":1},{"type":"TOKENS_LIMIT","percentage":12,"unit":3,"number":5}]}"#.utf8)
        let reversed = try SubscriptionQuotaParser.glm(reverse)
        XCTAssertEqual(reversed.windows.map(\.title), ["每周", "5 小时"])
        XCTAssertEqual(reversed.windows.map(\.usedPercent), [73, 12])
        let unknown = Data(#"{"limits":[{"type":"TOKENS_LIMIT","percentage":28,"future":"a"},{"type":"TOKENS_LIMIT","percentage":28,"future":"b"}]}"#.utf8)
        XCTAssertEqual(try SubscriptionQuotaParser.glm(unknown).windows.count, 2)
    }

    func testGLMReadsResetTimeFromConfirmedEndpointForms() throws {
        // 形态样本取自公开实现（zai-org/ZCode、Raycast agent-usage、zai-rs）的真实响应：
        // epoch 毫秒数字、RFC3339 字符串、数字字符串（按秒计）。
        let data = Data(#"{"limits":[{"type":"TOKENS_LIMIT","percentage":28,"unit":3,"number":5,"nextResetTime":1781778751996},{"type":"TOKENS_LIMIT","percentage":60,"unit":6,"number":1,"nextResetTime":"2026-06-22T00:00:00Z"},{"type":"TIME_LIMIT","percentage":12,"nextResetTime":"1781778751.996"}]}"#.utf8)
        let snapshot = try SubscriptionQuotaParser.glm(data)
        XCTAssertEqual(snapshot.windows.map(\.title), ["5 小时", "每周", "工具调用"])
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_781_778_751.996))
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1_782_086_400))
        XCTAssertEqual(snapshot.windows[2].resetsAt, Date(timeIntervalSince1970: 1_781_778_751.996))
    }

    func testGLMIgnoresUnusableResetTimeValuesWithoutDroppingWindows() throws {
        for value in ["null", "0", "-5", "1e300", "true", #""abc""#, #""2026-13-99T99:99:99Z""#, #""""#] {
            let data = Data(#"{"limits":[{"type":"TOKENS_LIMIT","percentage":28,"unit":3,"number":5,"nextResetTime":\#(value)}]}"#.utf8)
            let snapshot = try SubscriptionQuotaParser.glm(data)
            XCTAssertEqual(snapshot.windows.count, 1)
            XCTAssertNil(snapshot.windows[0].resetsAt, "值 \(value) 不应产生重置时间")
        }
    }

    func testGLMDuplicateRemovalKeepsResetTimeAlignedToFirstEntry() throws {
        let duplicate = #"{"type":"TIME_LIMIT","percentage":12,"nextResetTime":1781778751996}"#
        let data = Data(#"{"limits":[{"type":"TOKENS_LIMIT","percentage":28},{"type":"TOKENS_LIMIT","percentage":28},\#(duplicate),\#(duplicate)]}"#.utf8)
        let snapshot = try SubscriptionQuotaParser.glm(data)
        XCTAssertEqual(snapshot.windows.map(\.title), ["编码额度", "工具调用"])
        XCTAssertNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1_781_778_751.996))
    }

    func testRemainingDurationUsesMinuteGranularity() {
        let now = Date(timeIntervalSince1970: 1_782_086_400)
        func window(seconds: TimeInterval) -> SubscriptionQuotaWindow {
            SubscriptionQuotaWindow(id: "w", title: "5 小时", usedPercent: 28,
                                    resetsAt: seconds == 0 ? nil : now.addingTimeInterval(seconds))
        }
        XCTAssertNil(window(seconds: -30).remainingDuration(now: now))
        XCTAssertEqual(window(seconds: 15).remainingDuration(now: now), "1 分钟")
        XCTAssertEqual(window(seconds: 59 * 60 + 59).remainingDuration(now: now), "59 分钟")
        XCTAssertEqual(window(seconds: 3600).remainingDuration(now: now), "1 小时")
        XCTAssertEqual(window(seconds: 2 * 3600 + 5 * 60).remainingDuration(now: now), "2 小时 5 分钟")
        XCTAssertEqual(window(seconds: 2 * 86_400).remainingDuration(now: now), "2 天")
        XCTAssertEqual(window(seconds: 2 * 86_400 + 3 * 3600 + 17 * 60).remainingDuration(now: now), "2 天 3 小时")
        XCTAssertNil(window(seconds: 0).remainingDuration(now: now))
    }

    func testResetDescriptionCombinesRemainingAndAbsoluteMoment() {
        let now = Date(timeIntervalSince1970: 1_782_086_400)
        let today = SubscriptionQuotaWindow(id: "w", title: "5 小时", usedPercent: 28,
                                            resetsAt: now.addingTimeInterval(3300))
        let line = today.resetDescription(now: now)
        XCTAssertTrue(line.hasPrefix("还剩 55 分钟 · "))
        XCTAssertTrue(line.hasSuffix(" 重置"))
        let crossDay = SubscriptionQuotaWindow(id: "w", title: "每周", usedPercent: 38,
                                               resetsAt: now.addingTimeInterval(2 * 86_400 + 3600))
        XCTAssertTrue(crossDay.resetDescription(now: now).hasPrefix("还剩 2 天 1 小时 · "))
        XCTAssertEqual(SubscriptionQuotaWindow(id: "w", title: "每周", usedPercent: 38,
                                               resetsAt: now.addingTimeInterval(-1))
            .resetDescription(now: now), "周期已到，等待刷新")
        XCTAssertEqual(SubscriptionQuotaWindow(id: "w", title: "每周", usedPercent: 38, resetsAt: nil)
            .resetDescription(now: now), "服务未提供重置时间")
    }

    func testResetHelpDescriptionKeepsAbsoluteMoment() {
        let now = Date(timeIntervalSince1970: 1_782_086_400)
        let window = SubscriptionQuotaWindow(id: "w", title: "每周", usedPercent: 38, resetsAt: now.addingTimeInterval(3300))
        XCTAssertTrue(window.resetHelpDescription(now: now).hasPrefix("还剩 55 分钟，重置于 "))
        let expired = SubscriptionQuotaWindow(id: "w", title: "每周", usedPercent: 38, resetsAt: now.addingTimeInterval(-1))
        XCTAssertEqual(expired.resetHelpDescription(now: now), "周期已到，等待刷新")
        let missing = SubscriptionQuotaWindow(id: "w", title: "每周", usedPercent: 38, resetsAt: nil)
        XCTAssertEqual(missing.resetHelpDescription(now: now), "服务未提供重置时间")
    }

    func testPastedJSONErrorsAreSpecificAndDoNotExposeCredentials() throws {
        let cases: [(String, SubscriptionQuotaError)] = [
            ("/tmp/auth.json", .invalidAuthJSON),
            ("{broken", .invalidAuthJSON),
            (#"{"tokens":{}}"#, .missingAuthToken),
            (#"{"tokens":{"access_token":"  "}}"#, .missingAuthToken),
            (#"{"auth_mode":"apikey","OPENAI_API_KEY":"secret"}"#, .unsupportedAuthMode),
            (String(repeating: "x", count: 256 * 1024 + 1), .authJSONTooLarge)
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try CodexAuthDocument.parsePastedJSON(text)) { error in
                XCTAssertEqual(error as? SubscriptionQuotaError, expected)
                XCTAssertFalse(expected.message(for: .codex).contains("secret"))
            }
        }
        XCTAssertEqual(try CodexAuthDocument.parsePastedJSON(String(decoding: authData(), as: UTF8.self)), authData())
    }

    @MainActor
    func testInvalidPastedJSONDoesNotStartQueryOrReplaceSavedAccount() {
        withFixture { settings, secrets, client in
            let account = SubscriptionAccount(provider: .codex)
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            var saved: Bool?
            module.saveCodexAccount(account, authJSON: "{bad") { saved = $0 }
            XCTAssertEqual(saved, false)
            XCTAssertTrue(client.codex.isEmpty)
            XCTAssertTrue(secrets.auth.isEmpty)
            XCTAssertFalse(module.verifying)
            XCTAssertTrue(module.settingsMessage?.contains("JSON 格式错误") == true)
        }
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
    func testEmptyAndDisabledLifecycleNeverTouchCredentialsOrNetwork() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.refresh()
            XCTAssertTrue(module.snapshots.isEmpty)
            module.start()
            module.start()
            XCTAssertTrue(module.snapshots.isEmpty)
            XCTAssertEqual(module.displayedAccounts.filter { $0.provider == .glm }.count, 0)
            XCTAssertEqual(module.displayedAccounts.filter { $0.provider == .codex }.count, 0)
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
            module.preferences.update { $0.accounts = glm + codex; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            XCTAssertEqual(client.glm.map(\.key), ["test-first-key", "test-second-key"])
            XCTAssertEqual(client.codex.count, 1)
            XCTAssertEqual(module.refreshing.count, 4)
            module.refresh()
            XCTAssertEqual(client.count, 3)
            client.glm[0].completion(.success(.fixture(for: .glm)))
            settle()
            XCTAssertEqual(client.codex.count, 2)
            client.glm[1].completion(.failure(.signInRequired))
            client.codex[0].completion(CodexQuotaResult(quota: .success(.fixture(for: .codex))))
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
            module.preferences.update { $0.accounts = [account]; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            module.preferences.update { $0.accounts[0].alias = "工作" }
            settle()
            XCTAssertEqual(client.count, 1)
            XCTAssertFalse(client.codex[0].request.isCancelled)
            let snapshot = SubscriptionQuotaSnapshot.fixture(for: .codex)
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
            module.preferences.update { $0.accounts = accounts }
            module.start()
            module.removeAccount(accounts[0].id)
            XCTAssertNil(secrets.keys[accounts[0].id])
            XCTAssertEqual(secrets.keys[accounts[1].id], "test-two")
            module.preferences.update { $0.accounts[0].enabled = false }
            settle()
            XCTAssertTrue(client.glm.allSatisfy { $0.request.isCancelled })
            client.glm.forEach { $0.completion(.success(.fixture(for: .glm))) }
            settle()
            XCTAssertTrue(module.snapshots.isEmpty)
            module.preferences.update { $0.accounts[0].enabled = true }
            settle()
            let current = client.glm.last!
            module.stop()
            current.completion(.success(.fixture(for: .glm)))
            settle()
            XCTAssertTrue(current.request.isCancelled)
            XCTAssertTrue(module.snapshots.isEmpty)
        }
    }

    @MainActor
    func testGLMReplacementOnlyCancelsSelectedAccountAndNeverStoresKeysInPreferences() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
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
            module.preferences.update { $0.codexExecutable = "/usr/bin/true" }
            let account = SubscriptionAccount(provider: .codex, alias: "工作")
            var saved: Bool?
            module.saveCodexAccount(account, authJSON: String(decoding: authData(), as: UTF8.self)) { saved = $0 }
            XCTAssertTrue(module.verifying)
            XCTAssertTrue(module.preferences.value.accounts.isEmpty)
            XCTAssertTrue(secrets.auth.isEmpty)
            if case .saved(let data) = client.codex[0].input.auth { XCTAssertEqual(data, authData()) }
            else { XCTFail("导入必须验证指定文件") }
            client.codex[0].completion(CodexQuotaResult(quota: .success(.fixture(for: .codex)), authJSON: authData()))
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
            module.saveCodexAccount(replacement, authJSON: String(decoding: authData(), as: UTF8.self)) { saved = $0 }
            client.codex[0].completion(CodexQuotaResult(quota: .failure(.signInRequired), authJSON: authData("invalid-login")))
            settle()
            XCTAssertEqual(saved, false)
            XCTAssertEqual(secrets.auth[account.id], authData())
            XCTAssertEqual(module.preferences.value.accounts, [account])
            module.saveCodexAccount(replacement, authJSON: String(decoding: authData(), as: UTF8.self)) { saved = $0 }
            module.cancelAccountVerification()
            client.codex[1].completion(CodexQuotaResult(quota: .success(.fixture(for: .codex)), authJSON: authData("new-login")))
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
            module.preferences.update { $0.accounts = [account]; $0.codexExecutable = "/usr/bin/true" }
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
    func testDisablingAccountCancelsQueriesAndRejectsStaleCredentials() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let account = SubscriptionAccount(provider: .codex, codexAuthStored: true)
            secrets.auth[account.id] = authData()
            module.preferences.update { $0.accounts = [account]; $0.codexExecutable = "/usr/bin/true" }
            module.start()
            defer { module.stop() }
            module.preferences.update { $0.accounts[0].enabled = false }
            settle()
            client.codex[0].completion(CodexQuotaResult(quota: .success(.fixture(for: .codex)), authJSON: authData("stale-token")))
            settle()
            XCTAssertTrue(client.codex[0].request.isCancelled)
            XCTAssertTrue(module.snapshots.isEmpty)
            XCTAssertEqual(secrets.auth[account.id], authData())
        }
    }

    @MainActor
    func testTwoImportedCodexAccountsStayIndependentAcrossCLIChanges() {
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            module.preferences.update { $0.codexExecutable = "/usr/bin/true" }
            let accounts = [SubscriptionAccount(provider: .codex, alias: "相同别名"), SubscriptionAccount(provider: .codex, alias: "相同别名")]
            for (index, account) in accounts.enumerated() {
                module.saveCodexAccount(account, authJSON: String(decoding: authData(), as: UTF8.self)) { XCTAssertTrue($0) }
                client.codex[index].completion(CodexQuotaResult(quota: .success(.fixture(for: .codex)), authJSON: authData("account-\(index)-test-token")))
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
            module.saveCodexAccount(SubscriptionAccount(provider: .codex), authJSON: String(decoding: authData(), as: UTF8.self)) { saved = $0 }
            client.codex[0].completion(CodexQuotaResult(quota: .success(.fixture(for: .codex)), authJSON: authData()))
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

    func testNotificationPreferenceMigrationAndThresholdBounds() throws {
        for (raw, expected) in [("{}", 100), (#"{"demoMode":true,"notificationThreshold":150}"#, 100), (#"{"notificationThreshold":0}"#, 1)] {
            let value = try JSONDecoder().decode(SubscriptionQuotaPreferences.self, from: Data(raw.utf8))
            XCTAssertFalse(value.notificationsEnabled)
            XCTAssertEqual(value.notificationThreshold, expected)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("demoMode"))
        }
    }

    @MainActor
    func testQuotaNotificationsUseSharedChannelAndDeduplicateSuccessfulSamples() {
        withFixture { settings, secrets, client in
            let notifications = QuotaTestNotifications()
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets, notifications: notifications)
            let accounts = [SubscriptionAccount(provider: .glm, alias: "个人"), SubscriptionAccount(provider: .glm, alias: "工作")]
            accounts.forEach { secrets.keys[$0.id] = "test-only-not-a-real-key" }
            module.preferences.update { $0.accounts = accounts }
            module.start()
            defer { module.stop() }
            let reset = Date().addingTimeInterval(3600)
            func snapshot(_ value: Double, _ cycle: Date? = nil) -> SubscriptionQuotaSnapshot {
                .init(plan: nil, windows: [.init(id: "weekly", title: "每周", usedPercent: value, resetsAt: cycle ?? reset)], fetchedAt: Date())
            }
            client.glm.forEach { $0.completion(.success(snapshot(100))) }
            settle()
            XCTAssertTrue(notifications.messages.isEmpty)
            module.preferences.update { $0.notificationsEnabled = true }
            settle()
            XCTAssertEqual(notifications.messages.count, 2)
            XCTAssertTrue(notifications.messages[0].body.contains("100%"))
            module.refresh()
            client.glm.suffix(2).forEach { $0.completion(.success(snapshot(105))) }
            settle()
            XCTAssertEqual(notifications.messages.count, 2)
            module.preferences.update { $0.notificationThreshold = 80 }
            settle()
            XCTAssertEqual(notifications.messages.count, 4)
            notifications.delivered = false
            module.refresh()
            client.glm.suffix(2).forEach { $0.completion(.success(snapshot(90, reset.addingTimeInterval(3600)))) }
            settle()
            XCTAssertEqual(notifications.messages.count, 6)
            notifications.delivered = true
            module.refresh()
            client.glm.suffix(2).forEach { $0.completion(.success(snapshot(90, reset.addingTimeInterval(3600)))) }
            settle()
            XCTAssertEqual(notifications.messages.count, 8)
            module.refresh()
            client.glm.suffix(2).forEach { $0.completion(.failure(.network)) }
            settle()
            XCTAssertEqual(notifications.messages.count, 8)
            module.stop()
            module.refresh()
            XCTAssertEqual(notifications.messages.count, 8)
        }
    }

    func testGLMRingLayersFollowPeriodsRegardlessOfResponseOrder() {
        let windows: [SubscriptionQuotaWindow] = [
            .init(id: "tool", title: "工具调用", usedPercent: 100, resetsAt: nil),
            .init(id: "unknown", title: "编码额度", usedPercent: 105, resetsAt: nil),
            .init(id: "weekly", title: "每周", usedPercent: 42, resetsAt: nil),
            .init(id: "short", title: "5 小时", usedPercent: 0, resetsAt: nil),
        ]
        let ordered = SubscriptionQuotaView.orderedGLMWindows(windows)
        XCTAssertEqual(ordered.map(\.id), ["short", "weekly", "tool", "unknown"])
        XCTAssertEqual(SubscriptionQuotaView.orderedGLMWindows(windows.reversed()), ordered)
        XCTAssertEqual(ordered.map(\.usedPercent), [0, 42, 100, 105])
        XCTAssertEqual(SubscriptionQuotaView.orderedGLMWindows([]), [])
    }

    func testAccountRowsPairOnlySameProvidersAndKeepOddAccounts() {
        let accounts = [SubscriptionAccount(id: "c1", provider: .codex),
                        SubscriptionAccount(id: "g1", provider: .glm),
                        SubscriptionAccount(id: "c2", provider: .codex),
                        SubscriptionAccount(id: "g2", provider: .glm),
                        SubscriptionAccount(id: "g3", provider: .glm)]
        XCTAssertEqual(SubscriptionQuotaView.accountRows(accounts).map { $0.map(\.id) },
                       [["c1", "c2"], ["g1", "g2"], ["g3"]])
        XCTAssertTrue(SubscriptionQuotaView.accountRows([]).isEmpty)
    }

    @MainActor
    func testRenderSubscriptionViewsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        withFixture { settings, secrets, client in
            let module = SubscriptionQuotaModule(settings: settings, clients: client.clients, secrets: secrets)
            let accounts = [SubscriptionAccount(provider: .glm, alias: "个人订阅"), SubscriptionAccount(provider: .glm, alias: "工作订阅")]
            accounts.forEach { secrets.keys[$0.id] = "test-only-not-a-real-key" }
            module.preferences.update { $0.accounts = accounts }
            module.start()
            defer { module.stop() }
            let snapshot = SubscriptionQuotaSnapshot(plan: "Pro", windows: [
                .init(id: "short", title: "5 小时", usedPercent: 100,
                      resetsAt: Date().addingTimeInterval(3600)),
                .init(id: "weekly", title: "每周", usedPercent: 38,
                      resetsAt: Date().addingTimeInterval(2 * 86_400 + 3 * 3600)),
                .init(id: "extra", title: "工具调用", usedPercent: 0, resetsAt: Date().addingTimeInterval(-60)),
            ], fetchedAt: Date())
            client.glm.forEach { $0.completion(.success(snapshot)) }
            settle()
            for dark in [false, true] {
                for mode in ["cards", "rings", "rings-narrow", "compact", "settings"] {
                    let renderWidth: CGFloat = mode == "rings-narrow" ? 360 : 480
                    let view: AnyView = mode == "settings" ?
                        AnyView(Form { SubscriptionQuotaSettingsView(module: module, preferences: module.preferences) }.formStyle(.grouped)) :
                        AnyView(SubscriptionQuotaView(module: module, preferences: module.preferences)
                            .environment(\.modulePresentation, .init(placement: .tab, displayModeID: mode == "rings-narrow" ? "rings" : mode)))
                    let host = NSHostingView(rootView: view.padding(16).frame(width: renderWidth, height: 540, alignment: .topLeading)
                        .background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: renderWidth, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    // 屏幕外呈现窗口，让 onAppear 与有限动画完成后再缓存，避免截到初始透明帧。
                    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                    window.orderFront(nil)
                    let rendered = expectation(description: "等待入场动画完成")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { rendered.fulfill() }
                    wait(for: [rendered], timeout: 2)
                    host.layoutSubtreeIfNeeded()
                    defer { window.orderOut(nil) }
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("无法渲染"); continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let path = directory + "/subscriptions-" + mode + (dark ? "-dark.png" : "-light.png")
                    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                    catch { XCTFail("截图写入失败：\(error)") }
                }
            }
        }
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

private extension SubscriptionQuotaSnapshot {
    static func fixture(for provider: SubscriptionProvider, now: Date = Date()) -> Self {
        Self(plan: provider == .glm ? "Pro · 示例" : "Plus · 示例", windows: [
            SubscriptionQuotaWindow(id: "short", title: "5 小时", usedPercent: provider == .glm ? 32 : 68,
                resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
            SubscriptionQuotaWindow(id: "weekly", title: "每周", usedPercent: provider == .glm ? 57 : 24,
                resetsAt: now.addingTimeInterval(3 * 86400 + 3600)),
        ], fetchedAt: now)
    }
}

private final class QuotaTestNotifications: AppNotificationSending {
    var messages: [AppNotification] = []
    var delivered = true
    func send(_ notification: AppNotification, completion: @escaping (Bool) -> Void) {
        messages.append(notification)
        completion(delivered)
    }
}
