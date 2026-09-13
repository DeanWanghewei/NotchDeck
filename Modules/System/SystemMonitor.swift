import AppKit
import Combine
import Darwin
import SwiftUI

struct SystemStats {
    var cpuUsage: Double = 0        // 0...1
    var memoryUsed: UInt64 = 0      // bytes
    var memoryTotal: UInt64 = 0     // bytes
    var diskUsed: UInt64 = 0        // bytes
    var diskTotal: UInt64 = 0       // bytes
    var networkUpload: Double = 0   // bytes/s
    var networkDownload: Double = 0 // bytes/s
    var swapUsed: UInt64 = 0        // bytes
    var swapTotal: UInt64 = 0       // bytes
    var battery: BatteryAndSwap.BatteryInfo?
    /// 近 15 分钟 CPU 历史（每秒 1 个样本，最多 900 个）
    var cpuHistory: [Double] = []
}

/// CPU / 内存 / 磁盘 / 网络 / 交换内存 / 电池监控，每秒刷新
/// （host_statistics + sysctl NET_RT_IFLIST2 + IOKit 电源注册表）
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
    private var previousCPUTicks: [UInt32]?
    private var networkSample = NetworkRateSample()

    func reset() {
        previousCPUTicks = nil
        networkSample = NetworkRateSample()
    }

    func sample() -> SystemStats {
        var value = SystemStats()
        value.cpuUsage = sampleCPU()
        value.memoryUsed = sampleMemoryUsed()
        value.memoryTotal = ProcessInfo.processInfo.physicalMemory
        (value.diskUsed, value.diskTotal) = sampleDisk()
        let rate = networkSample.update(Self.networkCounters(), at: ProcessInfo.processInfo.systemUptime)
        (value.networkUpload, value.networkDownload) = (rate.up, rate.down)
        let swap = BatteryAndSwap.readSwap()
        value.swapUsed = swap.usedBytes
        value.swapTotal = swap.totalBytes
        value.battery = BatteryAndSwap.readBattery()
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

    // MARK: - CPU（host_statistics64 HOST_CPU_LOAD_INFO 差分）

    private func sampleCPU() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3]
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks else { return 0 }
        return CPUSample.usage(previous: previous, current: ticks)
    }

    // MARK: - 内存（vm_statistics64：active + wired + compressed，近似活动监视器）

    private func sampleMemoryUsed() -> UInt64 {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_page_size)
        let usedPages = UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.compressor_page_count)
        return usedPages * pageSize
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
