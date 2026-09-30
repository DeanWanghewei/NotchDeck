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
        // 接壤开关切换时立即重排窗口
        SettingsStore.shared.$notchAttached
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
        orderFrontEnsuringVisible()
    }

    /// 置前面板并确认真的落在当前 Space 上。
    ///
    /// Space 生命周期扰动（全屏空间创建/销毁、应用重启、更新程序强切前台等）
    /// 之后，canJoinAllSpaces 窗口的归属可能在窗口服务器侧变陈旧：
    /// orderFrontRegardless 被静默忽略，面板实际不可见而状态机照常进入
    /// expanded，悬停呼出从此失效（v0.19.2 在 macOS 27.2 实测）。因此置前后
    /// 必须校验；失败时重挂 collectionBehavior 强制窗口服务器重算归属并重试，
    /// 留待后续应用激活通知兜底。
    /// 置前面板并确认真的合成在屏幕上。
    ///
    /// Space 生命周期扰动（全屏空间创建/销毁、应用重启、更新程序强切前台等）
    /// 之后，canJoinAllSpaces 窗口可能被窗口服务器留在一个不可见空间上：
    /// orderFrontRegardless 静默空转，面板实际不可见而状态机照常进入 expanded，
    /// 悬停呼出从此失效（v0.19.2 在 macOS 27.2 实测）。因此置前后必须用
    /// CGWindowList 自查真实合成状态（isVisible / isOnActiveSpace 在
    /// macOS 27.2 上可能谎报，不可用作判据）；未上屏则先 orderOut 摘下、
    /// 重挂 collectionBehavior 强制重算归属、再置前重试，仍失败时留给
    /// restorePresentation 在下次应用激活通知时兜底。
    private func orderFrontEnsuringVisible(attempt: Int = 0) {
        guard let panel else { return }
        panel.orderFrontRegardless()
        if Self.isCompositedOnScreen(panel.windowNumber) { return }
        guard attempt < 3 else {
            DebugLog.write("present stranded after \(attempt + 1) attempts, wait for activation fallback")
            return
        }
        // 搁浅时窗口仍处于置入状态，单纯再次置前不会跨空间迁移；
        // 必须先摘下并重挂归属，强迫窗口服务器把它重新派给当前 Space。
        // 禁止 union(.moveToActiveSpace) 之类的组合——与 canJoinAllSpaces
        // 并存在 macOS 27.2 直接断言崩溃（实测）。
        panel.orderOut(nil)
        let behavior = panel.collectionBehavior
        panel.collectionBehavior = behavior.subtracting(.canJoinAllSpaces)
        panel.collectionBehavior = behavior
        panel.orderFrontRegardless()
        DebugLog.write("present reassert attempt=\(attempt)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.state == .expanding || self.state == .expanded else { return }
            self.orderFrontEnsuringVisible(attempt: attempt + 1)
        }
    }

    /// 面板是否真的合成在屏幕上：用自身 windowNumber 查 CGWindowList。
    /// 对自己窗口的查询不受其他进程窗口信息门控影响，是唯一可信判据。
    private static func isCompositedOnScreen(_ windowNumber: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly],
                                                    CGWindowID(windowNumber)) as? [[String: Any]] else {
            return false
        }
        return !list.isEmpty
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
        orderFrontEnsuringVisible()
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
