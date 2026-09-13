import SwiftUI

/// 系统监控：CPU / 内存 / 磁盘卡片 + CPU 热力图 + 交换内存 / 电池 + 网络速率
struct SystemMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let stats = monitor.stats
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(label: "CPU",
                         value: ByteFormat.percent(stats.cpuUsage),
                         progress: stats.cpuUsage,
                         systemImage: "cpu")
                    .help("CPU 使用率 \(ByteFormat.percent(stats.cpuUsage))")
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
                    UsageHeatmap(label: "CPU", samples: stats.cpuHistory)
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
                .help("近 15 分钟使用率，每列约 15 秒")
            }

            if settings.showSwap || settings.showBattery {
                HStack(spacing: 14) {
                    if settings.showSwap, stats.swapTotal > 0 {
                        Label("\(ByteFormat.bytes(stats.swapUsed)) / \(ByteFormat.bytes(stats.swapTotal))",
                              systemImage: "arrow.triangle.swap")
                            .help("交换内存（压缩后的 swap）：已用 / 总量")
                    }
                    if settings.showBattery, let battery = stats.battery {
                        HStack(spacing: 4) {
                            Image(systemName: battery.isPlugged
                                  ? (battery.isCharging ? "battery.100.bolt" : "battery.100")
                                  : "battery.\(min(100, Int(battery.percent / 25) * 25))")
                            Text("\(Int(battery.percent.rounded()))%")
                            Text("· \(battery.currentmAh)/\(battery.maxmAh) mAh")
                                .foregroundStyle(.tertiary)
                            if battery.cycleCount > 0 {
                                Text("· \(battery.cycleCount) 循环")
                                    .foregroundStyle(.tertiary)
                            }
                        }
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
    }

    private func batteryHelp(_ battery: BatteryAndSwap.BatteryInfo) -> String {
        var lines = ["电量 \(Int(battery.percent.rounded()))%（\(battery.isCharging ? "充电中" : battery.isPlugged ? "已接电源" : "使用电池")）",
                     "当前容量 \(battery.currentmAh) / 满充容量 \(battery.maxmAh) mAh"]
        if battery.designmAh > 0 {
            lines.append("设计容量 \(battery.designmAh) mAh，健康度 \(Int(Double(battery.maxmAh) / Double(battery.designmAh) * 100))%")
        }
        if battery.cycleCount > 0 {
            lines.append("循环次数 \(battery.cycleCount)")
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
