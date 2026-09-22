import Carbon.HIToolbox
import Combine
import Darwin
import SwiftUI
import XCTest

final class ShellTests: XCTestCase {
    func testExitStatusStderrAndEmptySuccess() {
        let result = Shell.execute("/bin/sh", arguments: ["-c", "printf out; printf problem >&2; exit 7"])
        XCTAssertEqual(result.completion, .exited(7))
        XCTAssertEqual(result.output, "out")
        XCTAssertEqual(result.errorOutput, "problem")
        XCTAssertEqual(Shell.run("/usr/bin/true", arguments: []), "")
        XCTAssertNil(Shell.run("/usr/bin/false", arguments: []))
    }

    func testHardTimeoutKillsUncooperativeProcessGroup() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = Shell.execute("/bin/sh", arguments: ["-c",
            "trap '' TERM; /bin/sleep 20 & child=$!; printf '%s' \"$child\"; wait"], timeout: 0.25)
        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let child = try XCTUnwrap(pid_t(result.output))
        let state = Shell.run("/bin/ps", arguments: ["-p", String(child), "-o", "stat="])
        // 已退出或等待 init 回收的僵尸均不再执行用户命令。
        XCTAssertTrue(state == nil || state?.contains("Z") == true)
    }

    func testExitedParentCannotLeavePipeReaderBlocked() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = Shell.execute("/bin/sh", arguments: ["-c", "/bin/sleep 20 & exit 0"], timeout: 0.2)
        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testLargeOutputIsBoundedAndStillDrained() {
        let result = Shell.execute("/bin/sh", arguments: ["-c",
            "/usr/bin/yes x | /usr/bin/head -c 1048576; /usr/bin/yes y | /usr/bin/head -c 1048576 >&2"],
            outputLimit: 1024)
        XCTAssertEqual(result.completion, .exited(0))
        XCTAssertEqual(result.output.utf8.count, 1024)
        XCTAssertEqual(result.errorOutput.utf8.count, 1024)
        XCTAssertTrue(result.outputTruncated)
    }

    func testContinuousOutputStillTimesOut() {
        let result = Shell.execute("/usr/bin/yes", arguments: ["x"], timeout: 0.2, outputLimit: 512)
        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertTrue(result.outputTruncated)
    }

    func testCancellationInterruptsRunningCommand() {
        let cancellation = Shell.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let result = Shell.execute("/bin/sleep", arguments: ["20"], cancellation: cancellation)
        XCTAssertEqual(result.completion, .cancelled)
    }

    func testLaunchFailureAndLossyUTF8() {
        let missing = Shell.execute("/notchdeck-nonexistent-executable", arguments: [])
        XCTAssertEqual(missing.completion, .launchFailed(ENOENT))
        let result = Shell.execute("/bin/sh", arguments: ["-c", "printf '\\377ok'"])
        XCTAssertEqual(result.completion, .exited(0))
        XCTAssertTrue(result.output.hasSuffix("ok"))
    }
}

