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
        formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
