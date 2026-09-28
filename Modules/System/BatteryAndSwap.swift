import Darwin
import Foundation
import IOKit
import IOKit.ps

/// 电池与交换内存：IOKit 电源注册表 + IOPS 电源源接口 + sysctl（公开接口，无需权限）
///
/// 备注（探针实证）：
/// - 2026-09，macOS 26：GPU 使用率（IOReport 用户态框架已移除）与风扇转速（经典 SMC 协议失效）不可用
/// - 2026-09，macOS 27.2 (26B5091g) 复证风扇/温度：AppleSMC 服务存在、IOServiceOpen 成功，
///   但 KERNEL_INDEX_SMC 结构方法（READ_KEYINFO/READ_BYTES）返回 kIOReturnUnsupported，
///   PrivateFrameworks 仅剩空壳 SMCT.framework（无二进制）→ 风扇与温度传感器仍不可用；
///   温度的公开等价物为 ProcessInfo.thermalState 热压力档位（见 SystemMonitor）
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
        /// 设计循环上限（注册表 DesignCycleCount9C，回退 IOPS DesignCycleCount）；0 = 未知
        var designCycleCount: Int = 0
        /// 用电池的剩余时间（分钟）；0 = 系统尚未给出估算
        var timeToEmptyMinutes: Int = 0
        /// 充满所需时间（分钟）；0 = 系统尚未给出估算
        var timeToFullMinutes: Int = 0
        /// 电压（毫伏）/ 电流（毫安，放电为负）；0 = 未知
        var voltageMV: Int = 0
        var amperageMA: Int = 0
    }

    struct SwapInfo: Equatable {
        var usedBytes: UInt64 = 0
        var totalBytes: UInt64 = 0
    }

    /// 电池信息；台式机等无电池设备返回 nil
    ///
    /// macOS 27 起 mAh 容量键（AppleRawMaxCapacity 等）从顶层属性移入嵌套的 BatteryData
    /// 字典（探针实证 26B5091g），读取时先顶层、后嵌套，兼容旧系统
    static func readBattery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }
        let batteryData = props["BatteryData"] as? [String: Any]

        func int(_ key: String) -> Int {
            if let top = (props[key] as? NSNumber)?.intValue, top != 0 { return top }
            return (batteryData?[key] as? NSNumber)?.intValue ?? 0
        }
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
        info.voltageMV = int("Voltage")
        info.amperageMA = int("Amperage")
        info.designCycleCount = int("DesignCycleCount9C")
        let estimates = readTimeEstimates()
        info.timeToEmptyMinutes = estimates.toEmptyMinutes
        info.timeToFullMinutes = estimates.toFullMinutes
        if info.designCycleCount <= 0 {
            info.designCycleCount = estimates.designCycleCount
        }
        return info
    }

    static func readSwap() -> SwapInfo {
        // vm.swapusage 是二进制 xsw_usage 结构体（非字符串），直接按结构体读取
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return SwapInfo() }
        return SwapInfo(usedBytes: usage.xsu_used, totalBytes: usage.xsu_total)
    }

    // MARK: - IOPS 电源源估算（剩余时间 / 充满时间，powerd 维护，公开接口）

    private static func readTimeEstimates() -> (toEmptyMinutes: Int, toFullMinutes: Int, designCycleCount: Int) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] else {
            return (0, 0, 0)
        }
        func minutes(_ key: String) -> Int { max(0, (desc[key] as? NSNumber)?.intValue ?? 0) }
        var toEmpty = minutes("Time to Empty")
        let toFull = minutes("Time to Full Charge")
        // IOPSGetTimeRemainingEstimate 返回秒级估算，比描述字典的分钟值更精确；
        // -1（timeRemainingUnknown）= 尚未算出，保持 0 由展示层提示"估算中"
        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate > 0 {
            toEmpty = Int(estimate / 60 + 0.5)
        }
        let design = max(0, (desc["DesignCycleCount"] as? NSNumber)?.intValue ?? 0)
        return (toEmpty, toFull, design)
    }

    // MARK: - 展示辅助（纯函数，供回归测试）

    /// iStats 风格 h:mm；不足 1 分钟或无效返回 nil（>99 小时封顶显示）
    static func formatTime(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        guard minutes <= 99 * 60 + 59 else { return "99+ 小时" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// 电池时间估算的内联描述：
    /// 放电且已估出 → "剩余 3:24"；充电且已估出 → "1:12 充满"；其余（接电源未充电 / 尚未估出）→ nil
    static func timeDescription(isCharging: Bool, isPlugged: Bool,
                                timeToEmptyMinutes: Int, timeToFullMinutes: Int) -> String? {
        if isCharging, let full = formatTime(minutes: timeToFullMinutes) {
            return "\(full) 充满"
        }
        if !isCharging, !isPlugged, let empty = formatTime(minutes: timeToEmptyMinutes) {
            return "剩余 \(empty)"
        }
        return nil
    }

    /// 循环次数占设计上限的比例（0...1）；上限未知返回 nil
    static func cycleFraction(count: Int, design: Int) -> Double? {
        guard design > 0 else { return nil }
        return min(1, max(0, Double(count) / Double(design)))
    }

    /// 实时功率（瓦）：mV × mA / 1e6，取绝对值；任一读数缺失返回 nil
    static func watts(voltageMV: Int, amperageMA: Int) -> Double? {
        guard voltageMV > 0, amperageMA != 0 else { return nil }
        return abs(Double(voltageMV) * Double(amperageMA)) / 1_000_000
    }
}
