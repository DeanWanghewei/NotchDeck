import AppKit
import Combine
import Foundation

struct NodeProcessInfo: Identifiable, Equatable {
    var id: String { "\(pid)-\(port)" }
    let pid: pid_t
    let port: Int
    let displayName: String
    let cpuPercent: Double
    let memoryMB: Double
    let commandLine: String
}

/// 扫描当前用户监听端口的 Node.js 进程：lsof 找 PID/端口，ps 取资源占用，每 2 秒刷新
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

    private static func performScan() -> [NodeProcessInfo] {
        guard let lsofOutput = Shell.run("/usr/sbin/lsof", arguments: ["-i", "-P", "-n", "-w"]) else {
            return []
        }

        var pidPorts: [pid_t: Set<Int>] = [:]
        for line in lsofOutput.split(separator: "\n").dropFirst() {
            guard line.contains("(LISTEN)") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (LISTEN)
            guard fields.count >= 9, fields[0].hasPrefix("node") else { continue }
            guard let pid = pid_t(fields[1]),
                  let port = Int(fields[8].split(separator: ":").last ?? "") else { continue }
            pidPorts[pid, default: []].insert(port)
        }
        guard !pidPorts.isEmpty else { return [] }

        let pidList = pidPorts.keys.map(String.init).joined(separator: ",")
        guard let psOutput = Shell.run("/bin/ps", arguments: ["-o", "pid=,%cpu=,rss=,command=", "-p", pidList]) else {
            return []
        }

        var pidMetrics: [pid_t: (cpu: Double, memoryMB: Double, command: String)] = [:]
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 4,
                  let pid = pid_t(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Double(fields[2]) else { continue }
            pidMetrics[pid] = (cpu, rssKB / 1024, fields[3])
        }

        var result: [NodeProcessInfo] = []
        for (pid, ports) in pidPorts {
            guard let metrics = pidMetrics[pid] else { continue }
            for port in ports {
                result.append(NodeProcessInfo(pid: pid,
                                              port: port,
                                              displayName: displayName(for: metrics.command),
                                              cpuPercent: metrics.cpu,
                                              memoryMB: metrics.memoryMB,
                                              commandLine: metrics.command))
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// 从完整命令行提取展示名：跳过解释器与参数开关，取第一个脚本文件名（如 server.js）
    private static func displayName(for commandLine: String) -> String {
        let tokens = commandLine.split(separator: " ").map(String.init)
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") { continue }
            return (token as NSString).lastPathComponent
        }
        return tokens.first.map { ($0 as NSString).lastPathComponent } ?? "node"
    }
}

/// 外部命令执行（使用绝对路径，见风险对策）
enum Shell {
    @discardableResult
    static func run(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
