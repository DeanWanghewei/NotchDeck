import AppKit

/// 零权限鼠标悬停检测：NSEvent.mouseLocation + Timer 轮询（0.1s/次）
///
/// - 悬停内置屏刘海区域（240pt 宽、5pt 高）超过 hoverDelay 后回调展开
/// - 鼠标离开面板超过 collapseDelay 后回调收起（仅当鼠标曾进入过面板，
///   避免快捷键呼出时鼠标不在面板内被立即收起）
final class MouseTracker {
    var onShouldExpand: (() -> Void)?
    var onShouldCollapse: (() -> Void)?

    private var timer: Timer?
    private var hoverDeadline: Date?
    private var leaveDeadline: Date?
    private var hasEnteredPanel = false

    private let settings = SettingsStore.shared

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let state = NotchWindowController.shared.state
        let mouse = NSEvent.mouseLocation

        if state == .collapsed {
            hasEnteredPanel = false
            leaveDeadline = nil

            if settings.hoverEnabled, Self.isMouseInNotchArea(mouse) {
                if hoverDeadline == nil {
                    hoverDeadline = Date().addingTimeInterval(settings.hoverDelay)
                } else if Date() >= hoverDeadline! {
                    hoverDeadline = nil
                    // 悬停呼出的面板即使未进入内容区，也应在离开后收起。
                    hasEnteredPanel = true
                    onShouldExpand?()
                }
            } else {
                hoverDeadline = nil
            }
            return
        }

        // 展开中 / 已展开：面板与刘海热区内保持，离开后倒计时收起
        hoverDeadline = nil
        if NotchWindowController.shared.panelFrame.contains(mouse) {
            hasEnteredPanel = true
            leaveDeadline = nil
        } else if Self.isMouseInNotchArea(mouse) {
            leaveDeadline = nil
        } else if hasEnteredPanel, settings.collapseEnabled {
            if leaveDeadline == nil {
                leaveDeadline = Date().addingTimeInterval(settings.collapseDelay)
            } else if Date() >= leaveDeadline! {
                leaveDeadline = nil
                onShouldCollapse?()
            }
        } else {
            leaveDeadline = nil
        }
    }

    /// 热区与面板使用同一块刘海屏，且不延伸到其上方的其他显示器。
    private static func isMouseInNotchArea(_ point: NSPoint) -> Bool {
        guard let screen = PanelMetrics.targetScreen else { return false }
        return PanelScreenGeometry(screen: screen).containsInHotZone(point)
    }
}
