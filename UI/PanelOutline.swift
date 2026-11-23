import SwiftUI

/// 面板轮廓的形变参数。每一项都是"形状自己的长度"：折叠态与展开态之间由弹簧逐项插值，
/// 所以中间每一帧都是一份合法的轮廓。
///
/// 状态差异不做成切换。展开若写成"插入/移除一个视图"，能缓动的只剩淡入淡出；
/// 只有把轮廓写成数，黑色本体才能从刘海里长出来（见 `PanelBodyShape.animatableData`）。
struct PanelOutline: Equatable {
    /// 卡片顶缘的 y；接壤模式下也是颈部的底缘。
    var top: CGFloat
    /// 卡片本体的高度。
    var bodyHeight: CGFloat
    /// 卡片左右两侧相对窗口边缘的内缩；0 表示与窗口同宽。
    var insetLeading: CGFloat
    var insetTrailing: CGFloat
    /// 颈部与卡片衔接处凹圆角的半径；悬浮卡片没有颈部，恒为 0。
    var fillet: CGFloat

    static let cornerRadius = PanelMetrics.cornerRadius

    /// 展开轮廓：卡片占满颈部以下的全部窗口。
    static func expanded(for layout: PanelLayout) -> PanelOutline {
        PanelOutline(top: layout.cardTop,
                     bodyHeight: layout.frame.height - layout.cardTop,
                     insetLeading: 0, insetTrailing: 0,
                     fillet: layout.isAttached ? fillet(for: layout) : 0)
    }

    /// 折叠轮廓：形变的起点。
    ///
    /// 接壤模式下颈部收回到硬件刘海之内——窗口顶缘就是屏幕顶缘，颈部与刘海同宽，
    /// 所以折叠态在屏幕上什么都没有。悬浮模式下收成顶缘中央、与颈部同宽的一条线：
    /// 收起态窗口本来就不在屏幕上，这只是让卡片从中央长出来，而不是整块淡入。
    static func folded(for layout: PanelLayout) -> PanelOutline {
        let width = layout.frame.width
        guard layout.isAttached else {
            let compact = min(PanelMetrics.neckWidth, width)
            let leading = min(max(layout.neckCenterX - compact / 2, 0), width - compact)
            return PanelOutline(top: 0, bodyHeight: 0,
                                insetLeading: leading, insetTrailing: width - compact - leading,
                                fillet: 0)
        }
        return PanelOutline(top: layout.notchDepth, bodyHeight: 0,
                            insetLeading: layout.neckCenterX - layout.neckWidth / 2,
                            insetTrailing: width - layout.neckCenterX - layout.neckWidth / 2,
                            fillet: 0)
    }

    /// 凹圆角在展开态的实际半径：被颈部半宽、肩部可用宽度与颈部高度共同限住，
    /// 保证补件既不伸进卡片本体的圆角，也不高过颈部。
    private static func fillet(for layout: PanelLayout) -> CGFloat {
        let shoulder = min(layout.neckCenterX - layout.neckWidth / 2,
                           layout.frame.width - layout.neckCenterX - layout.neckWidth / 2)
        return max(0, min(PanelMetrics.fillet, layout.neckWidth / 2 - 1,
                          shoulder - cornerRadius - 1, layout.cardTop / 2))
    }

    /// 两份轮廓之间的插值。弹簧只驱动这一个进度，所有长度随之同步变化，
    /// 颈部底缘与卡片顶缘在任何时刻都是同一条线。
    func interpolated(toward target: PanelOutline, at progress: CGFloat) -> PanelOutline {
        func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
        return PanelOutline(top: mix(top, target.top),
                            bodyHeight: mix(bodyHeight, target.bodyHeight),
                            insetLeading: mix(insetLeading, target.insetLeading),
                            insetTrailing: mix(insetTrailing, target.insetTrailing),
                            fillet: mix(fillet, target.fillet))
    }
}

/// 直接指定面板轮廓：像素测试与截图据此给出"第几帧"的确定轮廓，不必等待动画。
/// 应用运行时从不设置。
private struct PanelOutlineOverrideKey: EnvironmentKey {
    static let defaultValue: PanelOutline? = nil
}

