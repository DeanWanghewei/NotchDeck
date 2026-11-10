import AppKit
import Combine
import Darwin
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
    /// CPU 占用百分比；nil = 指标缺失（ps 不可用或该进程无采样）。
    /// 缺失必须显式表达为 nil：补 0 会被读成「真的没占用」，属于伪数值。
    let cpuPercent: Double?
    /// 内存占用（MB）；nil = 指标缺失，同 cpuPercent
    let memoryMB: Double?
    /// 完整命令行；ps 不可用时为空字符串（此时只有 pid/端口/进程名可用）
    let commandLine: String
}

/// 监听端口进程扫描：零配置，默认列出当前用户所有监听 TCP 端口的非系统进程。
/// lsof 找 PID/端口/命令名，ps 取 CPU/内存/完整命令行，每 2 秒刷新。
///
/// ps 在受限运行环境（沙箱、部分 CI）里会被系统以 EPERM 拒绝执行，
/// 旧实现因此在 ps 失败时直接清空整个进程列表。现在改为降级：
/// 仍列出监听端口（pid/端口/进程名来自 lsof），只把 CPU/内存标记为缺失。
final class NodeProcessScanner: ObservableObject {
    /// 命令执行器：注入后可在测试里模拟 ps 不可用。
    /// 返回 nil 或 completion 不是 .exited(0) 一律视为「命令不可用」。
    typealias Runner = (_ path: String, _ arguments: [String]) -> Shell.Result?

    /// lsof -Fpcn 字段解析结果：命令名 + 监听端口
    struct ListenerFields: Equatable {
        /// lsof 的 c 字段：命令名（ps 不可用时的进程名来源）
        var commandName: String
        /// 监听端口集合
        var ports: Set<Int>
    }

    /// ps 采样结果：CPU/内存/命令行 + 可执行路径
    struct Metrics {
        struct Sample {
            var cpu: Double
            var memoryMB: Double
            /// 完整命令行
            var command: String
        }
        var samples: [pid_t: Sample]
        /// ps -o comm= 的可执行路径（可能含空格，pid 之后的整体即 comm）
        var comms: [pid_t: String]
    }

    private let settings: SettingsStore
    /// 测试注入的执行器；nil 时用真实 Shell 执行
    private let injectedRunner: Runner?
    @Published private(set) var processes: [NodeProcessInfo] = []

    private var timer: Timer?
    private var isScanning = false
    private var generation = 0
    private var cancellation: Shell.Cancellation?
    private let scanQueue = DispatchQueue(label: "com.notchdeck.nodescanner", qos: .utility)

