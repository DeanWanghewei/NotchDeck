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

/// 刘海面板管理：无边框、非激活、statusBar 层级；
/// 顶部固定在菜单栏下方，固定尺寸并限制在当前屏幕可见区域内。
final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var panel: NSPanel?
    private var appModel: AppModel?
    private let presentation = PanelPresentation()
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var state: PanelState = .collapsed

    /// 动画代数：快速连续切换时使旧的完成回调失效
    private var animationGeneration = 0

    func configure(with appModel: AppModel) {
        guard panel == nil, let screen = PanelMetrics.targetScreen else { return }
        self.appModel = appModel

        let layout = PanelLayout(screen: PanelScreenGeometry(screen: screen),
                                 attached: SettingsStore.shared.notchAttached)
        presentation.layout = layout
        let panel = NSPanel(contentRect: layout.frame,
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
        let hostingView = NSHostingView(rootView: NotchDeckView()
            .environmentObject(appModel)
            .environmentObject(presentation))
        // 窗口尺寸由屏幕布局统一控制，避免 SwiftUI 最小尺寸约束反向撑大面板。
        hostingView.sizingOptions = []
        if #available(macOS 13.3, *) {
            // 接壤区域已包含屏幕安全区，禁止 HostingView 再次插入刘海 inset。
            hostingView.safeAreaRegions = []
        }
        panel.contentView = hostingView
        self.panel = panel

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                   NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrame() }
            .store(in: &subscriptions)
        // 接壤开关切换时立即重排窗口
        SettingsStore.shared.$notchAttached
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrame() }
            .store(in: &subscriptions)
    }

    /// 按当前配置重排窗口（收起状态下也生效，切换配置无感）
    private func refreshFrame() {
        guard let panel, let screen = PanelMetrics.targetScreen else { return }
        let layout = PanelLayout(screen: PanelScreenGeometry(screen: screen),
                                 attached: SettingsStore.shared.notchAttached)
        if presentation.layout != layout {
            presentation.layout = layout
        }
        if panel.frame != layout.frame {
            panel.setFrame(layout.frame, display: true)
        }
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

        refreshFrame()
        panel?.orderFrontRegardless()
        appModel.isExpanded = true

        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) { [weak self] in
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

        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.state = .collapsed
            self.panel?.orderOut(nil)
        }
    }

    private var animationDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : PanelMetrics.animationDuration
    }
}
