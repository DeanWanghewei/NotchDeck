import AppKit
import Combine
import Darwin
import SwiftUI

struct SystemStats {
    var cpuUsage: Double = 0        // 0...1
    /// 每核使用率（0...1，顺序为逻辑 CPU 编号；差分需要前一秒样本，首个周期为空）
    var cpuCores: [Double] = []
    /// 近一秒用户态（含 nice）/ 系统态占比（0...1）
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    /// 1 分钟平均负载（sysctl vm.loadavg）
    var loadAverage: Double = 0
    var memoryUsed: UInt64 = 0      // bytes
    var memoryTotal: UInt64 = 0     // bytes
    /// 内存构成（vm_statistics64 分页换算）：活跃（App）/ 联动 / 已压缩 / 已缓存（非活跃+投机）
    var memoryApp: UInt64 = 0
    var memoryWired: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var memoryCached: UInt64 = 0
    var diskUsed: UInt64 = 0        // bytes
    var diskTotal: UInt64 = 0       // bytes
    /// 各挂载卷用量（根卷在前）
    var volumes: [VolumeUsage] = []
    var networkUpload: Double = 0   // bytes/s
    var networkDownload: Double = 0 // bytes/s
    var swapUsed: UInt64 = 0        // bytes
    var swapTotal: UInt64 = 0       // bytes
    var battery: BatteryAndSwap.BatteryInfo?
    /// 系统热压力档位（温度的公开 API 等价物，SMC 温度键不可用）
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// 近 15 分钟 CPU 历史（每秒 1 个样本，最多 900 个）
    var cpuHistory: [Double] = []
}

/// 单个挂载卷的用量（NSFileManager 卷枚举，公开 API）
struct VolumeUsage: Equatable, Identifiable {
    let name: String
    let usedBytes: UInt64
    let totalBytes: UInt64
    var isRoot = false
    var id: String { name }

