import SwiftUI

/// 系统监控：CPU / 内存 / 磁盘卡片 + 网络速率，悬停显示详细数值
struct SystemMonitorView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let stats = app.system.stats
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

    private var memoryProgress: Double {
        let stats = app.system.stats
        guard stats.memoryTotal > 0 else { return 0 }
        return min(1, Double(stats.memoryUsed) / Double(stats.memoryTotal))
    }

    private var diskProgress: Double {
        let stats = app.system.stats
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
