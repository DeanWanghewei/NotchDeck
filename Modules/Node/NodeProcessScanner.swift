import AppKit
import Combine
import Foundation
import SwiftUI

struct NodeProcessInfo: Identifiable, Equatable {
    var id: String { "\(pid)-\(port)" }
    let pid: pid_t
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
    private let scanQueue = DispatchQueue(label: "com.notchdeck.nodescanner", qos: .utility)

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            let result = Self.performScan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes = result
                self.isScanning = false
            }
        }
    }

    // MARK: - 扫描实现

    private static func performScan() -> [NodeProcessInfo] {
        guard let lsofOutput = Shell.run("/usr/sbin/lsof", arguments: ["-i", "-P", "-n", "-w"]) else {
            return []
        }

        // 1. 收集所有 LISTEN 的 pid + 端口
        var pidPorts: [pid_t: Set<Int>] = [:]
        for line in lsofOutput.split(separator: "\n").dropFirst() {
            guard line.contains("(LISTEN)") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (LISTEN)
            guard fields.count >= 9,
                  let pid = pid_t(fields[1]),
                  let port = Int(fields[8].split(separator: ":").last ?? ""),
                  port > 0, port < 65536 else { continue }
            pidPorts[pid, default: []].insert(port)
        }
        guard !pidPorts.isEmpty else { return [] }

        let pidList = pidPorts.keys.map(String.init).joined(separator: ",")

        // 2. ps 获取 CPU/内存/完整命令行；comm 为真实可执行文件（不受 process.title 改名影响）
        guard let metricsOutput = Shell.run("/bin/ps", arguments: ["-o", "pid=,%cpu=,rss=,command=", "-p", pidList]) else {
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
        if let commOutput = Shell.run("/bin/ps", arguments: ["-o", "pid=,comm=", "-p", pidList]) {
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
            guard let metrics = pidMetrics[pid] else { continue }
            let comm = pidComm[pid] ?? ""
            guard !isSystemDaemon(comm) else { continue }

            let displayName = displayName(for: metrics.command, comm: comm)
            let executableName = (comm as NSString).lastPathComponent
            let isAppProcess = comm.contains(".app/")
            for port in ports {
                result.append(NodeProcessInfo(pid: pid,
                                              port: port,
                                              displayName: displayName,
                                              executableName: executableName.isEmpty ? "进程" : executableName,
                                              isAppProcess: isAppProcess,
                                              cpuPercent: metrics.cpu,
                                              memoryMB: metrics.memoryMB,
                                              commandLine: metrics.command))
            }
        }
        return result.sorted { $0.port < $1.port }
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
    /// 第一个非 flag 参数若是裸词（无扩展名无路径，如 start/serve/run），那是子命令而非文件，
    /// 看不出身份，此时回退到可执行文件名（如 Lingma）
    private static func displayName(for commandLine: String, comm: String) -> String {
        if let bundleName = appBundleName(from: comm) {
            return bundleName
        }
        let tokens = commandLine.split(separator: " ").map(String.init)
        let commName = (comm as NSString).lastPathComponent
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") { continue }
            if !token.contains("/") && !token.contains(".") {
                break // 裸子命令，不可读
            }
            return (token as NSString).lastPathComponent
        }
        if let fromCommand = tokens.first.map({ ($0 as NSString).lastPathComponent }),
           !fromCommand.isEmpty, fromCommand != commName {
            return fromCommand
        }
        return commName.isEmpty ? "进程" : commName
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

extension NodeProcessScanner: NotchModule {
    var id: String { "node" }
    var title: String { "进程监控" }
    var systemImage: String { "terminal" }

    func content() -> some View {
        NodeListView(scanner: self)
    }
}