extension EnvironmentValues {
    var panelOutlineOverride: PanelOutline? {
        get { self[PanelOutlineOverrideKey.self] }
        set { self[PanelOutlineOverrideKey.self] = newValue }
    }
}

/// 接壤模式下颈部两条侧边在窗口坐标里的位置。
struct PanelNeckSpan: Equatable {
    var leading: CGFloat
    var trailing: CGFloat

    init(layout: PanelLayout) {
        leading = layout.neckCenterX - layout.neckWidth / 2
        trailing = layout.neckCenterX + layout.neckWidth / 2
    }
}

/// 卡片本体：一段连续圆角矩形，位置与大小都是可插值的"形状自己的长度"。
///
/// 轮廓由 `PanelOutline` 写成数还不够——弹簧插值的是 `animatableData`。少了它，折叠开始的
/// 那一帧形状会按新参数重建，只有外框在动，圆角与凹角则是瞬间跳到位。
struct PanelBodyShape: Shape, InsettableShape {
    var top: CGFloat
    var height: CGFloat
    var insetLeading: CGFloat
    var insetTrailing: CGFloat
    /// 接壤模式下颈部的横向范围；悬浮卡片没有颈部，为 nil。
    var neck: PanelNeckSpan?
    /// 颈部与卡片衔接处凹圆角的半径，随轮廓一起插值。
    var fillet: CGFloat

    init(_ outline: PanelOutline, neck: PanelNeckSpan? = nil) {
        top = outline.top
        height = outline.bodyHeight
        insetLeading = outline.insetLeading
        insetTrailing = outline.insetTrailing
        self.neck = neck
        fillet = outline.fillet
    }

    /// 贴边容差：距窗口边缘不足这个量的内缩/高度直接吸附到边缘。
    static let edgeEpsilon: CGFloat = 0.1

    /// 夹在窗口之内。卡片展开后与窗口同宽同高，弹簧的过冲没有地方可去；不夹的话，
    /// 过冲那几帧的圆角会被窗口边缘切平，左上角看起来像被削掉一块。夹住之后过冲只剩
    /// 圆角的轻微起伏——是"回稳"，不是"弹一下"。不为过冲去放大窗口：多出来的透明边会吞掉
    /// 本该落到下层窗口的点击。
    ///
    /// 吸附：SwiftUI 动画的最后一帧不保证精确落在目标值上（实测残差可达 0.05pt）。
    /// 静止的卡片若比窗口窄零点几个点，边缘就是一条亚像素的透明细边——刘海形面板一旦
    /// 露出这种细边，读起来就像浮在边框上而不是长在边框上。
    func rect(in bounds: CGRect) -> CGRect {
        let top = min(max(self.top, bounds.minY), bounds.maxY)
        let leading = max(0, insetLeading)
        let trailing = max(0, insetTrailing)
        let snappedLeading = leading < Self.edgeEpsilon ? 0 : leading
        let snappedTrailing = trailing < Self.edgeEpsilon ? 0 : trailing
        let fullHeight = bounds.maxY - top
        let height = max(0, min(height, fullHeight))
        return CGRect(x: bounds.minX + snappedLeading, y: top,
                      width: max(0, bounds.width - snappedLeading - snappedTrailing),
                      height: fullHeight - height < Self.edgeEpsilon ? fullHeight : height)
    }

    func path(in rect: CGRect) -> Path {
        #if DEBUG
        // 供测试逐帧采样：Animatable 形状每一帧都会重新求 path，这里是唯一能观察到
        // 弹簧插值结果的位置。仅在 Debug 构建存在，Release 不保留任何状态。
        Self.rendered?(self, self.rect(in: rect))
        #endif
        let body = self.rect(in: rect)
        guard body.width > 0, body.height > 0 else { return Path() }
        let radius = min(PanelOutline.cornerRadius, body.width / 2, body.height / 2)
        // 顶缘从颈侧到凹角外缘的这一段必须是直线：凹角补件的前提是颈部经一段圆弧直接接到卡片顶边。
        // 形变刚开始时本体只比颈部宽一点，若顶角照常画 26pt，圆弧会落在颈部两侧，
        // 颈部底角与本体圆弧之间就豁出一个小缺口。所以肩部还没长过凹角时顶角是方的，
        // 长过去之后圆角再长出来——半径由动画中的长度当场推导，不会跳变。
        let topLeading: CGFloat, topTrailing: CGFloat
        if let neck {
            let fillet = max(0, self.fillet)
            topLeading = max(0, min(radius, (neck.leading - fillet - body.minX) / Self.continuousCornerReach))
            topTrailing = max(0, min(radius, (body.maxX - neck.trailing - fillet) / Self.continuousCornerReach))
        } else {
            topLeading = radius
            topTrailing = radius
        }
        return UnevenRoundedRectangle(topLeadingRadius: topLeading, bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius, topTrailingRadius: topTrailing,
                                      style: .continuous).path(in: body)
    }

