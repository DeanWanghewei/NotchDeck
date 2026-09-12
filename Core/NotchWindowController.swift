import AppKit
import SwiftUI

/// 面板状态机（见需求文档 6.3）：
/// Collapsed → Expanding → Expanded → Collapsing → Collapsed
enum PanelState {
    case collapsed
    case expanding
    case expanded
    case collapsing
}

/// 刘海面板尺寸常量
enum PanelMetrics {
    static let width: CGFloat = 460
    static let bodyHeight: CGFloat = 452
    static let capWidth: CGFloat = 240
    static let cornerRadius: CGFloat = 22
    static let animationDuration: TimeInterval = 0.5

    /// 主屏菜单栏高度：刘海屏约 37pt，普通屏约 24pt
    static var menuBarHeight: CGFloat {
        guard let screen = NSScreen.screens.first else { return 37 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    static var panelHeight: CGFloat {
        menuBarHeight + bodyHeight
    }
}

/// 刘海 NSPanel 管理：无边框、非激活、statusBar 层级，主屏顶部居中
final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var panel: NSPanel?
    private var appModel: AppModel?
    private(set) var state: PanelState = .collapsed

    /// 动画代数：快速连续切换时使旧的完成回调失效
    private var animationGeneration = 0

    func configure(with appModel: AppModel) {
        guard panel == nil, let screen = NSScreen.screens.first else { return }
        self.appModel = appModel

        let size = NSSize(width: PanelMetrics.width, height: PanelMetrics.panelHeight)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - size.height)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: NotchDeckView().environmentObject(appModel))
        self.panel = panel

        // 屏幕参数变化（外接/分辨率调整）时重新定位
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    /// 当前面板 frame（鼠标离开检测用）
    var panelFrame: NSRect {
        panel?.frame ?? .zero
    }

    func toggle() {
        if state == .collapsed || state == .collapsing {
            expand()
        } else {
            collapse()
        }
    }

    func expand() {
        guard state == .collapsed || state == .collapsing, let appModel else { return }
        animationGeneration += 1
        let generation = animationGeneration
        state = .expanding
        panel?.orderFrontRegardless()
        appModel.isExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMetrics.animationDuration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.state = .expanded
        }
    }

    func collapse() {
        guard state == .expanded || state == .expanding, let appModel else { return }
        animationGeneration += 1
        let generation = animationGeneration
        state = .collapsing
        appModel.isExpanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMetrics.animationDuration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.state = .collapsed
            self.panel?.orderOut(nil)
        }
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - PanelMetrics.width / 2,
                                           y: screen.frame.maxY))
    }
}
