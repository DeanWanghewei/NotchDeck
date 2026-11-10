import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest

/// 进程扫描器的降级行为与 lsof 字段解析回归测试。
///
/// 全部通过注入的执行器模拟 lsof / ps 输出：
/// 受限运行环境（沙箱、部分 CI）里 /bin/ps 会被系统以 EPERM 拒绝执行，
/// 测试不能依赖系统 ps 的行为。
final class NodeScannerTests: XCTestCase {
    // MARK: - lsof -Fpcn 字段解析

    func testParseListenerFieldsReadsCommandNameAndPorts() {
        // 探针实证形态：p=pid、f=fd、c=命令名、n=host:port
        let output = """
        p544
        crapportd
        f11
        n*:57076
        f13
        n*:57076
        p1050
        c企业微信
        f143
        n127.0.0.1:9884
        """
        let fields = NodeProcessScanner.parseListenerFields(output)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[544]?.commandName, "rapportd")
        XCTAssertEqual(fields[544]?.ports, [57076])
        XCTAssertEqual(fields[1050]?.commandName, "企业微信")
        XCTAssertEqual(fields[1050]?.ports, [9884])
    }

    func testParseListenerFieldsKeepsMultiplePortsOfSameProcess() {
        let output = "p42\ncnode\nf3\nn*:3000\nf4\nn[::1]:3000\nf5\nn127.0.0.1:8080\n"
        let fields = NodeProcessScanner.parseListenerFields(output)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[42]?.ports, [3000, 8080])
    }

    func testParseListenerFieldsRejectsDirtyOutput() {
        let output = """
        corphan
        p1
        cinit
        n*:22
        pbad
        cbroken
        n*:9000
        p42
        cnode
        n*:3000
        n*:0
        n*:65536
        n/tmp/12345
        n/tmp/dir:12345
        n*:8080
        """
        let fields = NodeProcessScanner.parseListenerFields(output)
        // 只留下有合法端口的 pid：pid 1、非法 pid 行、越界端口、文件路径都不入表
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[42]?.commandName, "node")
        XCTAssertEqual(fields[42]?.ports, [3000, 8080])
    }

    func testPortFieldBoundariesAndAddressForms() {
        XCTAssertEqual(NodeProcessScanner.port(fromNetworkField: "*:1"), 1)
        XCTAssertEqual(NodeProcessScanner.port(fromNetworkField: "*:65535"), 65535)
        XCTAssertEqual(NodeProcessScanner.port(fromNetworkField: "127.0.0.1:8080"), 8080)
        XCTAssertEqual(NodeProcessScanner.port(fromNetworkField: "[::1]:3000"), 3000)
        XCTAssertEqual(NodeProcessScanner.port(fromNetworkField: "[fe80::1%lo0]:3000"), 3000)
        XCTAssertNil(NodeProcessScanner.port(fromNetworkField: "*:0"))
        XCTAssertNil(NodeProcessScanner.port(fromNetworkField: "*:65536"))
        XCTAssertNil(NodeProcessScanner.port(fromNetworkField: "*:"))
        XCTAssertNil(NodeProcessScanner.port(fromNetworkField: "3000"))
        // 文件路径不是网络地址，不能被当成端口
        XCTAssertNil(NodeProcessScanner.port(fromNetworkField: "/tmp/3000"))
    }

    func testLegacyPortOnlyParserStillMatchesFieldProtocol() {
        let result = NodeProcessScanner.parseListeners("p42\nn*:3000\nn[::1]:3000\nn127.0.0.1:8080\np43\nn*:3000\npbad\nn*:9000\np44\nn*:65536\n")
        XCTAssertEqual(result[42], [3000, 8080])
        XCTAssertEqual(result[43], [3000])
        XCTAssertNil(result[44])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - ps 不可用时的降级

    func testScanDegradesToListenersWhenPSIsUnavailable() throws {
        let pid = getpid()
        let lsofOutput = "p\(pid)\ncfake-tool\nf3\nn127.0.0.1:5432\nn127.0.0.1:5433\n"
        // ps 启动失败（受限环境里 /bin/ps 被系统以 EPERM 拒绝执行）
        let runner = makeRunner(lsofOutput: lsofOutput, psMetrics: nil, psComm: nil)
        let result = NodeProcessScanner.performScan(runner: runner)

        // 关键：ps 失败不再清空列表，监听端口照常列出
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.port), [5432, 5433])
        let entry = try XCTUnwrap(result.first)
        XCTAssertEqual(entry.pid, pid)
        // 进程名来自 lsof 的 c 字段
        XCTAssertEqual(entry.displayName, "fake-tool")
        XCTAssertEqual(entry.executableName, "fake-tool")
        // 指标缺失：必须是 nil（缺失），不能补 0
        XCTAssertNil(entry.cpuPercent)
        XCTAssertNil(entry.memoryMB)
        XCTAssertEqual(entry.commandLine, "")
    }

    func testScanDegradesWhenPSExitsWithFailure() throws {
        let pid = getpid()
        let lsofOutput = "p\(pid)\ncfake-tool\nf3\nn127.0.0.1:5432\n"
        // ps 非 0 退出（等价于启动失败/超时：扫描器只认 .exited(0)）
        let runner = makeRunner(lsofOutput: lsofOutput, psMetrics: "", psMetricsExit: 1, psComm: nil)
        let result = NodeProcessScanner.performScan(runner: runner)
        XCTAssertEqual(result.count, 1)
        let entry = try XCTUnwrap(result.first)
        XCTAssertEqual(entry.port, 5432)
        XCTAssertEqual(entry.displayName, "fake-tool")
        XCTAssertNil(entry.cpuPercent)
        XCTAssertNil(entry.memoryMB)
    }

    func testScanKeepsListenersWhenOnlyCommandLineMetricsAreMissing() throws {
        let pid = getpid()
        let lsofOutput = "p\(pid)\ncfake-tool\nf3\nn127.0.0.1:5432\n"
        // ps 的指标行可用，但 comm 行那次调用失败：指标照旧，命令名另有来源
        let runner = makeRunner(lsofOutput: lsofOutput, psMetrics: "\(pid) 12.5 204800 /usr/local/bin/fake-tool --serve\n", psComm: nil)
        let result = NodeProcessScanner.performScan(runner: runner)
        let entry = try XCTUnwrap(result.first)
        XCTAssertEqual(entry.cpuPercent, 12.5)
        XCTAssertEqual(entry.memoryMB, 200)
        XCTAssertEqual(entry.commandLine, "/usr/local/bin/fake-tool --serve")
        XCTAssertFalse(entry.displayName.isEmpty)
    }

    // MARK: - ps 可用时的正常路径

    func testScanFillsMetricsWhenPSIsAvailable() throws {
        let pid = getpid()
        let lsofOutput = "p\(pid)\ncfake-tool\nf3\nn127.0.0.1:5432\n"
        let runner = makeRunner(lsofOutput: lsofOutput,
                                psMetrics: "\(pid) 12.5 204800 /usr/local/bin/fake-tool --serve\n",
                                psComm: "\(pid) /usr/local/bin/fake-tool\n")
        let result = NodeProcessScanner.performScan(runner: runner)

        XCTAssertEqual(result.count, 1)
        let entry = try XCTUnwrap(result.first)
        XCTAssertEqual(entry.pid, pid)
        XCTAssertEqual(entry.port, 5432)
        XCTAssertEqual(entry.displayName, "fake-tool")
        XCTAssertEqual(entry.executableName, "fake-tool")
        XCTAssertEqual(entry.cpuPercent, 12.5)
        XCTAssertEqual(entry.memoryMB, 200)
        XCTAssertEqual(entry.commandLine, "/usr/local/bin/fake-tool --serve")
    }

    func testScanKeepsProcessWhenPSRowIsMissing() throws {
        let pid = getpid()
        let lsofOutput = "p\(pid)\ncfake-tool\nf3\nn127.0.0.1:5432\n"
        // ps 输出里没有该 pid：指标缺失但进程仍然列出（不补 0）
        let runner = makeRunner(lsofOutput: lsofOutput, psMetrics: "\(pid + 100000) 1.0 1024 /usr/bin/other\n", psComm: nil)
        let result = NodeProcessScanner.performScan(runner: runner)
        let entry = try XCTUnwrap(result.first)
        XCTAssertNil(entry.cpuPercent)
        XCTAssertNil(entry.memoryMB)
    }

    // MARK: - 注入用执行器

    /// 模拟 lsof / ps 的输出与退出状态；ps 的两个调用（指标行、comm 行）分别可控
    private func makeRunner(lsofOutput: String,
                            psMetrics: String?,
                            psMetricsExit: Int32 = 0,
                            psComm: String? = nil,
                            psCommExit: Int32 = 0) -> NodeProcessScanner.Runner {
        { path, arguments in
            if path == "/usr/sbin/lsof" {
                return Shell.Result(output: lsofOutput, errorOutput: "", completion: .exited(0), outputTruncated: false)
            }
            if path == "/bin/ps" {
                if arguments.contains("pid=,%cpu=,rss=,command=") {
                    guard let psMetrics else { return nil }
                    return Shell.Result(output: psMetrics, errorOutput: "",
                                       completion: .exited(psMetricsExit), outputTruncated: false)
                }
                guard let psComm else { return nil }
                return Shell.Result(output: psComm, errorOutput: "",
                                   completion: .exited(psCommExit), outputTruncated: false)
            }
            return nil
        }
    }

    // MARK: - 自渲染目检

    /// 进程列表自渲染：指标缺失时必须显示占位「—」而不是假 0（AGENTS.md §4 要求 UI 改动目检深浅两版）。
    /// 仅在设置 `NOTCHDECK_RENDER_DIR` 时执行；直跑 xctest 时传 `NOTCHDECK_RENDER_DIR=... xcrun xctest ...`。
    @MainActor
    func testRenderProcessListWithMissingMetricsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // 两个真实存活进程：一个有 ps 指标，一个没有（模拟 ps 不可用时的降级行）
        let pidWithMetrics = getpid()
        let pidWithoutMetrics = getppid()
        let lsofOutput = """
        p\(pidWithMetrics)
        cfake-tool
        f3
        n127.0.0.1:5432
        p\(pidWithoutMetrics)
        cfake-missing-metrics
        f4
        n127.0.0.1:5433
        """
        let runner = makeRunner(lsofOutput: lsofOutput,
                                psMetrics: "\(pidWithMetrics) 12.5 204800 /usr/local/bin/fake-tool --serve\n",
                                psComm: "\(pidWithMetrics) /usr/local/bin/fake-tool\n")
        let scanner = NodeProcessScanner(runner: runner)
        let published = expectation(description: "扫描结果已发布")
        var received: [NodeProcessInfo] = []
        let subscription = scanner.$processes.dropFirst().first().sink { processes in
            received = processes
            published.fulfill()
        }
        scanner.start()
        defer { scanner.stop() }
        wait(for: [published], timeout: 5)
        withExtendedLifetime(subscription) {}

        XCTAssertEqual(received.count, 2)
        XCTAssertNotNil(received.first { $0.cpuPercent != nil })
        XCTAssertNotNil(received.first { $0.cpuPercent == nil })

        // NodeListView 读的是 SettingsStore.shared 的展示方式：渲染前切到指定样式，结束后还原
        let previousDisplay = SettingsStore.shared.processDisplay
        defer { SettingsStore.shared.processDisplay = previousDisplay }
        let size = NSSize(width: 520, height: 220)
        for style in ["grid", "list"] {
            SettingsStore.shared.processDisplay = style
            try render(NodeListView(scanner: scanner, settings: SettingsStore.shared),
                       name: "node-list-\(style)-missing-metrics", size: size, directory: directory)
        }
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize, directory: String) throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: view
                .padding(16).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // 屏幕外呈现窗口，等布局与首帧渲染完成后再缓存，避免截到空白帧
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            let rendered = expectation(description: "等待首帧渲染完成")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { rendered.fulfill() }
            wait(for: [rendered], timeout: 2)
            host.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("无法渲染"); continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = directory + "/" + name + "-" + (dark ? "dark" : "light") + ".png"
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