    /// 连续圆角（`.continuous`）沿边的实际延伸量，相对标称半径的倍数。
    ///
    /// 它不是圆弧：曲率从 0 缓升，曲线要越过标称半径之后才逐渐平到边上。macOS 27.3 实测，
    /// 曲线平到距边 0.05pt 以内的位置在 1.18~1.27 倍半径之间（r = 2 / 10 / 19.5 / 23.4 / 26 / 40
    /// 六档；另测 r = 5 一档得到 1.00，原因未查明）。判断"顶边某处是不是直线"必须用这个系数，
    /// 按 1:1 算会差出几个点；这里取实测偏大的一侧再留余量。
    static let continuousCornerReach: CGFloat = 1.3

    var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>,
        AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(AnimatablePair(top, height),
                                          AnimatablePair(insetLeading, insetTrailing)),
                           AnimatablePair(fillet, 0))
        }
        set {
            top = newValue.first.first.first
            height = newValue.first.first.second
            insetLeading = newValue.first.second.first
            insetTrailing = newValue.first.second.second
            fillet = newValue.second.first
        }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.top += amount
        shape.height -= 2 * amount
        shape.insetLeading += amount
        shape.insetTrailing += amount
        return shape
    }

    #if DEBUG
    static var rendered: ((PanelBodyShape, CGRect) -> Void)?
    /// 仅供测试区分同一形状的三种用途（本体填充 / 内容遮罩 / 悬浮卡片边线），不属于 animatableData。
    var debugTag = 0
    #endif
}

/// 颈部与两侧凹角补件：始终黑色。它要和硬件刘海读成同一块黑，
/// 所以卡片本体换成玻璃时它不换。
struct PanelNeckShape: Shape {
    var centerX: CGFloat
    var width: CGFloat
    /// 颈部底缘，与卡片顶缘是同一条线。
    var bottom: CGFloat
    var fillet: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottom, fillet) }
        set {
            bottom = newValue.first
            fillet = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard width > 0, bottom > rect.minY else { return Path() }
        let leading = centerX - width / 2
        let trailing = centerX + width / 2
        var path = Path(CGRect(x: leading, y: rect.minY, width: width,
                               height: min(bottom, rect.maxY) - rect.minY))
        let radius = max(0, min(fillet, width / 2 - 1,
                                min(leading - rect.minX, rect.maxX - trailing) - PanelOutline.cornerRadius - 1,
                                (bottom - rect.minY) / 2))
        guard radius > 0 else { return path }
        let piece = CGRect(x: leading - radius, y: bottom - radius, width: radius, height: radius)
        path.addPath(ConcaveFilletPiece(radius: radius).path(in: piece))
        // 右侧补件是左侧关于颈部中线的镜像。
        path.addPath(ConcaveFilletPiece(radius: radius).path(in: piece)
            .applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * centerX, ty: 0)))
        return path
    }
}

/// 凹角填充件：方形区域减去左上角四分之一圆——黑色填充后呈现颈部与卡片
/// 衔接处的凹圆角。左颈用原样，右颈由 `PanelNeckShape` 水平镜像。
struct ConcaveFilletPiece: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        let start = CGFloat(0) * .pi / 180
        let end = CGFloat(90) * .pi / 180
        for i in 0...16 {
            let t = start + (end - start) * CGFloat(i) / 16
            p.addLine(to: CGPoint(x: rect.minX + radius * cos(t), y: rect.minY + radius * sin(t)))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
