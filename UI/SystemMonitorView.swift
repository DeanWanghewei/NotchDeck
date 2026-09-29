import Darwin
import SwiftUI

/// 悬停详情类别：鼠标停在 CPU / 内存 / 磁盘卡片上展开对应明细，点击卡片可固定
enum StatDetailKind: Equatable {
    case cpu
    case memory
    case disk
}

/// 系统监控：CPU / 内存 / 磁盘卡片（悬停展开明细）+ CPU 热力图 + 交换内存 / 电池（含时间估算）
/// / 热压力警示 + 网络速率
struct SystemMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var settings = SettingsStore.shared
    @State private var hoveredKind: StatDetailKind?
    @State private var pinnedKind: StatDetailKind?

    /// initialPinnedDetail 仅供显示 QA / 预览注入初始固定状态，正常路径保持 nil
    init(monitor: SystemMonitor, initialPinnedDetail: StatDetailKind? = nil) {
        self.monitor = monitor
        _pinnedKind = State(initialValue: initialPinnedDetail)
    }

    private var activeDetail: StatDetailKind? { pinnedKind ?? hoveredKind }

    var body: some View {
        let stats = monitor.stats
        VStack(spacing: 10) {
            if settings.showThermalPressure, ThermalPressure.needsWarning(stats.thermalState) {
                thermalWarningRow(stats.thermalState)
            }

            statSection(stats)

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
        .animation(.easeInOut(duration: 0.2), value: activeDetail)
    }

    /// 卡片行 + 悬停展开的明细区。外层 onHover 统一收尾：鼠标离开整块区域才收起，
    /// 卡片之间的空隙与移入明细区本身都不触发收起；固定状态只由点击切换。
    private func statSection(_ stats: SystemStats) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                statCard(.cpu, label: "CPU",
                         value: ByteFormat.percent(stats.cpuUsage),
                         progress: stats.cpuUsage,
                         systemImage: "cpu")
                statCard(.memory, label: "内存",
                         value: ByteFormat.bytes(stats.memoryUsed),
                         progress: memoryProgress,
                         systemImage: "memorychip")
                statCard(.disk, label: "磁盘",
                         value: ByteFormat.bytes(stats.diskUsed),
                         progress: diskProgress,
                         systemImage: "internaldrive")
            }
            if let kind = activeDetail {
                StatDetailView(kind: kind, pinned: pinnedKind == kind, stats: stats)
                    .id(kind)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onHover { inside in
            if !inside { hoveredKind = nil }
        }
    }

    private func statCard(_ kind: StatDetailKind, label: String,
                          value: String, progress: Double, systemImage: String) -> some View {
        StatCard(label: label,
                 value: value,
                 progress: progress,
                 systemImage: systemImage,
                 highlighted: activeDetail == kind,
                 pinned: pinnedKind == kind)
            .onHover { hovering in
                if hovering { hoveredKind = kind }
            }
            .onTapGesture {
                pinnedKind = pinnedKind == kind ? nil : kind
            }
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
}

// MARK: - 悬停明细卡

/// 悬停 / 固定显示的明细卡：CPU 每核占用百分比（性能/能效核标注）、内存构成（含 swap）、磁盘各卷用量
private struct StatDetailView: View {
    let kind: StatDetailKind
    let pinned: Bool
    let stats: SystemStats

    /// 性能核数量（hw.perflevel0.logicalcpu，iStat 同源划分）；Intel 等无该键返回 nil → 不区分 P/E
    static let performanceCoreCount: Int? = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch kind {
            case .cpu: cpuContent
            case .memory: memoryContent
            case .disk: diskContent
            }
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(title)明细")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }

    private var title: String {
        switch kind {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        }
    }

    private var summary: String {
        switch kind {
        case .cpu:
            return "总体 \(ByteFormat.percent(stats.cpuUsage)) · \(stats.cpuCores.count) 核 · 负载 \(String(format: "%.2f", stats.loadAverage))"
        case .memory:
            let percent = stats.memoryTotal > 0
                ? ByteFormat.percent(Double(stats.memoryUsed) / Double(stats.memoryTotal))
                : "--"
            return "\(ByteFormat.bytes(stats.memoryUsed)) / \(ByteFormat.bytes(stats.memoryTotal))（\(percent)）"
        case .disk:
            return "\(stats.volumes.count) 个卷"
        }
    }

    // MARK: CPU：每核一行"核心名 + 用量条 + 百分比"，两列排布，一眼看出"1 核干活 N 核围观"

