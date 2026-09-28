import SwiftUI

/// 系统监控：CPU / 内存 / 磁盘卡片 + CPU 热力图 + 交换内存 / 电池（含时间估算）/ 热压力警示 + 网络速率
struct SystemMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let stats = monitor.stats
        VStack(spacing: 10) {
            if settings.showThermalPressure, ThermalPressure.needsWarning(stats.thermalState) {
                thermalWarningRow(stats.thermalState)
            }

            HStack(spacing: 10) {
                StatCard(label: "CPU",
                         value: ByteFormat.percent(stats.cpuUsage),
                         progress: stats.cpuUsage,
                         systemImage: "cpu")
                    .help("CPU 使用率 \(ByteFormat.percent(stats.cpuUsage))\n热压力：\(ThermalPressure.label(stats.thermalState))")
                StatCard(label: "内存",
                         value: ByteFormat.bytes(stats.memoryUsed),
                         progress: memoryProgress,
                         systemImage: "memorychip")
                    .help(memoryDetail(stats))
                StatCard(label: "磁盘",
                         value: ByteFormat.bytes(stats.diskUsed),
                         progress: diskProgress,
                         systemImage: "internaldrive")
                    .help(diskDetail(stats))
            }

            if settings.showCPUHeatmap {
                VStack(spacing: 5) {
                    UsageAreaChart(label: "CPU", samples: stats.cpuHistory)
                    HStack(spacing: 5) {
                        Text("GPU")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                        Text("此系统版本不提供 GPU 使用率")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(height: 13)
                }
                .help("近 15 分钟 CPU 使用率走势，右侧为最新")
            }

            if settings.showSwap || settings.showBattery {
                HStack(spacing: 14) {
                    if settings.showSwap, stats.swapTotal > 0 {
                        Label("\(ByteFormat.bytes(stats.swapUsed)) / \(ByteFormat.bytes(stats.swapTotal))",
                              systemImage: "arrow.triangle.swap")
                            .help("交换内存（压缩后的 swap）：已用 / 总量")
                    }
                    if settings.showBattery, let battery = stats.battery {
                        batteryInline(battery)
                            .help(batteryHelp(battery))
                    }
                    Spacer()
                    Text("网络 \(ByteFormat.rate(stats.networkDownload)) ↓")
                        .foregroundStyle(.green)
                    Text("\(ByteFormat.rate(stats.networkUpload)) ↑")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .monospacedDigit()
            } else {
                HStack(spacing: 16) {
                    Label(ByteFormat.rate(stats.networkDownload), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                    Label(ByteFormat.rate(stats.networkUpload), systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("网络")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.showCPUHeatmap)
        .animation(.easeInOut(duration: 0.25), value: monitor.stats.thermalState)
    }

    /// 热压力警示行：仅非正常档显示（温度/风扇不可用时，这是系统过热降速的唯一公开信号）
    private func thermalWarningRow(_ state: ProcessInfo.ThermalState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state == .critical ? "thermometer.high" : "thermometer.medium")
            Text("热压力：\(ThermalPressure.label(state)) · 系统可能已降低性能")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(state == .critical ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.orange))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background((state == .critical ? Color.red : Color.orange).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7))
        .help("系统热压力 \(ThermalPressure.label(state))（公开 API 仅提供档位，无具体温度）。持续高负载、高温环境或充电时可能触发，系统会降低 CPU/GPU 性能。")
    }

    /// 电池内联信息：空间不足时优先保留 时间估算 与 循环次数，容量降级省略
    @ViewBuilder
    private func batteryInline(_ battery: BatteryAndSwap.BatteryInfo) -> some View {
        let timeDescription = BatteryAndSwap.timeDescription(
            isCharging: battery.isCharging, isPlugged: battery.isPlugged,
            timeToEmptyMinutes: battery.timeToEmptyMinutes, timeToFullMinutes: battery.timeToFullMinutes)
        let cycles = battery.designCycleCount > 0
            ? "\(battery.cycleCount)/\(battery.designCycleCount) 循环"
            : (battery.cycleCount > 0 ? "\(battery.cycleCount) 循环" : "")
        ViewThatFits(in: .horizontal) {
            batteryParts(battery, time: timeDescription, cycles: cycles, capacity: true)
            batteryParts(battery, time: timeDescription, cycles: cycles, capacity: false)
        }
    }

    private func batteryParts(_ battery: BatteryAndSwap.BatteryInfo,
                              time: String?, cycles: String, capacity: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: battery.isPlugged
                  ? (battery.isCharging ? "battery.100.bolt" : "battery.100")
                  : "battery.\(min(100, Int(battery.percent / 25) * 25))")
            Text("\(Int(battery.percent.rounded()))%")
            if capacity, battery.maxmAh > 0 {
                Text("· \(battery.currentmAh)/\(battery.maxmAh) mAh")
                    .foregroundStyle(.tertiary)
            }
            if let time {
                Text("· \(time)")
                    .foregroundStyle(.secondary)
            } else if battery.isCharging {
                Text("· 充满 估算中")
                    .foregroundStyle(.tertiary)
            } else if !battery.isPlugged {
                Text("· 剩余 估算中")
                    .foregroundStyle(.tertiary)
            }
            if !cycles.isEmpty {
                Text("· \(cycles)")
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }

    private func batteryHelp(_ battery: BatteryAndSwap.BatteryInfo) -> String {
        var lines = ["电量 \(Int(battery.percent.rounded()))%（\(battery.isCharging ? "充电中" : battery.isPlugged ? "已接电源" : "使用电池")）"]
        if battery.maxmAh > 0 {
            lines.append("当前容量 \(battery.currentmAh) / 满充容量 \(battery.maxmAh) mAh")
        }
        if let time = BatteryAndSwap.timeDescription(
            isCharging: battery.isCharging, isPlugged: battery.isPlugged,
            timeToEmptyMinutes: battery.timeToEmptyMinutes, timeToFullMinutes: battery.timeToFullMinutes) {
            lines.append("预计 \(time)")
        }
        if battery.designmAh > 0 {
            lines.append("设计容量 \(battery.designmAh) mAh，健康度 \(Int(Double(battery.maxmAh) / Double(battery.designmAh) * 100))%")
        }
        if battery.cycleCount > 0 {
            if let fraction = BatteryAndSwap.cycleFraction(count: battery.cycleCount, design: battery.designCycleCount) {
                lines.append("循环次数 \(battery.cycleCount) / 设计上限 \(battery.designCycleCount)（已用 \(String(format: "%.1f%%", fraction * 100))）")
            } else {
                lines.append("循环次数 \(battery.cycleCount)")
            }
        }
        if battery.voltageMV > 0 || battery.amperageMA != 0 {
            var electrical = "电压 \(String(format: "%.2f", Double(battery.voltageMV) / 1000)) V"
            if battery.amperageMA != 0 {
                electrical += " · 电流 \(battery.amperageMA > 0 ? "" : "-")\(abs(battery.amperageMA)) mA"
                if let watts = BatteryAndSwap.watts(voltageMV: battery.voltageMV, amperageMA: battery.amperageMA) {
                    electrical += " · 功率 \(String(format: "%.1f", watts)) W（\(battery.isCharging ? "充入" : "输出")）"
                }
            }
            lines.append(electrical)
        }
        return lines.joined(separator: "\n")
    }

    private var memoryProgress: Double {
        let stats = monitor.stats
        guard stats.memoryTotal > 0 else { return 0 }
        return min(1, Double(stats.memoryUsed) / Double(stats.memoryTotal))
    }

    private var diskProgress: Double {
        let stats = monitor.stats
        guard stats.diskTotal > 0 else { return 0 }
        return min(1, Double(stats.diskUsed) / Double(stats.diskTotal))
    }

    private func memoryDetail(_ stats: SystemStats) -> String {
        let percent = stats.memoryTotal > 0
            ? ByteFormat.percent(Double(stats.memoryUsed) / Double(stats.memoryTotal))
            : "--"
        return "内存 \(ByteFormat.bytes(stats.memoryUsed)) / \(ByteFormat.bytes(stats.memoryTotal))（\(percent)）"
    }

    private func diskDetail(_ stats: SystemStats) -> String {
        let percent = stats.diskTotal > 0
            ? ByteFormat.percent(Double(stats.diskUsed) / Double(stats.diskTotal))
            : "--"
        return "磁盘 \(ByteFormat.bytes(stats.diskUsed)) / \(ByteFormat.bytes(stats.diskTotal))（\(percent)）"
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let progress: Double
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(barStyle)
                        .frame(width: max(3, proxy.size.width * min(1, max(0, progress))))
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var barStyle: AnyShapeStyle {
        if progress > 0.85 {
            return AnyShapeStyle(Color.orange.gradient)
        }
        return AnyShapeStyle(LinearGradient(colors: [.purple, .blue],
                                            startPoint: .leading, endPoint: .trailing))
    }
}
