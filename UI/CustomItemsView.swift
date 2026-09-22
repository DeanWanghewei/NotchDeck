import SwiftUI

/// 自定义子项：执行用户定义的 shell 命令，按子项选择的展示方式渲染输出
struct CustomItemsView: View {
    @ObservedObject var module: CustomItemsModule
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(settings.customItems) { item in
                itemCard(item)
            }
            HStack(spacing: 6) {
                if module.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("执行中…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    module.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(ScalingButtonStyle())
                .foregroundStyle(.secondary)
                .help("重新执行")
                Text("在设置中添加 / 编辑子项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func itemCard(_ item: CustomItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
            }
            itemBody(item)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    /// 文本子项原样显示输出；热力图子项解析出数值后渲染着色方格，
    /// 解析失败或命令出错时回退为文本，保证错误信息仍然可见。
    @ViewBuilder
    private func itemBody(_ item: CustomItem) -> some View {
        switch item.display {
        case .text:
            outputText(module.output(for: item) ?? "…")
        case .heatmap:
            if let values = module.samples[item.id], !values.isEmpty {
                CustomHeatmapView(values: values, rawText: module.output(for: item))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    outputText(module.output(for: item) ?? "…")
                    if module.unparsedHeatmapIDs.contains(item.id) {
                        Text("执行成功，但输出中没有解析到数字（需空格 / 逗号 / 换行分隔）")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func outputText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(6)
            .foregroundStyle(.primary.opacity(0.85))
    }
}

/// 热力图：数值序列渲染为按行排列的着色方格（类 GitHub 贡献图），颜色越深数值越高；
/// 失败样本（命令非 0 退出或超时）渲染为红色方格。多行布局从左到右、从上到下推进，最右下角为最新样本。
struct CustomHeatmapView: View {
    let values: [CustomItemsModule.CustomHeatmapSample]
    /// 悬停提示展示的命令原始输出
    var rawText: String?

    /// 每行方格数与最大行数：30 列 × 3 行以内可完整放进面板内容区
    private static let columns = 30
    private static let maxRows = 3
    private static let cellSize: CGFloat = 10
    private static let cellSpacing: CGFloat = 2
    /// 由浅到深的 5 档绿色；数值全部相等时取最深档
    static let levelOpacities: [Double] = [0.15, 0.32, 0.5, 0.7, 0.9]
    /// 失败样本的红色
    private static let failureColor = Color.red.opacity(0.85)

    private var displayed: [CustomItemsModule.CustomHeatmapSample] {
        Array(values.suffix(Self.columns * Self.maxRows))
    }

    private var numericValues: [Double] {
        displayed.compactMap(\.value)
    }

    private var rows: [[CustomItemsModule.CustomHeatmapSample]] {
        stride(from: 0, to: displayed.count, by: Self.columns).map {
            Array(displayed[$0..<min($0 + Self.columns, displayed.count)])
        }
    }

    private var range: (min: Double, max: Double)? {
        guard let minimum = numericValues.min(), let maximum = numericValues.max() else { return nil }
        return (minimum, maximum)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: Self.cellSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Self.cellSpacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, sample in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color(for: sample))
                                .frame(width: Self.cellSize, height: Self.cellSize)
                        }
                    }
                }
            }
            .help(helpText)
            HStack(spacing: 8) {
                Text(summary)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 2) {
                    Text("低")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    ForEach(Self.levelOpacities, id: \.self) { opacity in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.green.opacity(opacity))
                            .frame(width: 7, height: 7)
                    }
                    Text("高")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Self.failureColor)
                        .frame(width: 7, height: 7)
                    Text("失败")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: values)
    }

    private func color(for sample: CustomItemsModule.CustomHeatmapSample) -> Color {
        guard let value = sample.value, let range else { return Self.failureColor }
        return Color.green.opacity(
            Self.levelOpacities[Self.levelIndex(for: value, minimum: range.min, maximum: range.max)])
    }

    /// 数值 → 色档：区间内线性分档，最小值取 0 档（最浅），最大值取最末档（最深）；
    /// 全部相等时取最深档。独立成纯函数以便测试方向不颠倒。
    static func levelIndex(for value: Double, minimum: Double, maximum: Double) -> Int {
        guard maximum > minimum else { return levelOpacities.count - 1 }
        let fraction = (value - minimum) / (maximum - minimum)
        return min(levelOpacities.count - 1, max(0, Int(fraction * Double(levelOpacities.count - 1))))
    }

    private var summary: String {
        var parts: [String] = []
        if let last = displayed.last {
            parts.append(last.value.map { "最新 \(Self.format($0))" } ?? "最新 失败")
        }
        if let range {
            parts.append("高 \(Self.format(range.max))")
            parts.append("低 \(Self.format(range.min))")
        }
        let failures = displayed.filter { $0.value == nil }.count
        if failures > 0 { parts.append("失败 \(failures)") }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines = ["共 \(values.count) 个样本，绿色由浅到深表示数值由低到高，红色为失败（命令非 0 退出或超时），右下角为最新样本"]
        if let rawText, !rawText.isEmpty {
            lines.append("原始输出：\(rawText.prefix(400))")
        }
        return lines.joined(separator: "\n")
    }

    /// 按量级选择小数位，秒级时延（如 0.023）与百分比 / 计数都能读
    static func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if value == value.rounded(), magnitude < 1e9 { return String(Int(value)) }
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 10 { return String(format: "%.1f", value) }
        if magnitude >= 1 { return String(format: "%.2f", value) }
        return String(format: "%.3f", value)
    }
}
