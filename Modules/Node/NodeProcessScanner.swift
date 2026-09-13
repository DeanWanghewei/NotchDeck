import AppKit
import Combine
import Foundation
import SwiftUI

struct NodeProcessInfo: Identifiable, Equatable {
    var id: String { "\(pid)-\(port)" }
    let pid: pid_t
    let port: Int
    let displayName: String
    let cpuPercent: Double
    let memoryMB: Double
    let commandLine: String
}

/// 监听端口进程扫描：lsof 找 PID/端口，ps 取可执行文件/命令行/资源占用，
/// 按用户配置的关键词（默认 node，可添加 hermes/python 等）过滤，每 2 秒刷新
final class NodeProcessScanner: ObservableObject {
    @Published private(set) var processes: [NodeProcessInfo] = []

    let id = "node"
    let title = "进程监控"
    let systemImage = "terminal"

    private var timer: Timer?
    private var isScanning = false
    private let scanQueue = DispatchQueue(label: "com.notchdeck.nodescanner", qos: .utility)
    private let settings = SettingsStore.shared

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
        // 主线程捕获关键词（@Published 属性不应跨线程读）
        let keywords = settings.processKeywords
        scanQueue.async { [weak self] in
            let result = Self.performScan(keywords: keywords)
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes = result
                self.isScanning = false
            }
        }
    }

    // MARK: - 扫描实现

    private static func performScan(keywords: [String]) -> [NodeProcessInfo] {
        let normalizedKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedKeywords.isEmpty else { return [] }

        guard let lsofOutput = Shell.run("/usr/sbin/lsof", arguments: ["-i", "-P", "-n", "-w"]) else {
            return []
        }

        // 1. 收集所有 LISTEN 的 pid + 端口（此处不过滤进程名）
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

        // 3. 关键词匹配：可执行文件路径包含任一关键词（不受 process.title 改名影响，
        //    也不会被命令行里偶现的关键词字样误伤，如 VS Code Helper 中的 node 路径）
        func isMatched(_ comm: String) -> Bool {
            guard !comm.isEmpty else { return false }
            let commLower = comm.lowercased()
            return normalizedKeywords.contains { commLower.contains($0) }
        }

        var result: [NodeProcessInfo] = []
        for (pid, ports) in pidPorts {
            guard let metrics = pidMetrics[pid] else { continue }
            let comm = pidComm[pid] ?? ""
            guard isMatched(comm) else { continue }

            let displayName = displayName(for: metrics.command, fallback: comm)
            for port in ports {
                result.append(NodeProcessInfo(pid: pid,
                                              port: port,
                                              displayName: displayName,
                                              cpuPercent: metrics.cpu,
                                              memoryMB: metrics.memoryMB,
                                              commandLine: metrics.command))
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// 从完整命令行提取展示名：跳过解释器与参数开关，取第一个脚本/模块名（如 server.js、hermes_cli.main）
    private static func displayName(for commandLine: String, fallback comm: String) -> String {
        let tokens = commandLine.split(separator: " ").map(String.init)
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") { continue }
            return (token as NSString).lastPathComponent
        }
        if tokens.first.map({ !$0.isEmpty }) == true {
            return (tokens.first! as NSString).lastPathComponent
        }
        return (comm as NSString).lastPathComponent.isEmpty ? "进程" : (comm as NSString).lastPathComponent
    }
}

// MARK: - 面板模块接入

extension NodeProcessScanner: NotchModule {
    func content() -> some View {
        NodeListView(scanner: self)
    }
}
