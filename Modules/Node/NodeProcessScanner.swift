import AppKit
import Combine
import Foundation
import SwiftUI

struct NodeProcessInfo: Identifiable, Equatable {
    var id: String { "\(pid)-\(identity.startSeconds)-\(identity.startMicroseconds)-\(port)" }
    let identity: ProcessIdentity
    var pid: pid_t { identity.pid }
    let port: Int
    let displayName: String
    let executableName: String
    /// true = App 包内可执行（路径含 .app/）；false = 脚本/命令行进程（node、python、java 等）
    let isAppProcess: Bool
    let cpuPercent: Double
    let memoryMB: Double
    let commandLine: String
}

/// 监听端口进程扫描：零配置，默认列出当前用户所有监听 TCP 端口的非系统进程。
/// lsof 找 PID/端口，ps 取可执行文件/命令行/资源占用，每 2 秒刷新。
final class NodeProcessScanner: ObservableObject {
    @Published private(set) var processes: [NodeProcessInfo] = []

    private var timer: Timer?
    private var isScanning = false
    private var generation = 0
    private var cancellation: Shell.Cancellation?
    private let scanQueue = DispatchQueue(label: "com.notchdeck.nodescanner", qos: .utility)

    func start() {
        guard timer == nil else { return }
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
        scan()
    }

    func stop() {
        generation += 1
        cancellation?.cancel()
        timer?.invalidate()
        timer = nil
    }

