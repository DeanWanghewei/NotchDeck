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
}

/// CPU / 内存 / 磁盘 / 网络监控，每秒刷新（原生 API：host_statistics64 + sysctl + getifaddrs）
final class SystemMonitor: ObservableObject {
    @Published private(set) var stats = SystemStats()

    private var timer: Timer?
    private var previousCPUTicks: (idle: UInt64, total: UInt64)?
    private var previousNetwork: (up: UInt64, down: UInt64)?
    private var totalMemory: UInt64 = 0

    func start() {
        guard timer == nil else { return }
        totalMemory = Self.queryTotalMemory() ?? 0
        sampleCpuAndNetwork() // 建立基线，首次采样返回 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        var newStats = SystemStats()
        newStats.cpuUsage = sampleCPU()
        newStats.memoryUsed = sampleMemoryUsed()
        newStats.memoryTotal = totalMemory
        (newStats.diskUsed, newStats.diskTotal) = sampleDisk()
        (newStats.networkUpload, newStats.networkDownload) = sampleNetwork()
        stats = newStats
    }

    /// 首次调用建立基线，随后采样先记网络计数
    private func sampleCpuAndNetwork() {
        _ = sampleCPU()
        _ = sampleNetwork()
    }

    // MARK: - CPU（host_statistics64 HOST_CPU_LOAD_INFO 差分）

    private func sampleCPU() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        let total = user + system + idle + nice
        defer { previousCPUTicks = (idle, total) }
        guard let previous = previousCPUTicks else { return 0 }

        let deltaTotal = Double(total - previous.total)
        guard deltaTotal > 0 else { return 0 }
        let deltaIdle = Double(idle - previous.idle)
        return min(max(0, 1 - deltaIdle / deltaTotal), 1)
    }

    // MARK: - 内存（vm_statistics64：active + wired + compressed，近似活动监视器）

    private func sampleMemoryUsed() -> UInt64 {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_page_size)
        let usedPages = UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.compressor_page_count)
        return usedPages * pageSize
    }

    private static func queryTotalMemory() -> UInt64? {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &size, &length, nil, 0)
        return result == 0 ? size : nil
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

    // MARK: - 网络（getifaddrs 计数差分，排除回环接口）

    private func sampleNetwork() -> (up: Double, down: Double) {
        let counters = Self.networkCounters()
        defer { previousNetwork = counters }
        guard let previous = previousNetwork else { return (0, 0) }
        let upload = Double(counters.up &- previous.up)
        let download = Double(counters.down &- previous.down)
        return (max(0, upload), max(0, download))
    }

    private static func networkCounters() -> (up: UInt64, down: UInt64) {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return (0, 0) }
        defer { freeifaddrs(interfaceList) }

        var up: UInt64 = 0
        var down: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }

            guard let sockaddr = interface.ifa_addr else { continue }
            let family = sockaddr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            guard String(cString: interface.ifa_name) != "lo0" else { continue }
            guard let dataPointer = interface.ifa_data else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(data.ifi_ibytes)
            up += UInt64(data.ifi_obytes)
        }
        return (up, down)
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