    private var cpuContent: some View {
        Group {
            if stats.cpuCores.isEmpty {
                Text("每核占用采样中…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                // 核多（Ultra 级 20+ 核）时收紧列宽换 3 列，避免明细区过长
                let minimum: CGFloat = stats.cpuCores.count > 16 ? 150 : 210
                let busiest = stats.cpuCores.enumerated().max(by: { $0.element < $1.element })?.offset
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8)], spacing: 6) {
                    ForEach(Array(stats.cpuCores.enumerated()), id: \.offset) { index, usage in
                        CoreRow(label: Self.coreLabel(index), usage: usage, isBusiest: index == busiest)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch kind {
            case .cpu:
                if let busiest = stats.cpuCores.enumerated().max(by: { $0.element < $1.element }) {
                    Text("最忙 \(Self.coreLabel(busiest.offset)) · \(ByteFormat.percent(busiest.element))")
                }
                Text("用户态 \(ByteFormat.percent(stats.cpuUser)) · 系统态 \(ByteFormat.percent(stats.cpuSystem))")
            case .memory:
                if stats.swapTotal > 0 {
                    Text("交换内存使用 \(ByteFormat.percent(Double(stats.swapUsed) / Double(stats.swapTotal)))")
                }
            case .disk:
                if let root = stats.volumes.first(where: \.isRoot) {
                    Text("可用 \(ByteFormat.bytes(root.totalBytes - root.usedBytes))")
                }
            }
            Spacer()
            Text(pinned ? "再次点击卡片取消固定" : "点击卡片可固定显示")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// 核心标签：性能核"核心 N"，能效核"能效 N"（perflevel0 = 性能核在前，探针实证见 SystemSampler）
    static func coreLabel(_ index: Int) -> String {
        guard let performanceCount = performanceCoreCount, index >= performanceCount else {
            return "核心 \(index + 1)"
        }
        return "能效 \(index - performanceCount + 1)"
    }

    // MARK: 内存：构成条目（配色近似活动监视器）+ swap

    private var memoryContent: some View {
        let total = Double(stats.memoryTotal)
        func fraction(_ bytes: UInt64) -> Double {
            total > 0 ? min(1, Double(bytes) / total) : 0
        }
        return VStack(spacing: 6) {
            BreakdownRow(label: "App 内存", bytes: stats.memoryApp,
                         fraction: fraction(stats.memoryApp), color: .blue)
            BreakdownRow(label: "联动", bytes: stats.memoryWired,
                         fraction: fraction(stats.memoryWired), color: .orange)
            BreakdownRow(label: "已压缩", bytes: stats.memoryCompressed,
                         fraction: fraction(stats.memoryCompressed), color: .yellow)
            BreakdownRow(label: "已缓存", bytes: stats.memoryCached,
                         fraction: fraction(stats.memoryCached), color: .green, note: "可回收")
            if stats.swapTotal > 0 {
                BreakdownRow(label: "交换 swap", bytes: stats.swapUsed,
                             fraction: min(1, Double(stats.swapUsed) / Double(stats.swapTotal)),
                             color: .purple, note: "/ \(ByteFormat.bytes(stats.swapTotal))")
            } else {
                BreakdownRow(label: "交换 swap", bytes: nil, fraction: 0, color: .purple, note: "未启用")
            }
        }
    }

    // MARK: 磁盘：各挂载卷用量

    private var diskContent: some View {
        Group {
            if stats.volumes.isEmpty {
                Text("未发现可用卷")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 8) {
                    ForEach(stats.volumes) { volume in
                        VolumeRow(volume: volume)
                    }
                }
            }
        }
    }
}

/// 单核一行：核心名 + 用量条 + 百分比数字。条色走冷→暖色标（低负载冷蓝、高负载暖红），
/// 最忙核数字加粗；百分比仅在暖区（≥0.7，黄/橙/红）着色，冷区保持次要灰避免蓝字噪音。
private struct CoreRow: View {
    let label: String
    let usage: Double
    var isBusiest: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(HeatScale.color(usage))
                        .frame(width: max(2, proxy.size.width * min(1, max(0, usage))))
                }
            }
            .frame(height: 5)
            Text(ByteFormat.percent(usage))
                .font(.system(size: 9, weight: isBusiest ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(usage >= 0.7 ? HeatScale.color(usage) : Color.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// 明细行：标签 + 用量条 + 字节数（内存构成复用）；bytes 为 nil 时仅显示 note（如"未启用"）
private struct BreakdownRow: View {
    let label: String
    var bytes: UInt64?
    let fraction: Double
    var color: Color
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 5)
            HStack(spacing: 4) {
                if let bytes {
                    Text(ByteFormat.bytes(bytes))
                }
                if let note {
                    Text(note)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 110, alignment: .trailing)
            .lineLimit(1)
        }
    }
}

/// 单个挂载卷：名称 + 用量条 + 概要（已用 / 共 / 可用）
private struct VolumeRow: View {
    let volume: VolumeUsage

    var body: some View {
        let fraction = volume.totalBytes > 0
            ? Double(volume.usedBytes) / Double(volume.totalBytes) : 0
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: volume.isRoot ? "internaldrive" : "externaldrive")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(volume.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("已用 \(ByteFormat.bytes(volume.usedBytes)) / \(ByteFormat.bytes(volume.totalBytes)) · 可用 \(ByteFormat.bytes(volume.totalBytes - volume.usedBytes))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(ByteFormat.percent(fraction))
                    .foregroundStyle(.primary)
            }
            .font(.caption2)
            .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(fraction > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let progress: Double
    let systemImage: String
    var highlighted: Bool = false
    var pinned: Bool = false

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
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
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
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(highlighted ? 0.55 : 0), lineWidth: 1.5)
        )
    }

    private var barStyle: AnyShapeStyle {
        if progress > 0.85 {
            return AnyShapeStyle(Color.orange.gradient)
        }
        return AnyShapeStyle(LinearGradient(colors: [.purple, .blue],
                                            startPoint: .leading, endPoint: .trailing))
    }
}
