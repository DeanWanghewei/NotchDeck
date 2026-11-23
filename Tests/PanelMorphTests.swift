import AppKit
import Combine
import SwiftUI
import XCTest

/// 面板形变的三层证据：
/// 1. 像素——真实视图树在给定轮廓下只在该有的地方着色（`ImageRenderer`，确定性，不依赖动画，
///    只断言不透明表面：`ImageRenderer` 画不出 `glassEffect` 的材质）；
/// 2. 逐帧——翻转 `isExpanded` 后弹簧确实在两份轮廓之间逐帧插值，过冲被夹在窗口之内；
/// 3. 截图——设置 `NOTCHDECK_RENDER_DIR` 时导出深浅两版的折叠 / 中间 / 展开帧，供目检。
@MainActor
final class PanelMorphTests: XCTestCase {
    private let notchedScreen = PanelScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874),
        safeAreaTop: 38, menuBarThickness: 24,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 656, height: 38),
        auxiliaryTopRightArea: CGRect(x: 856, y: 944, width: 656, height: 38))
    private var attached: PanelLayout { PanelLayout(screen: notchedScreen, attached: true) }
    private var floating: PanelLayout { PanelLayout(screen: notchedScreen, attached: false) }

    // MARK: - 像素：折叠态

    func testFoldedAttachedPanelPaintsNothingBelowTheHardwareNotch() throws {
        let image = try render(layout: attached, progress: 0, expanded: false)
        let notch = notchedScreen.notch!
        XCTAssertEqual(image.opaqueCount(below: notch.height), 0,
                       "折叠态在硬件刘海底缘以下仍有着色——收起时会留下一条可见的黑边")
        // 刘海之内只有颈部是黑的：与硬件刘海同宽，正好藏进去。
        XCTAssertEqual(Double(image.opaqueCount()), 180 * notch.height, accuracy: 180 * notch.height * 0.02)
        XCTAssertEqual(image.alpha(x: 100, y: 10), 0)
        XCTAssertEqual(image.alpha(x: 260, y: 10), 1, accuracy: 0.01)
    }

    func testFoldedFloatingPanelPaintsNothing() throws {
        let image = try render(layout: floating, progress: 0, expanded: false)
        XCTAssertEqual(image.opaqueCount(), 0)
    }

    // MARK: - 像素：中间帧

    func testHalfUnfoldedPanelPaintsOnlyInsideItsOutline() throws {
        for layout in [attached, floating] {
            let image = try render(layout: layout, progress: 0.5, expanded: true)
            let from = PanelOutline.folded(for: layout)
            let to = PanelOutline.expanded(for: layout)
            let half = from.interpolated(toward: to, at: 0.5)
            let body = PanelBodyShape(half).rect(in: CGRect(origin: .zero, size: layout.frame.size))
            XCTAssertEqual(body.height, (layout.frame.height - layout.cardTop) / 2, accuracy: 0.01)

            // 颈部与两侧凹角补件是轮廓的一部分，它们落在卡片顶缘之上。
            let leading = layout.neckCenterX - layout.neckWidth / 2
            let trailing = layout.neckCenterX + layout.neckWidth / 2
            let allowed: [CGRect] = [body,
                                    CGRect(x: leading, y: 0, width: layout.neckWidth, height: half.top),
                                    CGRect(x: leading - half.fillet, y: half.top - half.fillet,
                                           width: half.fillet, height: half.fillet),
                                    CGRect(x: trailing, y: half.top - half.fillet,
                                           width: half.fillet, height: half.fillet)]

            // 汇总成一条断言：逐像素断言一旦方向读错会刷出几十万条失败，淹没真正有用的信息。
            XCTAssertNil(image.firstOpaquePixel(outside: allowed),
                         "在轮廓之外仍有不透明像素——内容没有被遮罩裁住")
            // 轮廓之外、窗口之内：内容已经按展开后的几何排好，必须完全透明。
            XCTAssertEqual(image.alpha(x: 10, y: 100), 0)
            XCTAssertEqual(image.alpha(x: Int(body.midX), y: Int(body.midY)), 1, accuracy: 0.01)

            let folded = try render(layout: layout, progress: 0, expanded: true)
            let expanded = try render(layout: layout, progress: 1, expanded: true)
            let belowNotch = layout.notchDepth
            XCTAssertGreaterThan(image.opaqueCount(below: belowNotch), folded.opaqueCount(below: belowNotch))
            XCTAssertLessThan(image.opaqueCount(below: belowNotch), expanded.opaqueCount(below: belowNotch))
        }
    }

    /// 悬浮卡片的边线贴在卡片内侧：占满最外一列像素，第二列必须还是干净的卡片底色。
    /// 形状若在 strokeBorder 之外再内缩半个线宽，边线就会跨到第二列上、最外列反而只剩半格。
    func testFloatingHairlineSitsOnTheInsideOfTheCardEdge() throws {
        let image = try render(layout: floating, progress: 1, expanded: true)
        let middle = Int(floating.frame.height) / 2
        let outer = try XCTUnwrap(image.colour(x: 0, y: middle))
        let inner = try XCTUnwrap(image.colour(x: 1, y: middle))
        let card = try XCTUnwrap(image.colour(x: 3, y: middle))
        XCTAssertLessThan(outer.red, 0.93, "最外列应被边线着色")
        XCTAssertGreaterThan(inner.red, 0.97, "边线不应伸到第二列")
        XCTAssertGreaterThan(card.red, 0.98)
        // 右缘对称。
        let width = Int(floating.frame.width)
        XCTAssertLessThan(try XCTUnwrap(image.colour(x: width - 1, y: middle)).red, 0.93)
        XCTAssertGreaterThan(try XCTUnwrap(image.colour(x: width - 2, y: middle)).red, 0.97)
    }

    // MARK: - 像素：展开态

    func testExpandedPanelPaintsTheWholeCardWithRoundedCorners() throws {
        for layout in [attached, floating] {
            let image = try render(layout: layout, progress: 1, expanded: true)
            let width = Int(layout.frame.width)
            let height = Int(layout.frame.height)
            let radius = Int(PanelOutline.cornerRadius)
            // 圆角以内通体不透明。
            for y in stride(from: Int(layout.cardTop) + radius, to: height - radius, by: 7) {
                for x in stride(from: radius, to: width - radius, by: 13) {
                    XCTAssertEqual(image.alpha(x: x, y: y), 1, accuracy: 0.01, "(\(x), \(y))")
                }
            }
            XCTAssertEqual(image.alpha(x: 0, y: Int(layout.cardTop)), 0)
            XCTAssertEqual(image.alpha(x: width - 1, y: Int(layout.cardTop)), 0)
            XCTAssertEqual(image.alpha(x: 0, y: height - 1), 0)
            XCTAssertEqual(image.alpha(x: width - 1, y: height - 1), 0)
            // 左边缘中段是卡片本体，必须着色（过冲夹取不得把卡片夹窄）。
            XCTAssertEqual(image.alpha(x: 0, y: height / 2), 1, accuracy: 0.01)
            XCTAssertEqual(image.alpha(x: width - 1, y: height / 2), 1, accuracy: 0.01)
            XCTAssertEqual(image.alpha(x: width / 2, y: height - 1), 1, accuracy: 0.01)
        }
    }

    /// 开关关闭时接壤面板与原先一致：通体纯黑，没有任何材质透出背景。
    func testSolidAttachedPanelIsPureBlack() throws {
        let image = try render(layout: attached, progress: 1, expanded: true,
                               background: Color.red)
        // 取样点避开居中的空状态提示与底栏文字：卡片顶缘以下 26pt 的左右两侧、底栏上方的间隙、颈部。
        for point in [(x: 30, y: 72), (x: 490, y: 72), (x: 30, y: 586), (x: 490, y: 586), (x: 260, y: 20)] {
            let colour = try XCTUnwrap(image.colour(x: point.x, y: point.y))
            XCTAssertLessThan(colour.red + colour.green + colour.blue, 0.02, "\(point)")
        }
    }

    // MARK: - 逐帧：弹簧在两份轮廓之间插值

    func testPanelUnfoldsThroughIntermediateOutlinesAndSettlesInsideTheWindow() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        let harness = try mount(layout: attached)
        defer { harness.release() }
        wait(0.2)
        XCTAssertEqual(harness.samples.all.map(\.rect.height).max(), 0, "挂载后应先是折叠轮廓")
        XCTAssertEqual(harness.samples.all.last?.rect.minY ?? -1, attached.notchDepth, accuracy: 0.01)

        let full = attached.frame.height - attached.cardTop
        harness.samples.mark()
        withAnimation(NotchMotion.unfold) { harness.app.isExpanded = true }
        wait(0.55)
        let unfolding = harness.samples.sinceMark
        let intermediate = Set(unfolding.map(\.rect.height).filter { $0 > 0 && $0 < full })
        XCTAssertGreaterThanOrEqual(intermediate.count, 4,
                                    "面板没有经过中间轮廓——弹簧没有插值形状参数，只剩插入/移除")
        // 过冲确实发生（未夹取的高度越过终值），但轮廓始终被夹在窗口之内。
        XCTAssertGreaterThan(unfolding.map(\.rawHeight).max() ?? 0, full)
        XCTAssertLessThanOrEqual(unfolding.map(\.rect.height).max() ?? 0, full)
        // 0.55s 时已到位，只剩顶缘零点几点的余摆。
        XCTAssertEqual(unfolding.last?.rect.height ?? 0, full, accuracy: 0.5)
        XCTAssertEqual(unfolding.last?.rect.minY ?? 0, attached.cardTop, accuracy: 0.5)
        // 弹簧走完后落在展开轮廓上：窗口边缘由贴边吸附保证精确，顶缘只要求亚像素余量。
        wait(0.6)
        let settled = try XCTUnwrap(harness.samples.all.last?.rect)
        XCTAssertEqual(settled.minX, 0, accuracy: 0.001)
        XCTAssertEqual(settled.minY, attached.cardTop, accuracy: 0.1)
        XCTAssertEqual(settled.maxX, attached.frame.width, accuracy: 0.001)
        XCTAssertEqual(settled.maxY, attached.frame.height, accuracy: 0.001)
    }

    /// 收起时弹簧过零后会回到正值。状态机在 `unfoldHold` 那一刻移出窗口，那时屏幕上必须已经空了。
    func testCollapsedPanelIsAlreadyInvisibleWhenTheStateMachineLetsGo() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        let harness = try mount(layout: attached)
        defer { harness.release() }
        wait(0.2)
        // 不包在 withAnimation 里也会动画：视图上的 .animation(_:value:) 只认值的变化。
        // 等它完全落定再收，收起才是"从静止出发"的那条弹簧——半途收起会带着速度出发，
        // 过零的时刻就不是 NotchMotion.zeroCrossings 算出来的那个了。
        harness.app.isExpanded = true
        wait(1.3)

        harness.samples.mark()
        withAnimation(NotchMotion.unfold) { harness.app.isExpanded = false }
        wait(0.95)
        let collapsing = harness.samples.sinceMark
        let full = attached.frame.height - attached.cardTop
        // 时间零点取动画实际开始的那一帧（第一个还没缩完的取值），而不是状态翻转的那一刻：
        // 翻转与动画提交之间可能有一段延迟，而弹簧的时间是从提交那一刻起算的。按墙钟从翻转
        // 起算，主线程一卡就会把"动画还没走到"误判成"等待时间不够"。
        let started = try XCTUnwrap(collapsing.first { $0.rect.height < full }, "收起动画没有开始")
        func sinceStart(_ sample: OutlineSamples.Sample) -> TimeInterval { sample.at - started.at }
        let aroundHold = collapsing.filter {
            sinceStart($0) >= NotchMotion.unfoldHold - 0.06 && sinceStart($0) <= NotchMotion.unfoldHold + 0.06
        }
        XCTAssertFalse(aroundHold.isEmpty, "等待窗口内没有任何一帧")
        XCTAssertTrue(aroundHold.allSatisfy { $0.rect.height == 0 },
                      "unfoldHold 时轮廓还没缩完，窗口被移出屏幕会被截断成一帧")
        // 再等下去弹簧回到正值，屏幕上会重新冒出细条——这正是不能等到"完全静止"的原因。
        XCTAssertGreaterThan(collapsing.filter { sinceStart($0) > 0.85 }.map(\.rect.height).max() ?? 0, 0)
    }

    /// 本体填充与内容遮罩共用同一个形状，必须始终在同一个时钟上。
    ///
    /// 判据不依赖求值顺序（实测填充与遮罩谁先求值并不固定），也不用时间戳判断"同一帧"
    /// （SwiftUI 在一轮运行循环里可能连续求值多个动画帧，彼此间隔不到 2ms）。
    /// 只看主行程——首次到位之前：这一段没有过冲，同一时钟下每一帧内两者取同一个值，
    /// 采样流必然单调（展开递增、收起递减）。遮罩若被别的动画驱动，流里就会出现
    /// 100、60、120、80 这样的来回跳——遮罩落后于本体时，内容会画到卡片外面。
    func testContentMaskAndBodyStayOnOneClock() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        let harness = try mount(layout: attached)
        defer { harness.release() }
        // 等折叠轮廓先渲染出来：挂载与翻转落在同一个事务里，弹簧没有前值可以出发。
        wait(0.2)
        for expanding in [true, false] {
            harness.samples.mark()
            withAnimation(NotchMotion.unfold) { harness.app.isExpanded = expanding }
            // 展开后等弹簧完全静止再收起，否则收起的开头会继承上一轮的余摆。
            wait(expanding ? 1.3 : 0.6)
            let samples = harness.samples.sinceMark
            XCTAssertGreaterThan(samples.filter { $0.tag == 0 }.count, 4, "本体采样太少")
            XCTAssertGreaterThan(samples.filter { $0.tag == 1 }.count, 4, "遮罩采样太少")

            let travel = samples.filter { $0.at <= 0.3 }
            XCTAssertGreaterThan(travel.count, 8, "主行程采样太少")
            var backStep: (from: CGFloat, to: CGFloat)?
            for (earlier, later) in zip(travel, travel.dropFirst()) where backStep == nil {
                let reversed = expanding ? later.rect.height < earlier.rect.height - Self.clockDeadBand
                                         : later.rect.height > earlier.rect.height + Self.clockDeadBand
                if reversed { backStep = (earlier.rect.height, later.rect.height) }
            }
            XCTAssertNil(backStep.map { "本体 \($0.from) 与遮罩 \($0.to) 交错出现" },
                          "\(expanding ? "展开" : "收起")时本体与遮罩不在同一个时钟上")
        }
    }

    /// 判定"回跳"的死区。主行程内同一时钟下不存在反向，这里只容纳数值噪声；
    /// 两个时钟的错位则是几十个点（变异验证实测：收起时本体 107pt、遮罩 167pt）。
    private static let clockDeadBand: CGFloat = 0.05

    /// 减弱动态效果去掉的是动画本身：即使事务里带了弹簧，轮廓也直接落到终值。
    /// `accessibilityReduceMotion` 是只读环境值，测试无法注入，所以经由显式入参的轮廓层验证。
    func testReducedMotionSnapsStraightToTheTarget() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        let harness = try mount(layout: attached, reduceMotion: true, layerOnly: true)
        defer { harness.release() }
        wait(0.2)
        harness.samples.mark()
        withAnimation(NotchMotion.unfold) { harness.flag?.expanded = true }
        wait(0.4)
        let heights = harness.samples.sinceMark.map(\.rect.height)
        let full = attached.frame.height - attached.cardTop
        XCTAssertTrue(heights.allSatisfy { $0 == 0 || $0 == full }, "减弱动态效果下仍出现了中间轮廓：\(heights)")
        XCTAssertEqual(heights.last, full)
    }

    func testOutlineLayerStillUnfoldsWhenMotionIsAllowed() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        // 对照组：同一层在允许动效时必须经过中间轮廓，否则上一条断言只是因为这条路径根本不动画。
        let harness = try mount(layout: attached, reduceMotion: false, layerOnly: true)
        defer { harness.release() }
        wait(0.2)
        harness.samples.mark()
        withAnimation(NotchMotion.unfold) { harness.flag?.expanded = true }
        wait(0.5)
        let full = attached.frame.height - attached.cardTop
        let intermediate = Set(harness.samples.sinceMark.map(\.rect.height).filter { $0 > 0 && $0 < full })
        XCTAssertGreaterThanOrEqual(intermediate.count, 4)
    }

    // MARK: - 挂载与翻转的先后

    /// 窗口控制器的真实时序：先置为挂载，视图上屏后经挂载回调（下一轮运行循环）再翻转。
    /// 这条路径必须从折叠轮廓出发、经过中间轮廓。挂载与翻转落在同一个事务里，视图第一次
    /// 求值时目标就已是展开态，弹簧没有前值可以出发——屏幕外测试窗口里实测形变丢失，
    /// 轮廓停在空形状上不再更新。
    func testUnfoldingFromTheMountCallbackStartsAtTheFoldedOutline() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        let harness = try mount(layout: attached, flipOnMount: true)
        defer { harness.release() }
        wait(1.3)
        let all = harness.samples.all
        XCTAssertGreaterThan(all.count, 10, "挂载回调没有触发翻转")
        let full = attached.frame.height - attached.cardTop
        // 首帧是折叠轮廓：完全藏在硬件刘海里。
        XCTAssertEqual(all.first?.rect.height, 0)
        XCTAssertEqual(all.first?.rect.minY ?? -1, attached.notchDepth, accuracy: 0.1)
        // 中间确实经历了从颈部长出来的过程。
        let intermediate = Set(all.map(\.rect.height).filter { $0 > 0 && $0 < full })
        XCTAssertGreaterThanOrEqual(intermediate.count, 4, "面板没有经过中间轮廓")
        XCTAssertEqual(all.last?.rect.maxY ?? 0, attached.frame.height, accuracy: 0.001)
        XCTAssertTrue(harness.app.isExpanded)
    }

    /// 形变只由"展开/收起"触发。菜单栏高度变化、换屏、切换接壤/悬浮同样会改轮廓，
    /// 但那是布局变化：窗口与内容都是瞬间到位的，轮廓若被弹簧拖成半秒，遮罩就追不上内容。
    /// 所以展开状态下换一份布局，直接就是新轮廓，不经过任何中间值。
    ///
    /// 这里和 `NotchWindowController.refreshFrame()` 一样不加 `withAnimation`：`.animation(_:value:)`
    /// 只在自己的触发条件变化时替换动画，拦不住事务里显式携带的动画——布局变化一旦被包进
    /// 动画事务，轮廓就又会形变。
    func testLayoutChangesWhileExpandedDoNotMorph() throws {
        try XCTSkipUnless(animationTicks(), "此环境没有逐帧推进的动画时钟（无图形会话），跳过逐帧采样")
        let harness = try mount(layout: attached)
        defer { harness.release() }
        wait(0.2)
        withAnimation(NotchMotion.unfold) { harness.app.isExpanded = true }
        wait(1.3)
        harness.samples.mark()
        harness.presentation.layout = floating
        wait(0.4)
        let samples = harness.samples.sinceMark.filter { $0.tag != 2 }
        XCTAssertGreaterThan(samples.count, 2, "布局变化没有触发重新求值")
        // 变化生效前的那一帧仍是旧轮廓，这是正常的；之后只允许直接出现新轮廓，
        // 不得出现新旧之间的任何中间值。
        let settledOnNew = samples.contains { abs($0.rect.minY) < 1e-3 }
        XCTAssertTrue(settledOnNew, "布局变化后没有出现新轮廓")
        let stray = samples.first {
            abs($0.rect.minY) > 1e-3 && abs($0.rect.minY - attached.cardTop) > 1e-3
        }
        XCTAssertNil(stray.map { "顶缘 \($0.rect.minY)" }, "布局变化被当成了形变，出现了新旧轮廓之间的中间值")
    }

    // MARK: - 截图（仅在设置 NOTCHDECK_RENDER_DIR 时执行）

    func testRenderPanelOutlinesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCHDECK_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "com.notchdeck.panel.render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let catalog = try PluginCatalog.bundled()
        let app = AppModel(settings: settings, modules: [], plugins: MarketplacePlugins.implementations,
                           catalog: catalog, appVersion: "99.0.0", catalogFetch: { _ in
            XCTFail("截图不应发起目录请求")
            return AnyCancellable {}
        })
        defer { app.shutdown() }
        settings.notchAttached = true
        app.isExpanded = true
        // 模块展开后才开始采集：等两个系统监控周期拿到真实读数。
        wait(2.5)

        for attachedMode in [true, false] {
            settings.notchAttached = attachedMode
            let layout = attachedMode ? attached : floating
            for dark in [false, true] {
                for glass in [false, true] {
                    settings.liquidGlass = glass
                    // 中间帧只看轮廓：真实动画里这个时刻内容的透明度还接近 0，
                    // 静态覆盖却会把它画成 100%，在轮廓边缘留下一圈被切开的界面碎片。
                    app.isExpanded = false
                    for (state, progress) in [("0-folded", 0.0), ("1-third", 0.33), ("2-two-thirds", 0.66),
                                              ("3-expanded-no-content", 1.0)] {
                        try exportPanel(app: app, layout: layout, attachedMode: attachedMode,
                                        progress: CGFloat(progress), dark: dark, to:
                            "\(directory)/panel-\(attachedMode ? "attached" : "floating")-\(glass ? "glass" : "solid")-\(state)-\(dark ? "dark" : "light").png")
                    }
                    // 展开态带内容：模块重新展开后等出真实读数，才能判断玻璃上的文字是否可读。
                    app.isExpanded = true
                    wait(1.5)
                    try exportPanel(app: app, layout: layout, attachedMode: attachedMode,
                                    progress: 1, dark: dark, to:
                        "\(directory)/panel-\(attachedMode ? "attached" : "floating")-\(glass ? "glass" : "solid")-4-expanded-\(dark ? "dark" : "light").png")
                }
            }
        }
        settings.notchAttached = true
    }

    private func exportPanel(app: AppModel, layout: PanelLayout, attachedMode: Bool,
                             progress: CGFloat, dark: Bool, to path: String) throws {
        let presentation = PanelPresentation()
        presentation.layout = layout
        presentation.isPresented = true
        let from = PanelOutline.folded(for: layout)
        let to = PanelOutline.expanded(for: layout)
        let panel = NotchDeckView()
            .environmentObject(app)
            .environmentObject(presentation)
            .environment(\.panelOutlineOverride, from.interpolated(toward: to, at: progress))
        let snapshot = ZStack(alignment: .top) {
            desktop(dark: dark)
            if attachedMode { hardwareNotch(layout: layout) }
            panel.frame(width: layout.frame.width, height: layout.frame.height)
        }
        try export(snapshot, size: layout.frame.size, dark: dark, to: path)
    }

    // MARK: - 工具

    /// 逐帧采样用例的前提：这个环境里的 SwiftUI 动画会逐帧推进。
    ///
    /// 这些断言依赖屏幕的刷新时钟。没有图形会话的 CI、SSH 会话里动画一帧都不走——那不是实现的
    /// 问题，像素与几何用例也不受影响。所以先用一个确定会动的形状探明：探针自己都采不到足够的
    /// 中间帧，依赖时钟的用例就跳过并写明原因。进程内只探一次。
    private func animationTicks() -> Bool {
        if let cached = Self.ticksCache { return cached }
        let app = makeApp()
        defer { app.shutdown() }
        let presentation = PanelPresentation()
        presentation.layout = attached
        let samples = OutlineSamples()
        PanelBodyShape.rendered = { [weak samples] shape, rect in
            samples?.record(tag: shape.debugTag, rawHeight: shape.height, rect: rect)
        }
        let host = NSHostingView(rootView: NotchDeckView()
            .environmentObject(app).environmentObject(presentation))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: attached.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        presentation.isPresented = true
        // 先让折叠轮廓渲染出来，再翻转；之后数不同的高度取值。
        wait(0.2)
        samples.mark()
        withAnimation(NotchMotion.unfold) { app.isExpanded = true }
        wait(0.5)
        PanelBodyShape.rendered = nil
        // 与夹具同理：必须真正结束这个窗口，否则它会污染之后每一条用例的采样。
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        let ticks = Set(samples.sinceMark.map(\.rect.height)).count >= 3
        Self.ticksCache = ticks
        return ticks
    }

    private static var ticksCache: Bool?

    /// 像素断言只针对不透明表面：`ImageRenderer` 画不出 `glassEffect` 的材质，只会留下垫在
    /// 玻璃后面的压暗层。玻璃开关默认开启，这里必须显式关闭；玻璃材质本身只能靠真实窗口目检。
    private func makeApp(liquidGlass: Bool = false) -> AppModel {
        let suite = "com.notchdeck.morph.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.liquidGlass = liquidGlass
        return AppModel(settings: settings, modules: [], plugins: [],
                        catalogFetch: { _ in AnyCancellable {} })
    }

    /// 默认挂载真实的 `NotchDeckView`；`layerOnly` 只挂载轮廓层，供无法注入的只读环境值做对照；
    /// `flipOnMount` 复现窗口控制器的时序——挂载回调在下一轮运行循环里翻转目标值。
    private func mount(layout: PanelLayout, reduceMotion: Bool = false,
                       layerOnly: Bool = false, flipOnMount: Bool = false) throws -> Harness {
        let app = makeApp()
        let presentation = PanelPresentation()
        presentation.layout = layout
        let samples = OutlineSamples()
        PanelBodyShape.rendered = { [weak samples] shape, rect in
            samples?.record(tag: shape.debugTag, rawHeight: shape.height, rect: rect)
        }
        let flag = FlipFlag()
        let root: AnyView = layerOnly
            ? AnyView(FlipPanel(layout: layout, flag: flag, reduceMotion: reduceMotion))
            : AnyView(NotchDeckView().environmentObject(app).environmentObject(presentation))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: layout.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // NSWindow 默认在 close 时额外释放一次；这里由 ARC 持有它，不设这一项 close 之后就是过度释放。
        window.isReleasedWhenClosed = false
        window.contentView = host
        // 屏幕外呈现窗口：让 SwiftUI 真正布局并逐帧渲染，又不打扰用户的桌面。
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        if flipOnMount {
            presentation.didMount = { [weak app] in
                DispatchQueue.main.async { app?.isExpanded = true }
            }
        }
        presentation.isPresented = true
        return Harness(app: app, presentation: presentation, window: window, samples: samples,
                       flag: layerOnly ? flag : nil)
    }

    private func render(layout: PanelLayout, progress: CGFloat, expanded: Bool,
                        background: Color = .clear) throws -> Bitmap {
        let app = makeApp()
        defer { app.shutdown() }
        app.isExpanded = expanded
        let presentation = PanelPresentation()
        presentation.layout = layout
        presentation.isPresented = true
        let from = PanelOutline.folded(for: layout)
        let to = PanelOutline.expanded(for: layout)
        let view = NotchDeckView()
            .environmentObject(app)
            .environmentObject(presentation)
            .environment(\.panelOutlineOverride, from.interpolated(toward: to, at: progress))
            .frame(width: layout.frame.width, height: layout.frame.height)
            .background(background)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try Bitmap(image: XCTUnwrap(renderer.cgImage, "面板渲染失败"))
    }

    private func export<V: View>(_ view: V, size: CGSize, dark: Bool, to path: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        wait(0.6)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "无法渲染 \(path)")
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// 截图用的桌面底：亮暗两套带纵向与横向变化的渐变，透明/玻璃区域是否可读一眼可见。
    private func desktop(dark: Bool) -> some View {
        LinearGradient(colors: dark
                       ? [Color(red: 0.32, green: 0.10, blue: 0.45), Color(red: 0.05, green: 0.35, blue: 0.55),
                          Color(red: 0.95, green: 0.55, blue: 0.15)]
                       : [Color(red: 1.00, green: 0.82, blue: 0.55), Color(red: 0.55, green: 0.85, blue: 0.95),
                          Color(red: 0.98, green: 0.45, blue: 0.55)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 硬件刘海的示意：窗口顶缘就是屏幕顶缘，刘海与颈部同宽同高。
    private func hardwareNotch(layout: PanelLayout) -> some View {
        let notch = notchedScreen.notch!
        return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                      bottomTrailingRadius: 10, topTrailingRadius: 0, style: .continuous)
            .fill(Color.black)
            .frame(width: notch.width, height: notch.height)
            .position(x: notch.midX - layout.frame.minX, y: notch.height / 2)
    }

    private func wait(_ seconds: TimeInterval) {
        let done = expectation(description: "等待 \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 3)
    }
}

@MainActor
private final class Harness {
    let app: AppModel
    let presentation: PanelPresentation
    let window: NSWindow
    let samples: OutlineSamples
    /// 只在只挂载轮廓层时存在：它翻转的是轮廓层自己的目标状态。
    let flag: FlipFlag?

    init(app: AppModel, presentation: PanelPresentation, window: NSWindow, samples: OutlineSamples,
         flag: FlipFlag?) {
        self.app = app
        self.presentation = presentation
        self.window = window
        self.samples = samples
        self.flag = flag
    }

    func release() {
        PanelBodyShape.rendered = nil
        // 必须真正结束这个窗口，而不只是 orderOut：移出屏幕的窗口仍然活着，动画还在跑，
        // 形状还在逐帧求值；采样钩子是全进程共用的一根，留着的窗口会把它的取值灌进
        // 下一条用例的采样里。先摘掉内容视图，SwiftUI 的视图图随之结束。
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        app.shutdown()
    }
}

@MainActor
private final class FlipFlag: ObservableObject {
    @Published var expanded = false
}

/// 只挂载轮廓层：`reduceMotion` 走显式入参。
private struct FlipPanel: View {
    let layout: PanelLayout
    @ObservedObject var flag: FlipFlag
    let reduceMotion: Bool

    var body: some View {
        PanelOutlineLayer(outline: flag.expanded ? .expanded(for: layout) : .folded(for: layout),
                          layout: layout, showsContent: flag.expanded, surface: .solid,
                          reduceMotion: reduceMotion) {
            Color.white
        }
    }
}

@MainActor
private final class OutlineSamples {
    struct Sample {
        let at: TimeInterval
        /// 形状的用途：0 = 本体填充，1 = 内容遮罩，2 = 悬浮卡片边线（内缩半个线宽，单独看待）。
        let tag: Int
        let rawHeight: CGFloat
        let rect: CGRect
    }

    private(set) var all: [Sample] = []
    private(set) var sinceMark: [Sample] = []
    private var marked = Date()

    func mark() {
        marked = Date()
        sinceMark = []
    }

    func record(tag: Int, rawHeight: CGFloat, rect: CGRect) {
        let sample = Sample(at: Date().timeIntervalSince(marked), tag: tag,
                            rawHeight: rawHeight, rect: rect)
        all.append(sample)
        sinceMark.append(sample)
    }
}

/// `ImageRenderer` 输出的像素读取：坐标以左上为原点，与窗口坐标一致。
/// 经由 `NSBitmapImageRep` 读取——把 CGImage 画进 CGContext 再按行取值的做法在这里上下颠倒过。
private final class Bitmap {
    let width: Int
    let height: Int
    private let rep: NSBitmapImageRep
    /// 8 位四通道时的原始字节与 alpha 偏移；其他格式退回逐点 `colorAt`。
    private let bytes: UnsafeMutablePointer<UInt8>?
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let alphaOffset: Int

    init(image: CGImage) {
        rep = NSBitmapImageRep(cgImage: image)
        width = rep.pixelsWide
        height = rep.pixelsHigh
        let raw: UnsafeMutablePointer<UInt8>? = rep.bitmapData
        let plain = rep.bitsPerSample == 8 && rep.samplesPerPixel == 4 && rep.hasAlpha && raw != nil
        bytes = plain ? raw : nil
        bytesPerRow = rep.bytesPerRow
        bytesPerPixel = rep.bitsPerPixel / 8
        alphaOffset = plain ? (rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3) : 0
    }

    func alpha(x: Int, y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        if let bytes {
            let i = y * bytesPerRow + x * bytesPerPixel
            return Double(bytes[i + alphaOffset]) / 255
        }
        return Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
    }

    func colour(x: Int, y: Int) -> (red: Double, green: Double, blue: Double)? {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// 第一个不透明却不在 `allowed`（外扩 1.5pt 容差）之内的像素。
    func firstOpaquePixel(outside allowed: [CGRect]) -> (x: Int, y: Int)? {
        let generous = allowed.map { $0.insetBy(dx: -1.5, dy: -1.5) }
        for y in 0..<height {
            for x in 0..<width where alpha(x: x, y: y) > 0.5 {
                if !generous.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { return (x, y) }
            }
        }
        return nil
    }

    /// `minY` 及其以下所有不透明像素的数量；`minY` ≤ 0 表示整张图。
    func opaqueCount(below minY: CGFloat = -1) -> Int {
        let firstRow = minY <= 0 ? 0 : Int(minY)
        var count = 0
        for y in firstRow..<height {
            for x in 0..<width where alpha(x: x, y: y) > 0.5 { count += 1 }
        }
        return count
    }
}
