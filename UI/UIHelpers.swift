import AppKit
import SwiftUI

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
