import AppKit
import Combine
import SwiftUI

/// 面板状态机（见需求文档 6.3）：
/// Collapsed → Expanding → Expanded → Collapsing → Collapsed
enum PanelState {
    case collapsed
    case expanding
    case expanded
    case collapsing
}

/// 悬浮岛屿面板尺寸常量：固定尺寸，内容在内部滚动，不做动态窗口高度
/// （动态高度 + AppKit 约束动画在切换内容时触发约束异常崩溃，已废除）
enum PanelMetrics {
    static let width: CGFloat = 520
    static let height: CGFloat = 580
    static let gapBelowMenuBar: CGFloat = 6
    static let cornerRadius: CGFloat = 26
    static let animationDuration: TimeInterval = 0.45
    /// 刘海悬停热区宽度（F1：约 240pt）
    static let hotZoneWidth: CGFloat = 240

    /// 优先选择带刘海的内置屏；没有刘海时使用当前主屏。
    static var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(24, screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// 目标屏的菜单栏高度（SwiftUI 侧使用）
    static var menuBarHeight: CGFloat {
        guard let screen = targetScreen else { return 37 }
        return menuBarHeight(on: screen)
    }
}

/// 刘海面板管理：无边框、非激活、statusBar 层级；
/// 顶部固定在菜单栏下方，固定尺寸并限制在当前屏幕可见区域内。
final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var panel: NSPanel?
    private var appModel: AppModel?
    private(set) var state: PanelState = .collapsed

    /// 动画代数：快速连续切换时使旧的完成回调失效
    private var animationGeneration = 0

    func configure(with appModel: AppModel) {
        guard panel == nil, let screen = PanelMetrics.targetScreen else { return }
        self.appModel = appModel

        let panel = NSPanel(contentRect: frame(on: screen),
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
        // 接壤开关切换时立即重排窗口
        settingsSubscription = SettingsStore.shared.$notchAttached
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrame() }
    }

    private var settingsSubscription: AnyCancellable?

    /// 按当前配置重排窗口（收起状态下也生效，切换配置无感）
    private func refreshFrame() {
        guard let panel, let screen = PanelMetrics.targetScreen else { return }
        panel.setFrame(frame(on: screen), display: true)
    }

    /// 当前面板 frame（鼠标离开检测用）
    var panelFrame: NSRect {
        panel?.frame ?? .zero
    }

    /// UI 调试用：面板内容视图（配合 -NotchDeckDumpUI 导出渲染图）
    var panelContentView: NSView? {
        panel?.contentView
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

        if let panel, let screen = PanelMetrics.targetScreen {
            panel.setFrame(frame(on: screen), display: false)
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

    // MARK: - 坐标

    /// 固定尺寸窗口。悬浮模式：顶部在菜单栏下方留 gap；
    /// 接壤模式：顶部贴屏幕顶端，窗口包含菜单栏高度的黑色"刘海延伸带"
    private func frame(on screen: NSScreen) -> NSRect {
        let attached = SettingsStore.shared.notchAttached
        let bandHeight = attached ? PanelMetrics.menuBarHeight(on: screen) : 0
        let width = min(PanelMetrics.width, screen.visibleFrame.width)
        let top = attached ? screen.frame.maxY : topY(on: screen)
        let height = min(PanelMetrics.height + bandHeight,
                         max(1, top - screen.visibleFrame.minY))
        return NSRect(x: screen.visibleFrame.midX - width / 2,
                      y: top - height, width: width, height: height)
    }

    /// 面板顶边：菜单栏下方留 gap，不覆盖刘海/菜单栏
    private func topY(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - PanelMetrics.menuBarHeight(on: screen) - PanelMetrics.gapBelowMenuBar
    }

    private func reposition() {
        guard let panel, let screen = PanelMetrics.targetScreen else { return }
        panel.setFrame(frame(on: screen), display: false)
    }
}
