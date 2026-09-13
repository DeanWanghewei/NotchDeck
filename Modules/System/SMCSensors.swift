import Darwin
import Foundation
import IOKit

/// 电池与交换内存：IOKit 电源注册表 + sysctl（公开接口，无需权限）
///
/// 备注（探针实证，2026-09，macOS 26）：
/// - GPU 使用率：IOReport 用户态框架已整体移除（共享缓存无符号、私有框架文件不存在），
///   IOGPUDevice 注册表亦无利用率统计 → GPU 数据不可用
/// - 风扇转速：经典 AppleSMC 用户客户端结构协议已失效（GetKeyInfo 返回 key-not-found，
///   Read 返回全零），注册表无实时转速 → 风扇数据暂不可用
///   两者未来恢复时，在 SystemMonitor.gpuAvailable / fansAvailable 与采样处接入即可
enum BatteryAndSwap {
    struct BatteryInfo: Equatable {
        var percent: Double = 0
        var isCharging = false
        var isPlugged = false
        var currentmAh: Int = 0
        var maxmAh: Int = 0
        var designmAh: Int = 0
        var cycleCount: Int = 0
    }

    struct SwapInfo: Equatable {
        var usedBytes: UInt64 = 0
        var totalBytes: UInt64 = 0
    }

    /// 电池信息；台式机等无电池设备返回 nil
    static func readBattery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int { (props[key] as? NSNumber)?.intValue ?? 0 }
        let maxCapacity = int("AppleRawMaxCapacity")
        let currentCapacity = int("AppleRawCurrentCapacity")
        guard maxCapacity > 0 else { return nil }
        var info = BatteryInfo()
        info.percent = Double(currentCapacity) / Double(maxCapacity) * 100
        info.isCharging = (props["IsCharging"] as? NSNumber)?.boolValue ?? false
        info.isPlugged = (props["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        info.currentmAh = currentCapacity
        info.maxmAh = maxCapacity
        info.designmAh = int("DesignCapacity")
        info.cycleCount = int("CycleCount")
        return info
    }

    static func readSwap() -> SwapInfo {
        // vm.swapusage 是二进制 xsw_usage 结构体（非字符串），直接按结构体读取
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return SwapInfo() }
        return SwapInfo(usedBytes: usage.xsu_used, totalBytes: usage.xsu_total)
    }
}
