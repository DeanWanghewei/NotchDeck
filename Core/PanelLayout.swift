import AppKit
import Combine

/// 窗口、轮廓与悬停检测共享同一份屏幕数据，不依赖 macOS 版本号或固定菜单栏高度。
struct PanelScreenGeometry {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var menuBarThickness: CGFloat
    var auxiliaryTopLeftArea: CGRect = .zero
    var auxiliaryTopRightArea: CGRect = .zero

    init(screen: NSScreen) {
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        safeAreaTop = screen.safeAreaInsets.top
        menuBarThickness = NSStatusBar.system.thickness
        auxiliaryTopLeftArea = screen.auxiliaryTopLeftArea ?? .zero
        auxiliaryTopRightArea = screen.auxiliaryTopRightArea ?? .zero
    }

    init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
         menuBarThickness: CGFloat,
         auxiliaryTopLeftArea: CGRect = .zero, auxiliaryTopRightArea: CGRect = .zero) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.menuBarThickness = menuBarThickness
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    var menuBarHeight: CGFloat {
        max(safeAreaTop, frame.maxY - visibleFrame.maxY,
            menuBarThickness > 0 ? menuBarThickness : 24)
    }

    var notch: CGRect? {
        guard safeAreaTop > 0 else { return nil }
        let left = auxiliaryTopLeftArea
        let right = auxiliaryTopRightArea
        if !left.isEmpty, !right.isEmpty, right.minX > left.maxX,
           left.maxX >= frame.minX, right.minX <= frame.maxX {
            return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop,
                          width: right.minX - left.maxX, height: safeAreaTop)
        }
        return CGRect(x: frame.midX - PanelMetrics.neckWidth / 2,
                      y: frame.maxY - safeAreaTop,
                      width: PanelMetrics.neckWidth, height: safeAreaTop)
    }

    var hotZone: CGRect? {
        guard let notch else { return nil }
        let width = min(PanelMetrics.hotZoneWidth, frame.width)
        return CGRect(x: min(max(notch.midX - width / 2, frame.minX), frame.maxX - width),
                      y: frame.maxY - 5, width: width, height: 5)
    }

    func containsInHotZone(_ point: CGPoint) -> Bool {
        guard let hotZone else { return false }
        return point.x >= hotZone.minX && point.x <= hotZone.maxX &&
            point.y > hotZone.minY && point.y <= hotZone.maxY
    }
}

enum PanelMetrics {
    static let width: CGFloat = 520
    static let height: CGFloat = 580
    static let gapBelowMenuBar: CGFloat = 6
    static let cornerRadius: CGFloat = 26
    static let fillet: CGFloat = 14
    static let animationDuration: TimeInterval = 0.45
    static let hotZoneWidth: CGFloat = 240
    /// 保留原有视觉宽度，但不超过系统报告的硬件刘海宽度。
    static let neckWidth: CGFloat = 180

    static var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}

struct PanelLayout: Equatable {
    let frame: CGRect
    let isAttached: Bool
    let cardTop: CGFloat
    let neckWidth: CGFloat
    /// 相对窗口左缘的刘海中心；侧边 Dock 挤压窗口时仍与硬件对齐。
    let neckCenterX: CGFloat

    init(screen: PanelScreenGeometry, attached: Bool) {
        let visible = screen.visibleFrame
        let width = min(PanelMetrics.width, max(1, visible.width))
        let center = screen.notch?.midX ?? screen.frame.midX
        let x = min(max(center - width / 2, visible.minX), visible.maxX - width)
        neckCenterX = center - x
        neckWidth = min(PanelMetrics.neckWidth, screen.notch?.width ?? 0)
        // 无刘海或窄屏容不下颈部/肩部时，使用完整的悬浮卡片。
        let shoulder = neckWidth / 2 + PanelMetrics.cornerRadius + PanelMetrics.fillet
        isAttached = attached && screen.notch != nil &&
            neckCenterX >= shoulder && width - neckCenterX >= shoulder
        let top = isAttached ? screen.frame.maxY :
            max(visible.minY + 1, screen.frame.maxY - screen.menuBarHeight - PanelMetrics.gapBelowMenuBar)
        let requestedNeckHeight = isAttached ? screen.menuBarHeight + PanelMetrics.gapBelowMenuBar : 0
        let height = min(PanelMetrics.height + requestedNeckHeight, max(1, top - visible.minY))
        cardTop = min(requestedNeckHeight, max(0, height - 1))
        frame = CGRect(x: x, y: top - height, width: width, height: height)
    }
}

final class PanelPresentation: ObservableObject {
    @Published var layout: PanelLayout?
}
