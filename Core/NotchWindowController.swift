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

/// 刘海面板管理：无边框、非激活、statusBar 层级，可加入其他应用的全屏空间；
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

    private lazy var visibilityRecovery = PanelVisibilityRecovery(
        isOnScreen: { [weak self] in
            guard let panel = self?.panel else { return nil }
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
            return PanelVisibility.isOnScreen(windowNumber: panel.windowNumber, windows: windows)
        },
        orderFront: { [weak self] in self?.panel?.orderFrontRegardless() },
        reattach: { [weak self] in
            guard let panel = self?.panel else { return }
            // 先摘下再重挂，强制窗口服务器重算 Space 归属；
            // canJoinAllSpaces 与 moveToActiveSpace 并存会触发 AppKit 断言。
            panel.orderOut(nil)
            let behavior = panel.collectionBehavior
            panel.collectionBehavior = behavior.subtracting(.canJoinAllSpaces)
            panel.collectionBehavior = behavior
            DebugLog.write("present reattach window=\(panel.windowNumber)")
        },
        didFail: { [weak self] in self?.presentationDidFail() })

    func configure(with appModel: AppModel) {
        guard panel == nil, let screen = PanelMetrics.targetScreen else { return }
        self.appModel = appModel

        let layout = PanelLayout(screen: PanelScreenGeometry(screen: screen),
                                 attached: appModel.settings.notchAttached)
        presentation.layout = layout
        let panel = NSPanel(contentRect: layout.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // canJoinAllSpaces 只描述 Space 归属；macOS 13+ 还需显式允许加入其他
        // 应用的窗口集合/全屏空间，避免编辑器等应用的全屏窗口将面板排除在外。
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                    .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
                   NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification),
                   NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restorePresentation() }
            .store(in: &subscriptions)
        // 接壤开关切换时立即重排窗口。读注入的设置而不是全局单例：应用里它就是
        // `SettingsStore.shared`，测试则可以传入自己的设置——此前直接读单例，传入的设置不生效。
        appModel.settings.$notchAttached
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrame() }
            .store(in: &subscriptions)
    }

    /// 全屏切换/激活编辑器可能重排窗口层次；恢复已展开的面板，不激活 NotchDeck。
    /// 通知排队期间用户可能已经收起面板，必须按当前状态决定是否重新置前。
    private func restorePresentation() {
        refreshFrame()
        guard state == .expanding || state == .expanded else { return }
        visibilityRecovery.present()
    }

    /// 恢复失败必须回到可再次唤起的状态，否则鼠标热区会一直误认面板已展开。
    private func presentationDidFail() {
        guard state == .expanding || state == .expanded else { return }
        DebugLog.write("present stranded, reset to collapsed window=\(panel?.windowNumber ?? -1)")
        animationGeneration += 1
        state = .collapsed
        appModel?.isExpanded = false
        presentation.didMount = nil
        presentation.isPresented = false
        panel?.orderOut(nil)
    }

    /// 稀少异常事件落盘（/tmp/notchdeck-debug.log），日常路径零开销零噪音
    enum DebugLog {
        static func write(_ message: String) {
            let line = "\(Date().timeIntervalSince1970) \(message)\n"
            let path = URL(fileURLWithPath: "/tmp/notchdeck-debug.log")
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: path)
            }
        }
    }

    /// 按当前配置重排窗口（收起状态下也生效，切换配置无感）
    private func refreshFrame() {
        guard let panel, let screen = PanelMetrics.targetScreen else { return }
        let attached = appModel?.settings.notchAttached ?? SettingsStore.shared.notchAttached
        let layout = PanelLayout(screen: PanelScreenGeometry(screen: screen), attached: attached)
        if presentation.layout != layout {
            presentation.layout = layout
        }
        applyAppearance()
        if panel.frame != layout.frame {
            panel.setFrame(layout.frame, display: true)
        }
    }

    /// 接壤卡片保持深色，窗口本身也必须是深色外观。SwiftUI 的颜色跟随环境里的 colorScheme，
    /// 但材质（Liquid Glass）与滚动条、滑杆等系统控件跟随窗口外观——浅色系统下不强制，
    /// 接壤面板的玻璃是浅色的，正好在黑色硬件刘海下形成一条亮色接缝。
    /// 悬浮卡片跟随系统，外观交还给系统（nil）。
    private func applyAppearance() {
        panel?.appearance = presentation.layout?.isAttached == true ? NSAppearance(named: .darkAqua) : nil
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
        if presentation.isPresented {
            // 收起途中折返：视图还在屏幕上，弹簧从当前轮廓直接转向，不必重新挂载。
            appModel.isExpanded = true
        } else {
            presentation.isPresented = true
            unfoldAfterMount(generation: generation)
        }
        visibilityRecovery.present()

        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.state = .expanded
        }
    }

    /// 先让折叠轮廓挂载并上屏，再翻转目标值。
    ///
    /// 弹簧只能从视图"上一次画出来的值"出发。挂载与翻转落在同一个事务里，视图第一次求值时
    /// 目标就已经是展开态——没有前值可插值，形变会丢失（屏幕外测试窗口里实测：轮廓停在空形状上
    /// 不再更新）。所以翻转只由视图挂载完成后的回调（`PanelPresentation.didMount`）触发。
    private func unfoldAfterMount(generation: Int) {
        presentation.didMount = { [weak self] in
            // 让挂载的那一帧先提交完：onAppear 发生在首次求值期间，这里挪到下一轮再翻转。
            DispatchQueue.main.async {
                guard let self, self.animationGeneration == generation, self.state == .expanding,
                      let appModel = self.appModel, !appModel.isExpanded else { return }
                appModel.isExpanded = true
            }
        }
        // 视图迟迟没有挂载上屏（窗口被系统压住、屏幕参数变动等）。不能到点盲目翻转——那正是
        // 上面要规避的情形；也不能一直停在"展开中"让热区误判。放弃这次展开，回到可再次唤起的状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mountTimeout) { [weak self] in
            guard let self, self.animationGeneration == generation, self.state == .expanding,
                  self.appModel?.isExpanded != true else { return }
            DebugLog.write("panel did not mount in \(Self.mountTimeout)s, reset to collapsed")
            self.animationGeneration += 1
            self.visibilityRecovery.cancel()
            self.state = .collapsed
            self.presentation.didMount = nil
            self.presentation.isPresented = false
            self.panel?.orderOut(nil)
        }
    }

    /// 视图从置为挂载到完成首屏渲染的等待上限。正常情况下一两帧内完成；0.5s 足以容下
    /// 一次窗口置前与首帧布局，又不至于让一次失败的展开长时间占住热区。
    static let mountTimeout: TimeInterval = 0.5

    func collapse() {
        guard state == .expanded || state == .expanding, let appModel else { return }
        animationGeneration += 1
        let generation = animationGeneration
        state = .collapsing
        visibilityRecovery.cancel()
        appModel.isExpanded = false

        // 轮廓缩完才卸载视图并移出屏幕；提前移出会把还在收的轮廓截断成一帧。
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.state = .collapsed
            self.presentation.didMount = nil
            self.presentation.isPresented = false
            self.panel?.orderOut(nil)
        }
    }

    /// 状态机在形变开始后等待的时间。收起时必须落在弹簧"过零后为负"的窗口期内，
    /// 见 `NotchMotion.unfoldHold`。
    private var holdDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? NotchMotion.stillDuration : NotchMotion.unfoldHold
    }
}