    /// 根卷在前，其余按名称排序（面板按此顺序展示）
    static func sorted(_ volumes: [VolumeUsage]) -> [VolumeUsage] {
        volumes.sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// CPU / 内存 / 磁盘 / 网络 / 交换内存 / 电池 / 热压力监控，每秒刷新
/// （host_processor_info + vm_statistics64 + NSFileManager 卷枚举 + sysctl NET_RT_IFLIST2
///  + IOKit 电源注册表 + IOPS 电源源估算）
final class SystemMonitor: ObservableObject {
    @Published private(set) var stats = SystemStats()
    /// GPU 使用率需要 IOReport 私有框架，macOS 15+ 已对用户态移除（探针实证），当前恒为不可用
    static let gpuAvailable = false
    /// 经典 SMC 用户客户端协议在当前系统已失效（探针实证），风扇转速暂不可用
    static let fansAvailable = false

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.notchdeck.system", qos: .utility)
    private let sampler = SystemSampler()
    private var generation = 0
    private var sampling = false

    func start() {
        guard timer == nil else { return }
        generation += 1
        queue.async { self.sampler.reset() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        sample()
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        let version = generation
        queue.async { [weak self] in
            guard let self else { return }
            let value = self.sampler.sample()
            DispatchQueue.main.async {
                self.sampling = false
                guard self.timer != nil, self.generation == version else { return }
                self.stats = value
            }
        }
    }
}

/// 所有采样状态仅由 SystemMonitor 的串行后台队列访问。
private final class SystemSampler {
    private var previousCoreTicks: [[UInt32]]?
    private var networkSample = NetworkRateSample()

    func reset() {
        previousCoreTicks = nil
        networkSample = NetworkRateSample()
    }

    func sample() -> SystemStats {
        var value = SystemStats()
        let cpu = sampleCPU()
        value.cpuUsage = cpu.usage
        value.cpuCores = cpu.cores
        value.cpuUser = cpu.user
        value.cpuSystem = cpu.system
        value.loadAverage = Self.sampleLoadAverage()
        let memory = sampleMemory()
        value.memoryUsed = memory.used
        value.memoryApp = memory.app
        value.memoryWired = memory.wired
        value.memoryCompressed = memory.compressed
        value.memoryCached = memory.cached
        value.memoryTotal = ProcessInfo.processInfo.physicalMemory
        (value.diskUsed, value.diskTotal) = sampleDisk()
        value.volumes = sampleVolumes()
        let rate = networkSample.update(Self.networkCounters(), at: ProcessInfo.processInfo.systemUptime)
        (value.networkUpload, value.networkDownload) = (rate.up, rate.down)
        let swap = BatteryAndSwap.readSwap()
        value.swapUsed = swap.usedBytes
        value.swapTotal = swap.totalBytes
        value.battery = BatteryAndSwap.readBattery()
        value.thermalState = ProcessInfo.processInfo.thermalState
        value.cpuHistory = Self.appendCpuHistory(value.cpuUsage, to: &cpuHistory)
        return value
    }

    /// 近 15 分钟历史（900 个样本，超出即淘汰最旧）
    private var cpuHistory: [Double] = []
    private static let historyLimit = 900
    static func appendCpuHistory(_ usage: Double, to history: inout [Double]) -> [Double] {
        history.append(usage)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        return history
    }

    // MARK: - CPU（host_processor_info 每核差分，iStat 同源）
    // 探针实证（macOS 27.2 / M1 Pro）：host_processor_info 不接受 HOST_CPU_LOAD_INFO
    // （host_statistics 的聚合 flavor），每核采样的正确 flavor 是 PROCESSOR_CPU_LOAD_INFO，
    // 缓冲区布局为每核 4 个 integer_t（user/system/idle/nice）；逻辑 CPU 编号与
    // hw.perflevel 对应——性能核（perflevel0）在前、能效核（perflevel1）在后。

    private func sampleCPU() -> (usage: Double, cores: [Double], user: Double, system: Double) {
        var coreCount: natural_t = 0
        var buffer: UnsafeMutablePointer<integer_t>?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &buffer, &infoCount) == KERN_SUCCESS,
              let ticks = buffer, coreCount > 0 else { return (0, [], 0, 0) }
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            current.append((0..<4).map { UInt32(ticks[core * 4 + $0]) })
        }
        vm_deallocate(mach_task_self_, vm_address_t(Int(bitPattern: ticks)),
                      vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        defer { previousCoreTicks = current }
        guard let previous = previousCoreTicks,
              let result = CPUSample.coreUsage(previous: previous, current: current) else {
            return (0, [], 0, 0)
        }
        return result
    }

    // MARK: - 内存（vm_statistics64：active + wired + compressed = 已用，近似活动监视器；
    // inactive + speculative ≈ 活动监视器的"已缓存文件"，可被系统回收）

    private func sampleMemory() -> (used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64) {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, 0, 0) }
        let page = UInt64(vm_page_size)
        let app = UInt64(vmStats.active_count) * page
        let wired = UInt64(vmStats.wire_count) * page
        let compressed = UInt64(vmStats.compressor_page_count) * page
        let cached = (UInt64(vmStats.inactive_count) + UInt64(vmStats.speculative_count)) * page
        return (app + wired + compressed, app, wired, compressed, cached)
    }

    // MARK: - 挂载卷（iStat 走 Disk Arbitration，公开等价物为 NSFileManager 卷枚举；
    // skipHiddenVolumes 排除 VM/Preboot 等系统隐藏挂载点）

