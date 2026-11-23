import Foundation
import SwiftUI

/// 运动词汇表：全应用的动效曲线只在这里定义，视图与窗口控制器只引用名字。
///
/// 面板形变与容器内的布局变化一律用弹簧：macOS 的动效有"物理感"，是因为物体略微过冲再停住；
/// 只做缩放/位移而没有过冲，读起来像幻灯片切换。数值取在"刚好不发弹"之下——阻尼 0.7 出头
/// 只回稳一次，不会来回晃。数据读数与内容替换沿用 `docs/design-conventions.md` 里的时长，
/// 那是已经按"无皮筋感"调过并写进约束的部分。
/// 改任何数值前先改对应的注释：注释写的是取舍，不是数值的复述。
enum NotchMotion {
    // MARK: - 面板形变

    static let unfoldResponse: TimeInterval = 0.62
    static let unfoldDamping: CGFloat = 0.72
    /// 卡片本体在折叠轮廓与展开轮廓之间的形变。
    ///
    /// 比原先展开过渡的 0.42/0.85 更重、更松：那组数配"淡入 + 缩放"合适，配形变读起来像拨开关。
    /// 面板应当像一团液体改变形状——慢到有质量，阻尼停在"不会骤停"之下，于是它是"回稳"
    /// 而不是"到达"。首次到位约 0.34s，与原过渡的实际完成时间相当，悬停唤起不会变慢。
    static let unfold = Animation.spring(response: unfoldResponse, dampingFraction: unfoldDamping)

    /// 形变开始后内容跟进。比 `unfold` 略快，读数追上黑色本体而不是拖在后面。
    static let contents = Animation.spring(response: 0.48, dampingFraction: 0.8)

    /// 内容折叠时朝屏幕上缘后退的距离。只做短位移、不做缩放：遮罩已经在负责遮挡，
    /// 再叠一个缩放就成了两种效果互相打架。
    static let contentRise: CGFloat = 10

    /// 展开时内容晚一拍出现，让本体先长出来；收起时不等，直接跟着轮廓缩回去。
    /// 开与关本来就不是镜像：收起时任何延迟都会让内容露在已经缩小的轮廓外面。
    static let contentBeat: TimeInterval = 0.06

    /// 列表里的条目逐个跟进：每一条落在前一条之后，整组像依次铺开而不是一起出现。
    /// 每条 45ms、封顶 180ms——条目再多也不拖成一场仪式。
    static func stagger(_ index: Int) -> Animation {
        contents.delay(min(Double(max(0, index)) * 0.045, 0.18))
    }

    /// 条目跟进时朝来处退回的距离。比面板内容的 `contentRise` 短：这里的条目只有一行文字那么高，
    /// 退得太多会让相邻条目看起来在互相穿插。
    static let listRise: CGFloat = 6

    /// "正在重新取数"的反馈：恰好转一整圈回到原位，转完自己停下。
    ///
    /// 不用 `repeatForever`：它不会因为把值设回去而停止，而目标值若正好是它正在趋近的值，
    /// SwiftUI 根本不会开新事务，动画就一直转下去。有限的一圈没有取消问题——转完就是原位，
    /// 取数比一圈还慢时图标安静地停着，也比一直转更克制。
    static let refresh = Animation.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)

    /// 形变开始后，状态机等待多久再认定"已到位"（可以再次切换；收起时到点把窗口移出屏幕）。
    ///
    /// 不是弹簧完全静止的时间。收起时弹簧约 0.34s 第一次过零，随后过冲到负值——被轮廓
    /// 夹到 0，屏幕上已经空了——约 0.79s 才回到正值，再冒出约半个点的高度。窗口必须在这段
    /// "值为负、看不见"的窗口期内移出屏幕，否则收到最后会闪一下细条。`zeroCrossings`
    /// 把这个关系写成可测试的断言：重新调 `unfold` 时，这个数必须跟着重新落位。
    static let unfoldHold: TimeInterval = 0.45

    /// 欠阻尼弹簧从静止出发后的前两次过零时刻。两次之间位移为负，收起方向上就是
    /// "屏幕上已经空了"的那段时间。临界阻尼及以上不过零，返回 nil。
    static func zeroCrossings(response: TimeInterval, damping: CGFloat) -> (first: TimeInterval, second: TimeInterval)? {
        guard response > 0, damping > 0, damping < 1 else { return nil }
        let zeta = Double(damping)
        let omega = 2 * Double.pi / response
        let decay = (1 - zeta * zeta).squareRoot()
        let damped = omega * decay
        // 单位阶跃响应 e^(−ζωt)·(cos ωdt + ζ/√(1−ζ²)·sin ωdt) 的零点：tan θ = −√(1−ζ²)/ζ。
        let phase = Double.pi - atan(decay / zeta)
        return (phase / damped, (phase + Double.pi) / damped)
    }

    // MARK: - 容器与数据

    /// 容器内元素的增删、重排与切换（应用列表、自定义子项、标签页、监控明细）。
    /// 取代此前 0.3/0.85、0.35/0.85、0.3/0.8 三组相近的数：差别眼睛分辨不出，
    /// 却让同一类变化在不同页面手感不一致。
    static let layout = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// 用量图形（长条、圆环）过渡到新读数。扫过去读起来是"一次测量"，跳过去读起来像故障。
    static let reading = Animation.easeInOut(duration: 0.35)

    /// 内容替换（明细切换、热压力状态变化）：双方都在动，用短交叉淡入，弹簧在这里只会迟到。
    static let crossfade = Animation.easeInOut(duration: 0.2)

    /// 从无到有的首次出现。
    static let appear = Animation.easeOut(duration: 0.2)

    /// 按钮按压反馈：按下去快、弹回来带一点弹性。
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.55)

    // MARK: - 减弱动态效果

    /// 系统开启"减弱动态效果"时唯一保留的动画：纯淡入淡出，不做位移与形变。
    static let still = Animation.easeOut(duration: 0.12)
    static let stillDuration: TimeInterval = 0.12

    /// 减弱动态效果时去掉以位移/缩放/形变表达的动画——视图直接落在终值，
    /// 而不是把动画缩短（缩短后的位移仍然是位移）。
    static func unlessReducedMotion(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
