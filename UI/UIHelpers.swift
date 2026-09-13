import AppKit
import SwiftUI

/// 仅底部圆角：接壤模式下与刘海延伸带连成一体（macOS 13+ 内建 UnevenRoundedRectangle）
func bottomRoundedRectangle(radius: CGFloat) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 0,
                           bottomLeadingRadius: radius,
                           bottomTrailingRadius: radius,
                           topTrailingRadius: 0,
                           style: .continuous)
}

/// 毛玻璃背景（NSVisualEffectView，behindWindow 混合）
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// 仅底部圆角的矩形：顶部与刘海融合，底部圆角收尾
struct BottomRoundedRectangle: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > cornerRadius * 2, rect.height > cornerRadius else {
            return Path(CGRect(origin: .zero, size: rect.size))
        }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - cornerRadius))
        path.addArc(tangent1End: CGPoint(x: 0, y: rect.maxY),
                    tangent2End: CGPoint(x: cornerRadius, y: rect.maxY),
                    radius: cornerRadius)
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius),
                    radius: cornerRadius)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.closeSubpath()
        return path
    }
}

/// 15 分钟使用率热力图：样本降采样为 60 列，颜色随占用率从青到红
struct UsageHeatmap: View {
    let label: String
    let samples: [Double]
    /// 采样间隔（秒），用于列数计算
    var sampleInterval: Double = 1
    var columns: Int = 60

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            HStack(spacing: 1.5) {
                ForEach(0..<columns, id: \.self) { column in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(cellColor(value(sample: column)))
                        .frame(height: 13)
                }
            }
            Text(currentText)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// 每列聚合最近一段样本的平均值
    private func value(sample column: Int) -> Double {
        let perColumn = max(1, Int(900.0 / Double(columns)))
        let filled = samples.count
        // 右侧为最新：空列（尚无数据）显示为近零
        let end = filled - (columns - 1 - column) * perColumn
        let start = end - perColumn
        guard end > 0 else { return 0 }
        let slice = samples[max(0, start)..<max(0, end)]
        guard !slice.isEmpty else { return 0 }
        return slice.reduce(0, +) / Double(slice.count)
    }

    private var currentText: String {
        guard let last = samples.last else { return "--" }
        return String(format: "%.0f%%", last * 100)
    }

    private func cellColor(_ value: Double) -> Color {
        let v = min(1, max(0, value))
        if v < 0.03 { return Color.primary.opacity(0.08) }
        // 青(0.45) → 红(0)：占用率越高色相越暖
        return Color(hue: 0.45 * (1 - v), saturation: 0.75, brightness: 0.9)
    }
}

/// "已适配"标记：白名单 App 专用徽章
struct AdaptedBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 8))
            Text("已适配")
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .foregroundStyle(Color.accentColor)
        .help("该应用已深度适配 NotchDeck（如媒体控制等能力）")
    }
}

/// 按压缩放反馈的图标按钮样式
struct ScalingButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// 面板展开/收起的弹性过渡
extension AnyTransition {
    static let panelExpand: AnyTransition = .asymmetric(
        insertion: .opacity
            .combined(with: .scale(scale: 0.96, anchor: .top))
            .combined(with: .offset(y: -6)),
        removal: .opacity
            .combined(with: .scale(scale: 0.97, anchor: .top)))

    /// 标签页内容切换：新页自右侧滑入，旧页淡出左移
    static let tabSwitch: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(x: 16)),
        removal: .opacity.combined(with: .offset(x: -10)))
}

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        formatter.string(fromByteCount: Int64(value))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 KB/s" }
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