    private func sampleVolumes() -> [VolumeUsage] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: .skipHiddenVolumes) else { return [] }
        var volumes: [VolumeUsage] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let free = max(0, values.volumeAvailableCapacity ?? 0)
            volumes.append(VolumeUsage(name: values.volumeName ?? url.lastPathComponent,
                                       usedBytes: UInt64(max(0, total - free)),
                                       totalBytes: UInt64(total),
                                       isRoot: url.path(percentEncoded: false) == "/"))
        }
        return Array(VolumeUsage.sorted(volumes).prefix(6))
    }

    // MARK: - 负载（sysctl vm.loadavg → loadavg.ldavg[0] / fscale，1 分钟均值）

    private static func sampleLoadAverage() -> Double {
        var load = loadavg()
        var size = MemoryLayout<loadavg>.stride
        guard sysctlbyname("vm.loadavg", &load, &size, nil, 0) == 0, load.fscale > 0 else { return 0 }
        return Double(load.ldavg.0) / Double(load.fscale)
    }

    // MARK: - 磁盘

    private func sampleDisk() -> (used: UInt64, total: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attributes[.systemSize] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber else {
            return (0, 0)
        }
        let totalValue = total.uint64Value
        let freeValue = free.uint64Value
        return (totalValue > freeValue ? totalValue - freeValue : 0, totalValue)
    }

    // MARK: - 网络：路由接口快照提供 64 位字节计数，避免 4 GB 回绕丢失流量。

    private static func networkCounters() -> [UInt16: NetworkCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return [:] }
        return bytes.withUnsafeBytes { buffer in
            var counters: [UInt16: NetworkCounter] = [:]
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                if header.ifm_type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0, message.ifm_flags & IFF_UP != 0 {
                        counters[message.ifm_index] = NetworkCounter(
                            inBytes: message.ifm_data.ifi_ibytes, outBytes: message.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
            return counters
        }
    }
}

struct NetworkCounter {
    let inBytes: UInt64
    let outBytes: UInt64
}

struct NetworkRateSample {
    private var previous: [UInt16: NetworkCounter] = [:]
    private var timestamp: TimeInterval?

    mutating func update(_ counters: [UInt16: NetworkCounter], at now: TimeInterval) -> (up: Double, down: Double) {
        defer { previous = counters; timestamp = now }
        guard let timestamp, now > timestamp, now - timestamp <= 5 else { return (0, 0) }
        var up = 0.0
        var down = 0.0
        for (id, current) in counters {
            guard let old = previous[id], current.inBytes >= old.inBytes,
                  current.outBytes >= old.outBytes else { continue }
            down += Double(current.inBytes - old.inBytes) / (now - timestamp)
            up += Double(current.outBytes - old.outBytes) / (now - timestamp)
        }
        return (up, down)
    }
}

enum CPUSample {
    static func usage(previous: [UInt32], current: [UInt32]) -> Double {
        guard previous.count == 4, current.count == 4 else { return 0 }
        let deltas = zip(current, previous).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return 0 }
        return 1 - Double(deltas[2]) / Double(total)
    }

    /// 每核 4-tick（user/system/idle/nice）差分：各核 busy + 全局占比（按 tick 加权，nice 计入用户态）。
    /// 核数不一致（唤醒重置等）返回 nil，本周期由调用方丢弃。
    static func coreUsage(previous: [[UInt32]], current: [[UInt32]])
        -> (usage: Double, cores: [Double], user: Double, system: Double)? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var cores: [Double] = []
        cores.reserveCapacity(current.count)
        var userTicks: UInt64 = 0
        var systemTicks: UInt64 = 0
        var idleTicks: UInt64 = 0
        var totalTicks: UInt64 = 0
        for (prev, cur) in zip(previous, current) {
            cores.append(usage(previous: prev, current: cur))
            let deltas = zip(cur, prev).map { UInt64($0 &- $1) }
            userTicks += deltas[0] + deltas[3]
            systemTicks += deltas[1]
            idleTicks += deltas[2]
            totalTicks += deltas.reduce(0, +)
        }
        guard totalTicks > 0 else { return nil }
        return (1 - Double(idleTicks) / Double(totalTicks), cores,
                Double(userTicks) / Double(totalTicks), Double(systemTicks) / Double(totalTicks))
    }
}

/// 热压力档位展示（ProcessInfo.ThermalState → 中文标签与提示）
enum ThermalPressure {
    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "适度"
        case .serious: return "重度"
        case .critical: return "严重"
        @unknown default: return "未知"
        }
    }

    /// 警示行是否需要显示（正常档不提示，避免常态噪音）
    static func needsWarning(_ state: ProcessInfo.ThermalState) -> Bool {
        state != .nominal
    }
}

// MARK: - 面板模块接入

extension SystemMonitor: NotchModule {
    var id: String { "system" }
    var title: String { "系统监控" }
    var systemImage: String { "chart.pie" }

    func content() -> some View {
        SystemMonitorView(monitor: self)
    }
}