    init(settings: SettingsStore = .shared, runner: Runner? = nil) {
        self.settings = settings
        self.injectedRunner = runner
    }

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
            guard let self else { return }
            let result = Self.performScan(runner: self.makeRunner(token: token))
            DispatchQueue.main.async {
                self.isScanning = false
                guard self.timer != nil, self.generation == version else { return }
                self.processes = result
            }
        }
    }

    // MARK: - 扫描实现

    /// 默认执行器把取消令牌透传给 Shell：停止模块时能立刻结束正在跑的 lsof/ps。
    /// 注入的执行器由调用方自行处理令牌，单测因此不依赖系统进程行为。
    private func makeRunner(token: Shell.Cancellation) -> Runner {
        if let injectedRunner { return injectedRunner }
        return { path, arguments in
            Shell.execute(path, arguments: arguments, cancellation: token)
        }
    }

    static func performScan(runner: Runner) -> [NodeProcessInfo] {
        // lsof 是降级的地基：它不可用就拿不到 pid/端口/命令名，无从降级
        guard let lsofOutput = run(runner, "/usr/sbin/lsof",
                                   ["-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-nP", "-Fpcn"]) else { return [] }
        let listeners = parseListenerFields(lsofOutput)
        guard !listeners.isEmpty else { return [] }
        let identities = listeners.keys.reduce(into: [pid_t: ProcessIdentity]()) { result, pid in
            if let identity = ProcessIdentity.read(pid), identity.uid == getuid() { result[pid] = identity }
        }
        guard !identities.isEmpty else { return [] }
        let pidList = identities.keys.sorted().map(String.init).joined(separator: ",")

        // ps 不可用（启动失败 / 非 0 退出 / 超时）时 metrics 为 nil：
        // 继续列出监听端口进程，CPU/内存留空由 UI 显示占位，绝不补 0
        let metrics = fetchMetrics(runner: runner, pidList: pidList)

        var result: [NodeProcessInfo] = []
        for (pid, fields) in listeners {
            guard let identity = identities[pid],
                  ProcessIdentity.read(pid) == identity else { continue }
            let sample = metrics?.samples[pid]
            let psComm = metrics?.comms[pid] ?? ""
            // 可执行路径：ps 的 comm 优先；ps 不可用时用 libproc 公开接口兜底，
            // 这样系统守护进程过滤与 .app 识别在降级后依然成立
            let executablePath = psComm.isEmpty ? processExecutablePath(of: pid) : psComm
            guard !isSystemDaemon(executablePath) else { continue }

            let pathName = executablePath.map { ($0 as NSString).lastPathComponent } ?? ""
            // 进程名：ps 可用时取 comm 末段；不可用时取 lsof 的 c 字段（命令名）
            let name: String
            let displayName: String
            if let sample {
                name = pathName
                displayName = Self.displayName(for: sample.command, comm: psComm.isEmpty ? (executablePath ?? "") : psComm)
            } else {
                name = fields.commandName.isEmpty ? pathName : fields.commandName
                displayName = name
            }
            guard !name.isEmpty else { continue }
            let isAppProcess = executablePath?.contains(".app/") ?? false
            for port in fields.ports {
                result.append(NodeProcessInfo(identity: identity,
                                              port: port,
                                              displayName: displayName,
                                              executableName: name,
                                              isAppProcess: isAppProcess,
                                              cpuPercent: sample?.cpu,
                                              memoryMB: sample?.memoryMB,
                                              commandLine: sample?.command ?? ""))
            }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// ps 采样：主调用失败即整体判定为「指标不可用」（返回 nil）；
    /// comm 单独一次调用，失败时由 libproc 兜底，不影响 CPU/内存
    private static func fetchMetrics(runner: Runner, pidList: String) -> Metrics? {
        guard let metricsOutput = run(runner, "/bin/ps",
                                       ["-ww", "-o", "pid=,%cpu=,rss=,command=", "-p", pidList]) else { return nil }
        var samples: [pid_t: Metrics.Sample] = [:]
        for line in metricsOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 4,
                  let pid = pid_t(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Double(fields[2]) else { continue }
            samples[pid] = Metrics.Sample(cpu: cpu, memoryMB: rssKB / 1024, command: fields[3])
        }
        var comms: [pid_t: String] = [:]
        if let commOutput = run(runner, "/bin/ps", ["-ww", "-o", "pid=,comm=", "-p", pidList]) {
            for line in commOutput.split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                if fields.count == 2, let pid = pid_t(fields[0]) {
                    comms[pid] = fields[1]
                }
            }
        }
        return Metrics(samples: samples, comms: comms)
    }

    /// 只有正常退出 0 才算成功：启动失败 / 非 0 退出 / 超时一律视为命令不可用
    private static func run(_ runner: Runner, _ path: String, _ arguments: [String]) -> String? {
        guard let result = runner(path, arguments), result.completion == .exited(0) else { return nil }
        return result.output
    }

    /// lsof 的字段协议不依赖列宽、用户名或 COMMAND 中的空格。
    ///
    /// -Fpcn 探针实证（macOS 27.3）：p=pid、c=命令名、n=网络地址 host:port、f=fd（忽略）。
    /// c 字段是命令名 basename（不含路径，可含空格与括号，如 "Code Helper (Plugin)"），
    /// 每个进程一条、紧跟 p 之后；同一进程可有多条 n（每个监听 fd 一条）。
    static func parseListenerFields(_ output: String) -> [pid_t: ListenerFields] {
        var commands: [pid_t: String] = [:]
        var ports: [pid_t: Set<Int>] = [:]
        var pid: pid_t?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p":
                // 非法 pid 会让 pid 变成 nil，其后的 n 行一并作废
                pid = pid_t(line.dropFirst())
            case "c":
                guard let pid, pid > 1 else { continue }
                // 命令名两端可能有空白（内核 comm 的填充），显示前去掉
                commands[pid] = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            case "n":
                guard let pid, pid > 1,
                      let port = port(fromNetworkField: String(line.dropFirst())) else { continue }
                ports[pid, default: []].insert(port)
            default:
                break
            }
        }
        // 只有拿到合法端口的 pid 才入表：否则会留下空条目
        var result: [pid_t: ListenerFields] = [:]
        for (pid, pidPorts) in ports {
            result[pid] = ListenerFields(commandName: commands[pid] ?? "", ports: pidPorts)
        }
        return result
    }

    /// 兼容旧接口：只取端口集合
    static func parseListeners(_ output: String) -> [pid_t: Set<Int>] {
        parseListenerFields(output).mapValues { $0.ports }
    }

    /// n 字段形如 host:port（n*:57076 / n127.0.0.1:9884 / n[::1]:3000）：
    /// 端口取最后一个冒号之后的数字；主机部分出现 "/" 说明这是文件路径而非网络地址，丢弃
    static func port(fromNetworkField value: String) -> Int? {
        guard let separator = value.lastIndex(of: ":") else { return nil }
        guard let port = Int(value[value.index(after: separator)...]), (1...65535).contains(port) else { return nil }
        let host = value[..<separator]
        guard !host.isEmpty, !host.contains("/") else { return nil }
        return port
    }

    /// 可执行文件路径（公开 API libproc 的 proc_pidpath）：
    /// ps 不可用时的兜底，实证与 ps -o comm= 一致（如 /usr/libexec/rapportd），
    /// 用于系统守护进程过滤与 .app 包识别
    static func processExecutablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// 系统自带守护进程（/System、/usr/libexec、/usr/sbin、/sbin）不展示：
    /// 它们数量多、与开发场景无关，且结束后会被 launchd 自动拉起。
    /// 路径不可得时无法判定，不猜：保留条目，名称另有来源。
    private static func isSystemDaemon(_ executablePath: String?) -> Bool {
        guard let executablePath, !executablePath.isEmpty else { return false }
        return executablePath.hasPrefix("/System/") ||
            executablePath.hasPrefix("/usr/libexec/") ||
            executablePath.hasPrefix("/usr/sbin/") ||
            executablePath.hasPrefix("/sbin/")
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
    static let descriptor = ModuleDescriptor(id: "node", title: "进程监控", systemImage: "terminal",
        summary: "查看当前用户的监听端口与进程")

    func content() -> some View {
        NodeListView(scanner: self, settings: settings)
    }
    func settingsContent() -> some View { ProcessModuleSettingsView(settings: settings) }
}