    func scan() {
        guard timer != nil, !isScanning else { return }
        isScanning = true
        let version = generation
        let token = Shell.Cancellation()
        cancellation = token
        scanQueue.async { [weak self] in
            let result = Self.performScan(cancellation: token)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                guard self.timer != nil, self.generation == version else { return }
                self.processes = result
            }
        }
    }

    // MARK: - 扫描实现

    private static func performScan(cancellation: Shell.Cancellation) -> [NodeProcessInfo] {
        func run(_ path: String, _ arguments: [String]) -> String? {
            let result = Shell.execute(path, arguments: arguments, cancellation: cancellation)
            return result.completion == .exited(0) ? result.output : nil
        }
        guard let lsofOutput = run("/usr/sbin/lsof", ["-a", "-u", String(getuid()),
            "-iTCP", "-sTCP:LISTEN", "-nP", "-Fpn"]) else { return [] }
        let pidPorts = parseListeners(lsofOutput)
        guard !pidPorts.isEmpty else { return [] }
        let identities = pidPorts.keys.reduce(into: [pid_t: ProcessIdentity]()) { result, pid in
            if let identity = ProcessIdentity.read(pid), identity.uid == getuid() { result[pid] = identity }
        }
        guard !identities.isEmpty else { return [] }
        let pidList = identities.keys.sorted().map(String.init).joined(separator: ",")

        // 2. ps 获取 CPU/内存/完整命令行；comm 为真实可执行文件（不受 process.title 改名影响）
        guard let metricsOutput = run("/bin/ps", ["-ww", "-o", "pid=,%cpu=,rss=,command=", "-p", pidList]) else {
            return []
        }
        var pidMetrics: [pid_t: (cpu: Double, memoryMB: Double, command: String)] = [:]
        for line in metricsOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 4,
                  let pid = pid_t(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Double(fields[2]) else { continue }
            pidMetrics[pid] = (cpu, rssKB / 1024, fields[3])
        }

        // comm 单独一列（路径可能含空格，pid 之后的整体即 comm）
        var pidComm: [pid_t: String] = [:]
        if let commOutput = run("/bin/ps", ["-ww", "-o", "pid=,comm=", "-p", pidList]) {
            for line in commOutput.split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                if fields.count == 2, let pid = pid_t(fields[0]) {
                    pidComm[pid] = fields[1]
                }
            }
        }

        // 3. 组装：排除系统目录下的守护进程（ControlCenter、rapportd 等），其余全部展示
        var result: [NodeProcessInfo] = []
        for (pid, ports) in pidPorts {
            guard let metrics = pidMetrics[pid], let identity = identities[pid],
                  ProcessIdentity.read(pid) == identity else { continue }
            let comm = pidComm[pid] ?? ""
            guard !isSystemDaemon(comm) else { continue }

            let displayName = displayName(for: metrics.command, comm: comm)
            let executableName = (comm as NSString).lastPathComponent
            let isAppProcess = comm.contains(".app/")
            for port in ports {
                result.append(NodeProcessInfo(identity: identity,
                                              port: port,
                                              displayName: displayName,
                                              executableName: executableName.isEmpty ? "进程" : executableName,
                                              isAppProcess: isAppProcess,
                                              cpuPercent: metrics.cpu,
                                              memoryMB: metrics.memoryMB,
                                              commandLine: metrics.command))
            }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// lsof 的字段协议不依赖列宽、用户名或 COMMAND 中的空格。
    static func parseListeners(_ output: String) -> [pid_t: Set<Int>] {
        var result: [pid_t: Set<Int>] = [:]
        var pid: pid_t?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = pid_t(line.dropFirst())
            case "n":
                guard let pid, pid > 1,
                      let port = Int(line.split(separator: ":").last ?? ""), (1...65535).contains(port) else { continue }
                result[pid, default: []].insert(port)
            default: break
            }
        }
        return result
    }

    /// 系统自带守护进程（/System、/usr/libexec、/usr/sbin、/sbin）不展示：
    /// 它们数量多、与开发场景无关，且结束后会被 launchd 自动拉起
    private static func isSystemDaemon(_ comm: String) -> Bool {
        guard !comm.isEmpty else { return true }
        return comm.hasPrefix("/System/") ||
            comm.hasPrefix("/usr/libexec/") ||
            comm.hasPrefix("/usr/sbin/") ||
            comm.hasPrefix("/sbin/")
    }

    /// 展示名优先级：App 包名（如 企业微信、IntelliJ IDEA）> 脚本/模块名（如 server.js、hermes_cli.main）> 可执行文件名。
    /// - `-m 模块` 调用时（python -m pkg.mod gateway run），紧随的裸词子命令拼入展示名以区分实例
    /// - 第一个非 flag 参数若是裸词（无扩展名无路径，如 start/serve/run），那是子命令而非文件，
    ///   看不出身份，此时回退到可执行文件名（如 Lingma）
    private static func displayName(for commandLine: String, comm: String) -> String {
        if let bundleName = appBundleName(from: comm) {
            return bundleName
        }
        let tokens = commandLine.split(separator: " ").map(String.init)
        let commName = (comm as NSString).lastPathComponent

        var scriptIsModule = false
        var scriptIndex: Int?
        var cursor = 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token == "-m" {
                scriptIsModule = true
            } else if !token.hasPrefix("-") {
                scriptIndex = cursor
                break
            }
            cursor += 1
        }
        guard let scriptIndex, let script = tokens[safe: scriptIndex] else {
            return commName.isEmpty ? "进程" : commName
        }
        // 裸词子命令（如 `Lingma start`）不可读，回退可执行名
        guard script.contains("/") || script.contains(".") else {
            return commName.isEmpty ? "进程" : commName
        }

        var name = (script as NSString).lastPathComponent
        if scriptIsModule, let sub = tokens[safe: scriptIndex + 1],
           let first = sub.first, first.isLetter {
            // python -m pkg.mod gateway run → "pkg.mod gateway"
            name += " " + sub
        }
        return name
    }

    /// 取最内层 .app 包名：/Applications/Hermes.app/.../Hermes Helper.app/... → "Hermes Helper"
    private static func appBundleName(from comm: String) -> String? {
        let components = comm.split(separator: "/").map(String.init)
        for component in components.reversed() where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return nil
    }
}

// MARK: - 面板模块接入

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NodeProcessScanner: NotchModule {
    var id: String { "node" }
    var title: String { "进程监控" }
    var systemImage: String { "terminal" }

    func content() -> some View {
        NodeListView(scanner: self)
    }
}