final class SettingsAndLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "com.notchdeck.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testAKeySurvivesRestartAndInvalidStoredValuesDoNotCrash() {
        let settings = SettingsStore(defaults: defaults)
        settings.hotKeyCode = UInt32(kVK_ANSI_A)
        XCTAssertEqual(SettingsStore(defaults: defaults).hotKeyCode, UInt32(kVK_ANSI_A))
        defaults.set(-1, forKey: "settings.hotKeyCode")
        defaults.set(-1, forKey: "settings.hotKeyModifiers")
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.hotKeyCode, UInt32(kVK_ANSI_I))
        XCTAssertEqual(restored.hotKeyModifiers, UInt32(cmdKey | shiftKey))
    }

    func testModuleOrderPersistsNormalizesAndIgnoresBoundaryMoves() {
        let settings = SettingsStore(defaults: defaults)
        let registryIDs = ["media", "volume", "apps", "system", "node", "custom"]
        // 未设置排序时按注册顺序原样输出
        XCTAssertEqual(settings.effectiveModuleOrder(registryIDs: registryIDs), registryIDs)
        // 上移一位，与重启后读取一致
        settings.moveModule("system", offset: -1, registryIDs: registryIDs)
        XCTAssertEqual(settings.effectiveModuleOrder(registryIDs: registryIDs),
                       ["media", "volume", "system", "apps", "node", "custom"])
        XCTAssertEqual(SettingsStore(defaults: defaults).moduleOrder,
                       ["media", "volume", "system", "apps", "node", "custom"])
        // 边界移动不写入任何变更
        settings.moveModule("media", offset: -1, registryIDs: registryIDs)
        settings.moveModule("custom", offset: 1, registryIDs: registryIDs)
        XCTAssertEqual(settings.moduleOrder,
                       ["media", "volume", "system", "apps", "node", "custom"])
        // 历史遗留未知 id 被剔除，新增模块按注册顺序附加在后
        defaults.set(["custom", "gone", "media"], forKey: "settings.moduleOrder")
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.effectiveModuleOrder(registryIDs: registryIDs),
                       ["custom", "media", "volume", "apps", "system", "node"])
    }

    func testRegistryStartsOnceAndStopsDisabledOrUnavailableModules() {
        let settings = SettingsStore(defaults: defaults)
        let registry = ModuleRegistry()
        let module = LifecycleModule()
        registry.register(module)
        registry.register(module)
        registry.updateActivity(settings: settings)
        registry.updateActivity(settings: settings)
        XCTAssertEqual(registry.boxes.count, 1)
        XCTAssertEqual(module.starts, 1)
        settings.updateConfig(for: module.id) { $0.enabled = false }
        registry.updateActivity(settings: settings)
        XCTAssertEqual(module.stops, 1)
        settings.updateConfig(for: module.id) { $0.enabled = true }
        registry.updateActivity(settings: settings)
        module.isAvailable = false
        registry.updateActivity(settings: settings)
        XCTAssertEqual(module.starts, 2)
        XCTAssertEqual(module.stops, 2)
    }

    @MainActor
    func testChangedCustomCommandDiscardsOldResultsAndRunsNewCommand() {
        let settings = SettingsStore(defaults: defaults)
        let old = CustomItem(name: "test", command: "/bin/sleep 2; printf stale")
        settings.customItems = [old]
        let module = CustomItemsModule(settings: settings)
        module.start()
        defer { module.stop() }
        let updated = expectation(description: "New configuration finishes")
        var observed: [String] = []
        let subscription = module.$outputs.sink { output in
            if let value = output[old.id] {
                observed.append(value)
                if value == "fresh" { updated.fulfill() }
            }
        }
        module.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var replacement = old
            replacement.command = "printf fresh"
            settings.customItems = [replacement]
        }
        wait(for: [updated], timeout: 3)
        XCTAssertFalse(observed.contains("stale"))
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testDisabledCustomModuleDoesNotExecuteAndStopDiscardsResults() {
        let settings = SettingsStore(defaults: defaults)
        settings.customItems = [CustomItem(name: "test", command: "/bin/sleep 1; printf stale")]
        settings.updateConfig(for: "custom") { $0.enabled = false }
        let module = CustomItemsModule(settings: settings)
        module.start()
        module.refresh()
        XCTAssertFalse(module.isRunning)
        settings.updateConfig(for: "custom") { $0.enabled = true }
        module.refresh()
        XCTAssertTrue(module.isRunning)
        module.stop()
        let settled = expectation(description: "Cancelled completion delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(module.isRunning)
        XCTAssertTrue(module.outputs.isEmpty)
    }

    func testCustomItemLegacyDecodingFallsBackToText() throws {
        // 旧版本持久化数据没有 display 字段，缺失时回退为文本展示而不是解码失败
        let legacy = #"{"id":"abc","name":"IP","command":"echo 1"}"#
        let item = try JSONDecoder().decode(CustomItem.self, from: Data(legacy.utf8))
        XCTAssertEqual(item.display, .text)
        XCTAssertEqual(item.name, "IP")
        let restored = try JSONDecoder().decode(CustomItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored, item)
        let heatmap = try JSONDecoder().decode(
            CustomItem.self,
            from: Data(#"{"id":"def","name":"热力","command":"seq 5","display":"heatmap"}"#.utf8))
        XCTAssertEqual(heatmap.display, .heatmap)
    }

    func testNumbersParsesSeparatedTokensAndIgnoresOthers() {
        XCTAssertEqual(CustomItemsModule.numbers(in: "12 0.5,7%\nabc -3;x", limit: 10), [12, 0.5, 7, -3])
        XCTAssertEqual(CustomItemsModule.numbers(in: "no digits here", limit: 10), [])
        XCTAssertEqual(CustomItemsModule.numbers(in: "", limit: 10), [])
        let many = (1...20).map(String.init).joined(separator: "\n")
        XCTAssertEqual(CustomItemsModule.numbers(in: many, limit: 5), [1, 2, 3, 4, 5])
        XCTAssertEqual(CustomItemsModule.numbers(in: many, limit: 0), [])
    }

    func testHeatmapLevelDarkerForLargerValue() {
        let levels = (0...100).map { CustomHeatmapView.levelIndex(for: Double($0), minimum: 0, maximum: 100) }
        // 数值越大色档不降低；最小值最浅、最大值最深、中间单调不减
        XCTAssertEqual(levels.first, 0)
        XCTAssertEqual(levels.last, CustomHeatmapView.levelOpacities.count - 1)
        XCTAssertEqual(levels, levels.sorted())
        // 全部相等时取最深档；越界值被钳制
        XCTAssertEqual(CustomHeatmapView.levelIndex(for: 5, minimum: 5, maximum: 5),
                       CustomHeatmapView.levelOpacities.count - 1)
        XCTAssertEqual(CustomHeatmapView.levelIndex(for: -3, minimum: 0, maximum: 100), 0)
        XCTAssertEqual(CustomHeatmapView.levelIndex(for: 130, minimum: 0, maximum: 100),
                       CustomHeatmapView.levelOpacities.count - 1)
    }

    @MainActor
    func testHeatmapSingleValueAccumulatesAndResetsOnCommandChange() {
        let settings = SettingsStore(defaults: defaults)
        let item = CustomItem(name: "heat", command: "printf 5", display: .heatmap)
        settings.customItems = [item]
        let module = CustomItemsModule(settings: settings, pollInterval: 60)
        module.start()
        defer { module.stop() }

        func sample(_ value: Double) -> CustomItemsModule.CustomHeatmapSample { .value(value) }

        let first = expectation(description: "首次执行产生一个样本")
        let second = expectation(description: "再次执行累积第二个样本")
        let reset = expectation(description: "命令变更后历史重新累积")
        var cancellables = Set<AnyCancellable>()
        module.$samples.sink { samples in
            let values = samples[item.id] ?? []
            // 用序列内容而非元素个数判定，使命令重置后的单元素序列不会重复满足 first
            if values == [sample(5)] { first.fulfill() }
            if values == [sample(5), sample(5)] { second.fulfill() }
            if values == [sample(6)] { reset.fulfill() }
        }.store(in: &cancellables)

        module.refresh()
        wait(for: [first], timeout: 5)
        module.refresh()
        wait(for: [second], timeout: 5)
        XCTAssertEqual(module.samples[item.id], [sample(5), sample(5)])

        var replaced = item
        replaced.command = "printf 6"
        settings.customItems = [replaced]
        wait(for: [reset], timeout: 5)
        XCTAssertEqual(module.samples[item.id], [sample(6)])
    }

    @MainActor
    func testHeatmapFailureRecordsRedSampleThenRecovers() {
        let settings = SettingsStore(defaults: defaults)
        let marker = NSTemporaryDirectory() + "notchdeck-recovery-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: marker) }
        // 同一条命令首次失败（建标记文件）、再次执行成功：失败样本与成功样本在同一序列累积
        let command = "if [ -f \"\(marker)\" ]; then printf 3; else touch \"\(marker)\"; exit 7; fi"
        let item = CustomItem(name: "probe", command: command, display: .heatmap)
        settings.customItems = [item]
        let module = CustomItemsModule(settings: settings, pollInterval: 60)
        module.start()
        defer { module.stop() }
        let failed = expectation(description: "非 0 退出记为失败样本")
        let recovered = expectation(description: "恢复成功后继续累积")
        var cancellables = Set<AnyCancellable>()
        module.$samples.sink { samples in
            if samples[item.id] == [.failure] { failed.fulfill() }
            if samples[item.id] == [.failure, .value(3)] { recovered.fulfill() }
        }.store(in: &cancellables)
        module.refresh()
        wait(for: [failed], timeout: 5)
        module.refresh()
        wait(for: [recovered], timeout: 5)
    }

    @MainActor
    func testHeatmapItemsArePolledInBackgroundWithoutManualRefresh() {
        let settings = SettingsStore(defaults: defaults)
        let item = CustomItem(name: "probe", command: "printf 9", display: .heatmap)
        settings.customItems = [item]
        // 缩短轮询间隔验证后台采样；不手动 refresh，只靠定时器驱动
        let module = CustomItemsModule(settings: settings, pollInterval: 0.3)
        module.start()
        defer { module.stop() }
        let polled = expectation(description: "定时器完成首次采样")
        var cancellables = Set<AnyCancellable>()
        module.$samples.sink { samples in
            if samples[item.id]?.isEmpty == false { polled.fulfill() }
        }.store(in: &cancellables)
        wait(for: [polled], timeout: 5)
        XCTAssertEqual(module.samples[item.id], [.value(9)])
    }

    func testHeatmapValueFormattingMatchesMagnitude() {
        XCTAssertEqual(CustomHeatmapView.format(62), "62")
        XCTAssertEqual(CustomHeatmapView.format(0.023), "0.023")
        XCTAssertEqual(CustomHeatmapView.format(45.3), "45.3")
        XCTAssertEqual(CustomHeatmapView.format(1234.4), "1234")
        XCTAssertEqual(CustomHeatmapView.format(1234.6), "1235")
        XCTAssertEqual(CustomHeatmapView.format(-0.5), "-0.500")
    }

    @MainActor
    func testHeatmapSuccessWithoutNumbersIsMarkedUnparsed() {
        let settings = SettingsStore(defaults: defaults)
        let item = CustomItem(name: "heat", command: "printf ok", display: .heatmap)
        settings.customItems = [item]
        let module = CustomItemsModule(settings: settings)
        module.start()
        defer { module.stop() }
        let done = expectation(description: "执行完成")
        var cancellables = Set<AnyCancellable>()
        module.$outputs.sink { outputs in
            if outputs[item.id] != nil { done.fulfill() }
        }.store(in: &cancellables)
        module.refresh()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(module.outputs[item.id], "ok")
        XCTAssertTrue(module.unparsedHeatmapIDs.contains(item.id))
        XCTAssertNil(module.samples[item.id])
    }
}

private final class LifecycleModule: ObservableObject, NotchModule {
    let id = "fixture"
    let title = "fixture"
    let systemImage = "circle"
    var isAvailable = true
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func content() -> some View { EmptyView() }
}

final class MediaAndMonitoringTests: XCTestCase {
    func testGeneratedMediaScriptWithFixtureApplication() throws {
        // 执行实际 JXA 脚本，但用普通 JS 对象替代应用，避免自动化授权与播放器副作用。
        let fixture = """
        const fixtureApplication = function() { return {
            running: function() { return true; },
            playerState: function() { return 'playing'; },
            playerPosition: function() { return 12.5; },
            currentTrack: function() { return {
                name: function() { return 'Song | live'; }, artist: function() { return 'Artist'; },
                album: function() { return 'Album'; }, duration: function() { return 120000; },
                artworkUrl: function() { return 'https://example.com/art.jpg'; }
            }; }
        }; };
        """
        let result = Shell.execute("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e",
            fixture + "\n" + Scripting.infoScript(for: "com.spotify.client")
                .replacingOccurrences(of: "Application(", with: "fixtureApplication(")])
        XCTAssertEqual(result.completion, .exited(0), result.errorOutput)
        let track = try XCTUnwrap(Scripting.parse(result.output, bundleID: "com.spotify.client"))
        XCTAssertEqual(track.title, "Song | live")
        XCTAssertEqual(track.duration, 120)
        XCTAssertTrue(track.isPlaying)
    }

    @MainActor
    func testNativeSystemSamplingPublishesUsableData() {
        let monitor = SystemMonitor()
        let sampled = expectation(description: "Native sample")
        let subscription = monitor.$stats.dropFirst().first().sink { stats in
            XCTAssertGreaterThan(stats.memoryTotal, 0)
            XCTAssertGreaterThan(stats.memoryUsed, 0)
            XCTAssertGreaterThan(stats.diskTotal, 0)
            XCTAssertTrue((0...1).contains(stats.cpuUsage))
            sampled.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }
        wait(for: [sampled], timeout: 3)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testScannerFindsOwnedListeningSocket() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let scanner = NodeProcessScanner()
        let found = expectation(description: "Owned TCP listener found")
        let subscription = scanner.$processes.dropFirst().first().sink { processes in
            XCTAssertTrue(processes.contains { $0.pid == getpid() && $0.port == port })
            XCTAssertTrue(processes.allSatisfy { $0.identity.uid == getuid() })
            found.fulfill()
        }
        scanner.start()
        defer { scanner.stop() }
        wait(for: [found], timeout: 10)
        withExtendedLifetime(subscription) {}
    }

    func testMediaMetadataPreservesSeparatorsAndSpotifyDurationUsesSeconds() throws {
        let title = "Song | Part \"2\"\n现场"
        let raw = try JSONSerialization.data(withJSONObject: [
            "title": title, "artist": "A|B", "album": "Live", "isPlaying": true,
            "elapsed": 75.5, "duration": 180000, "artworkURL": "https://example.com/cover.jpg"
        ])
        let spotify = try XCTUnwrap(Scripting.parse(String(decoding: raw, as: UTF8.self), bundleID: "com.spotify.client"))
        XCTAssertEqual(spotify.title, title)
        XCTAssertEqual(spotify.artist, "A|B")
        XCTAssertEqual(spotify.duration, 180)
        XCTAssertEqual(spotify.elapsed, 75.5)
        let music = try XCTUnwrap(Scripting.parse(String(decoding: raw, as: UTF8.self), bundleID: "com.apple.Music"))
        XCTAssertEqual(music.duration, 180000)
    }

    func testMalformedMediaAndRawArtwork() {
        XCTAssertNil(Scripting.parse("not JSON", bundleID: "com.apple.Music"))
        XCTAssertEqual(Scripting.artworkData("«data JPEGFFD8FF»\n"), Data([0xff, 0xd8, 0xff]))
        XCTAssertNil(Scripting.artworkData("«data JPEGXYZ»"))
        XCTAssertNil(Scripting.artworkData(""))
    }

    func testRatesUseElapsedTimeAnd64BitCounters() {
        var sample = NetworkRateSample()
        let initial: UInt64 = 9_000_000_000
        XCTAssertEqual(sample.update([1: NetworkCounter(inBytes: initial, outBytes: initial)], at: 10).down, 0)
        let rate = sample.update([1: NetworkCounter(inBytes: initial + 2000, outBytes: initial + 1000)], at: 12)
        XCTAssertEqual(rate.down, 1000)
        XCTAssertEqual(rate.up, 500)
    }

    func testCounterResetNewInterfaceAndWakeDoNotSpike() {
        var sample = NetworkRateSample()
        _ = sample.update([1: NetworkCounter(inBytes: 1000, outBytes: 1000)], at: 1)
        let reset = sample.update([1: NetworkCounter(inBytes: 0, outBytes: 0),
                                   2: NetworkCounter(inBytes: 99999, outBytes: 99999)], at: 2)
        XCTAssertEqual(reset.down, 0)
        XCTAssertEqual(reset.up, 0)
        XCTAssertEqual(sample.update([1: NetworkCounter(inBytes: 9000, outBytes: 9000)], at: 100).down, 0)
    }

    func testCPUTickWrapDoesNotUnderflow() {
        XCTAssertEqual(CPUSample.usage(previous: [UInt32.max - 4, 0, 20, 0], current: [5, 0, 30, 0]), 0.5)
        XCTAssertEqual(CPUSample.usage(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]), 0)
    }

    func testListenerFieldParserSupportsIPv6AndDeduplicatesSockets() {
        let result = NodeProcessScanner.parseListeners("p42\nn*:3000\nn[::1]:3000\nn127.0.0.1:8080\np43\nn*:3000\npbad\nn*:9000\np44\nn*:65536\n")
        XCTAssertEqual(result[42], [3000, 8080])
        XCTAssertEqual(result[43], [3000])
        XCTAssertNil(result[44])
        XCTAssertEqual(result.count, 2)
    }

    func testKillerRejectsProcessGroupsSelfAndStaleIdentity() throws {
        let current = try XCTUnwrap(ProcessIdentity.read(getpid()))
        XCTAssertNotNil(NodeProcessKiller.terminate(current))
        XCTAssertNotNil(NodeProcessKiller.terminate(ProcessIdentity(pid: 0, uid: getuid(), startSeconds: 0, startMicroseconds: 0)))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let identity = try XCTUnwrap(ProcessIdentity.read(child.processIdentifier))
        let stale = ProcessIdentity(pid: identity.pid, uid: identity.uid,
                                    startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
        XCTAssertNotNil(NodeProcessKiller.terminate(stale))
        XCTAssertTrue(child.isRunning)
        XCTAssertNil(NodeProcessKiller.terminate(identity))
    }
}
