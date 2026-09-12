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

/// 悬浮岛屿面板尺寸常量：完全独立于刘海，悬浮在菜单栏下方
enum PanelMetrics {
    static let width: CGFloat = 440
    static let gapBelowMenuBar: CGFloat = 6
    static let cornerRadius: CGFloat = 26
    static let animationDuration: TimeInterval = 0.45
    static let collapsedHeight: CGFloat = 24
    /// 刘海悬停热区宽度（F1：约 240pt）
    static let hotZoneWidth: CGFloat = 240

    /// 主屏菜单栏高度：刘海屏约 37pt，普通屏约 24pt
    static var menuBarHeight: CGFloat {
        guard let screen = NSScreen.screens.first else { return 37 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    static var maxPanelHeight: CGFloat {
        guard let screen = NSScreen.screens.first else { return 800 }
        return screen.visibleFrame.height - 40
    }
}

/// 刘海面板管理：无边框、非激活、statusBar 层级；
/// 顶部固定在菜单栏下方，高度跟随 SwiftUI 内容动态变化（向下生长）
final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var panel: NSPanel?
    private var appModel: AppModel?
    private(set) var state: PanelState = .collapsed

    /// 动画代数：快速连续切换时使旧的完成回调失效
    private var animationGeneration = 0
    private var contentHeight: CGFloat = PanelMetrics.collapsedHeight

    func configure(with appModel: AppModel) {
        guard panel == nil, let screen = NSScreen.screens.first else { return }
        self.appModel = appModel

        let panel = NSPanel(contentRect: frame(withHeight: PanelMetrics.collapsedHeight, on: screen),
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

        // 从刘海下方的极小尺寸开始向下生长
        if let panel, let screen = NSScreen.screens.first {
            panel.setFrame(frame(withHeight: PanelMetrics.collapsedHeight, on: screen), display: false)
        }
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

    /// SwiftUI 内容高度变化 → 顶部固定、向下动画调整窗口高度
    func updateContentHeight(_ height: CGFloat) {
        guard let panel, let screen = NSScreen.screens.first,
              state == .expanding || state == .expanded || state == .collapsing else { return }
        let target = min(max(PanelMetrics.collapsedHeight, height), PanelMetrics.maxPanelHeight)
        guard abs(target - contentHeight) > 0.5 else { return }
        contentHeight = target

        let newFrame = frame(withHeight: target, on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - 坐标

    private func frame(withHeight height: CGFloat, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - PanelMetrics.width / 2,
               y: topY(on: screen) - height,
               width: PanelMetrics.width,
               height: height)
    }

    /// 面板顶边：菜单栏下方留 gap，不覆盖刘海/菜单栏
    private func topY(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - PanelMetrics.menuBarHeight - PanelMetrics.gapBelowMenuBar
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - PanelMetrics.width / 2,
                                           y: topY(on: screen)))
    }
}
