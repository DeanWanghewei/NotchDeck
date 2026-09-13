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

/// 15 分钟使用率折线阴影图：折线 + 渐变填充，右侧为最新样本
struct UsageAreaChart: View {
    let label: String
    let samples: [Double]
    var height: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            chart
                .frame(height: height)
            VStack(alignment: .trailing, spacing: 0) {
                Text(currentText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                Text("15min")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 40, alignment: .trailing)
        }
    }

    private var chart: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                areaPath(in: size)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.38),
                                                  Color.accentColor.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                linePath(in: size)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = samples.last, !samples.isEmpty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                        .position(x: size.width, y: (1 - min(1, max(0, last))) * size.height)
                }
            }
        }
    }

    /// 样本映射为图表点（右侧为最新；x 相对样本序号均分）
    private func chartPoints(in size: CGSize) -> [CGPoint] {
        let values = samples.map { min(1, max(0, $0)) }
        guard values.count > 1 else {
            return [CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: (1 - value) * size.height)
        }
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        let points = chartPoints(in: size)
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }

    private func areaPath(in size: CGSize) -> Path {
        var path = linePath(in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private var currentText: String {
        guard let last = samples.last else { return "--" }
        return String(format: "%.0f%%", last * 100)
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
