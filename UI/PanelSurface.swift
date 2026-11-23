import AppKit
import SwiftUI

/// 面板表面的唯一真相：玻璃开关、系统能力与辅助功能设置归一后的结果。
/// 视图只消费这里的结果，不各自判断"现在该不该用玻璃"。
enum PanelSurfaceStyle: Equatable {
    /// 不透明：开关关闭，或系统开启了「减少透明度」/「增强对比度」。
    case solid
    /// 系统 Liquid Glass（macOS 26+）。
    case glass
    /// 开关打开但系统不支持时的毛玻璃兜底。
    case legacyBlur

    /// 当前构建能否使用 Liquid Glass：需要 macOS 26 的运行时与 Xcode 26 的 SDK。
    /// 旧 SDK 仍可构建出毛玻璃版本。
    static var glassAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 辅助功能优先于开关：「减少透明度」「增强对比度」要的是不透明的界面，
    /// 任何材质都不该盖过它们。
    static func resolve(glassEnabled: Bool, glassAvailable: Bool,
                        reduceTransparency: Bool, increasedContrast: Bool) -> PanelSurfaceStyle {
        if reduceTransparency || increasedContrast { return .solid }
        guard glassEnabled else { return .solid }
        return glassAvailable ? .glass : .legacyBlur
    }
}

/// 卡片本体的表面。玻璃是不被裁剪的兄弟图层：折射与边缘高光画在玻璃自己的边上，
/// 套在裁剪或缩放里的玻璃会退化成一层平磨砂。轮廓变化时玻璃跟着自己的形状一起形变。
struct PanelBodySurface: View {
    let shape: PanelBodyShape
    let attached: Bool
    let style: PanelSurfaceStyle

    /// 接壤模式下垫在玻璃后面的黑色压暗。黑色硬件刘海下面直接接一块透亮的玻璃，
    /// 亮色壁纸会把白字洗掉；压暗后保留透过来的明暗，又压得住读数所需的对比。
    ///
    /// 按最悲观的情况取值——假设材质本身不压暗，卡片就只是"背景 × (1 − 压暗)"：纯白壁纸下
    /// 要让白字达到正文可读的 4.5:1，压暗须 ≥ 0.54（取 0.6 留出余量，实测该模型下 5.7:1）。
    /// 最初的 0.35 在亮色渐变上实测白字只有 3.3~3.6:1、灰色次要文字 1.3:1，不可读。
    /// 实机复核：深色外观下材质本身几乎不压暗（卡片 ≈ 背景 × (1 − 压暗)，实测通道比值 0.41），
    /// 所以上面的假设就是实际情况——0.6 是实际生效的值，不是下限，不能再低。
    static let attachedGlassDim: CGFloat = 0.6

    var body: some View {
        switch style {
        case .solid:
            shape.fill(attached ? Color.black : Color(nsColor: .windowBackgroundColor))
        case .legacyBlur:
            legacy
        case .glass:
            glass
        }
    }

    @ViewBuilder
    private var legacy: some View {
        if attached {
            // 颈部与卡片同为黑色底，避免系统浅色玻璃在刘海下形成亮色接缝。
            shape.fill(Color.black)
                .overlay { VisualEffectBackground().opacity(0.55).clipShape(shape) }
        } else {
            VisualEffectBackground()
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                .clipShape(shape)
        }
    }

    @ViewBuilder
    private var glass: some View {
        // Swift 6.2 / Xcode 26 起提供玻璃 API；仍允许用旧 SDK 构建毛玻璃版本。
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .background { if attached { shape.fill(Color.black.opacity(Self.attachedGlassDim)) } }
        } else {
            legacy
        }
        #else
        legacy
        #endif
    }
}

/// 轮廓层：按一份确定的轮廓画本体表面与颈部，并把内容裁进这团轮廓。
///
/// `PanelRoot` 只负责决定"现在是哪一份轮廓"；这一层拿到什么就画什么——像素测试因此可以
/// 直接喂折叠 / 中间 / 展开三份轮廓，不必等待动画。内容按展开后的几何一次排好、全程不移动，
/// 只被这团轮廓遮住或露出：动的只有遮罩。
struct PanelOutlineLayer<Content: View>: View {
    let outline: PanelOutline
    let layout: PanelLayout
    /// 内容是否已经属于展开态：决定淡入与可点击，不决定轮廓；也是形变的触发条件（见 `motion`）。
    let showsContent: Bool
    let surface: PanelSurfaceStyle
    /// 由 `PanelRoot` 从环境读出后传入：`accessibilityReduceMotion` 是只读环境值，
    /// 做成显式入参后测试可以直接构造"减弱动态效果"下的轮廓层。
    var reduceMotion = false
    @ViewBuilder let content: () -> Content

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let body = PanelBodyShape(outline, neck: layout.isAttached ? PanelNeckSpan(layout: layout) : nil)
        // 形变只由"展开/收起"触发——`showsContent` 恰好只在这一刻翻转。不以轮廓本身为触发条件：
        // 菜单栏高度变化、换屏、切换接壤/悬浮也会改轮廓，那些是布局变化，窗口与内容都是瞬间
        // 到位的，唯独轮廓被拖成半秒的形变只会让遮罩追不上内容。
        let motion: Animation? = NotchMotion.unlessReducedMotion(NotchMotion.unfold, reduceMotion)
        // 遮罩与填充是同一个形状的同一份数值，只用于区分用途（测试据此验证两者始终同帧同值）。
        let mask: PanelBodyShape = {
            var mask = body
            #if DEBUG
            mask.debugTag = 1
            #endif
            return mask
        }()
        ZStack(alignment: .top) {
            PanelBodySurface(shape: body, attached: layout.isAttached, style: surface)
                .animation(motion, value: showsContent)
            content()
                // 位移在裁剪之前：内容从轮廓上缘后面滑出来，而不是连着遮罩一起挪。
                .offset(y: showsContent || reduceMotion ? 0 : -NotchMotion.contentRise)
                .opacity(showsContent ? 1 : 0)
                // 只有内容的淡入与位移走 `contents`。挂在裁剪外层的话，它会连带驱动遮罩，
                // 遮罩就和本体不在同一条弹簧上：收起时遮罩一旦落后于本体，内容会溢出卡片。
                .animation(reduceMotion ? NotchMotion.still
                                        : NotchMotion.contents.delay(showsContent ? NotchMotion.contentBeat : 0),
                           value: showsContent)
                .padding(.top, layout.cardTop)
                .clipShape(mask)
                // 遮罩与本体是同一个时钟——包括减弱动态效果时一同直接落位。
                .animation(motion, value: showsContent)
                .allowsHitTesting(showsContent)
            if layout.isAttached {
                PanelNeckShape(centerX: layout.neckCenterX, width: layout.neckWidth,
                               bottom: outline.top, fillet: outline.fillet)
                    .fill(Color.black)
                    .animation(motion, value: showsContent)
            } else {
                // 悬浮卡片在浅色壁纸/浅色窗口下需要一条边线与背景分开；接壤卡片与刘海同为黑色，不需要。
                // strokeBorder 自己会把轮廓内缩半个线宽，边线正好贴在卡片内侧；不再额外内缩。
                let border: PanelBodyShape = {
                    var border = body
                    #if DEBUG
                    border.debugTag = 2
                    #endif
                    return border
                }()
                border.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.12), lineWidth: 1)
                    .animation(motion, value: showsContent)
            }
        }
    }
}
