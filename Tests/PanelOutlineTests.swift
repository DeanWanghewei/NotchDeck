import SwiftUI
import XCTest

/// 轮廓形变的几何：折叠态必须完全藏进硬件刘海，展开态必须与原「凸字形」逐点一致，
/// 中间每一帧都是一份夹在窗口之内、不回退的合法轮廓。
final class PanelOutlineTests: XCTestCase {
    private let notchedScreen = PanelScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874),
        safeAreaTop: 38, menuBarThickness: 24,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 656, height: 38),
        auxiliaryTopRightArea: CGRect(x: 856, y: 944, width: 656, height: 38))
    private lazy var attached = PanelLayout(screen: notchedScreen, attached: true)
    private lazy var floating = PanelLayout(screen: notchedScreen, attached: false)

    private var bounds: CGRect { CGRect(origin: .zero, size: attached.frame.size) }

    // MARK: - 展开态

    func testExpandedAttachedOutlineIsTheCardBelowTheNeck() {
        let outline = PanelOutline.expanded(for: attached)
        XCTAssertEqual(outline.top, attached.cardTop)
        XCTAssertEqual(PanelBodyShape(outline).rect(in: bounds), CGRect(x: 0, y: 44, width: 520, height: 580))
        XCTAssertEqual(outline.insetLeading, 0)
        XCTAssertEqual(outline.insetTrailing, 0)
        XCTAssertEqual(outline.fillet, 14)
    }

    func testExpandedNeckMatchesTheHardwareNotchAndFlaresIntoTheCard() {
        let outline = PanelOutline.expanded(for: attached)
        let neck = PanelNeckShape(centerX: attached.neckCenterX, width: attached.neckWidth,
                                  bottom: outline.top, fillet: outline.fillet).path(in: bounds)
        // 颈部 170…350，两侧各外扩一个凹圆角；底缘与卡片顶缘重合。
        XCTAssertEqual(neck.boundingRect, CGRect(x: 156, y: 0, width: 208, height: 44))
        // 屏幕坐标下颈部完全落在硬件刘海的横向范围内。
        let hardware = notchedScreen.notch!
        XCTAssertTrue(hardware.minX <= attached.frame.minX + 170)
        XCTAssertTrue(attached.frame.minX + 350 <= hardware.maxX)

        // 凹角补件填的是圆弧以外的角落：紧贴卡片顶缘、颈部外侧 2pt 处应被填上，
        // 而圆弧以内的那块（补件自己的左上角附近）必须留空。
        XCTAssertTrue(neck.contains(CGPoint(x: 168, y: 43)))
        XCTAssertFalse(neck.contains(CGPoint(x: 157, y: 31)))
        // 右侧是左侧的镜像。
        XCTAssertTrue(neck.contains(CGPoint(x: 352, y: 43)))
        XCTAssertFalse(neck.contains(CGPoint(x: 363, y: 31)))
    }

    func testExpandedBodyHasRoundedCornersAndASolidCentre() {
        let body = PanelBodyShape(.expanded(for: attached)).path(in: bounds)
        XCTAssertTrue(body.contains(CGPoint(x: 260, y: 300)))
        XCTAssertTrue(body.contains(CGPoint(x: 0.5, y: 300)))
        // 左上角在圆角之内，不属于卡片。
        XCTAssertFalse(body.contains(CGPoint(x: 0.5, y: 44.5)))
        XCTAssertFalse(body.contains(CGPoint(x: 519.5, y: 44.5)))
        XCTAssertFalse(body.contains(CGPoint(x: 0.5, y: 623.5)))
        XCTAssertFalse(body.contains(CGPoint(x: 519.5, y: 623.5)))
    }

    // MARK: - 折叠态

    func testFoldedAttachedOutlineHidesInsideTheHardwareNotch() {
        let outline = PanelOutline.folded(for: attached)
        XCTAssertEqual(outline.top, notchedScreen.notch!.height)
        XCTAssertEqual(outline.top, attached.notchDepth)
        XCTAssertEqual(outline.bodyHeight, 0)
        XCTAssertTrue(PanelBodyShape(outline).path(in: bounds).isEmpty)

        // 颈部与硬件刘海同宽、底缘齐平：折叠态在屏幕上没有任何可见的黑色。
        XCTAssertEqual(bounds.width - outline.insetLeading - outline.insetTrailing, attached.neckWidth)
        let neck = PanelNeckShape(centerX: attached.neckCenterX, width: attached.neckWidth,
                                  bottom: outline.top, fillet: outline.fillet).path(in: bounds)
        XCTAssertEqual(neck.boundingRect, CGRect(x: 170, y: 0, width: 180, height: 38))
        XCTAssertLessThanOrEqual(neck.boundingRect.maxY, notchedScreen.notch!.height)
    }

    func testFoldedOutlineNeverEndsBelowTheNotchOnShortScreens() {
        // 屏幕过矮时颈部被压得比请求的短，折叠态仍不得低于硬件刘海底缘。
        let screen = PanelScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         visibleFrame: CGRect(x: 0, y: 950, width: 1512, height: 32),
                                         safeAreaTop: 38, menuBarThickness: 24)
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertLessThan(layout.cardTop, 38)
        let outline = PanelOutline.folded(for: layout)
        XCTAssertLessThanOrEqual(outline.top, layout.cardTop)
        XCTAssertEqual(outline.top, layout.notchDepth)
        XCTAssertEqual(outline.bodyHeight, 0)
    }

    func testFoldedFloatingOutlineIsACentreLineAsWideAsTheNeck() {
        let outline = PanelOutline.folded(for: floating)
        let rect = PanelBodyShape(outline).rect(in: CGRect(origin: .zero, size: floating.frame.size))
        XCTAssertEqual(rect.minX, floating.neckCenterX - PanelMetrics.neckWidth / 2)
        XCTAssertEqual(rect.midX, floating.neckCenterX)
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(rect.height, 0)
        XCTAssertEqual(outline.fillet, 0)
        XCTAssertTrue(PanelBodyShape(outline).path(in: CGRect(origin: .zero, size: floating.frame.size)).isEmpty)
    }

    func testFoldedFloatingOutlineStaysInsideNarrowWindows() {
        let screen = PanelScreenGeometry(frame: CGRect(x: 0, y: -400, width: 400, height: 400),
                                         visibleFrame: CGRect(x: 60, y: -340, width: 340, height: 310),
                                         safeAreaTop: 0, menuBarThickness: 30)
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertFalse(layout.isAttached)
        let bounds = CGRect(origin: .zero, size: layout.frame.size)
        let rect = PanelBodyShape(.folded(for: layout)).rect(in: bounds)
        XCTAssertTrue(bounds.contains(rect))
        XCTAssertEqual(rect.width, min(PanelMetrics.neckWidth, bounds.width))
    }

    // MARK: - 弹簧过冲

    func testOvershootIsClampedInsideTheWindow() {
        let expanded = PanelOutline.expanded(for: attached)
        // 阻尼 0.72 的过冲约 4%：高度多出约 23pt、两侧内缩变成负值；顶缘只多出零点几个点。
        let overshoot = PanelOutline(top: expanded.top + 0.25, bodyHeight: expanded.bodyHeight + 23,
                                     insetLeading: -7, insetTrailing: -7, fillet: expanded.fillet + 0.5)
        let rect = PanelBodyShape(overshoot).rect(in: bounds)
        // 两侧与底边被夹在窗口边缘上——圆角不会被窗口切平；顶缘有余量，照常过冲。
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.width, bounds.width)
        XCTAssertEqual(rect.maxY, bounds.maxY)
        XCTAssertEqual(rect.minY, expanded.top + 0.25, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rect.height, expanded.bodyHeight)
        XCTAssertTrue(bounds.contains(rect))

        let folded = PanelOutline.folded(for: attached)
        let undershoot = PanelOutline(top: folded.top - 1, bodyHeight: -20,
                                      insetLeading: folded.insetLeading + 7, insetTrailing: folded.insetTrailing + 7,
                                      fillet: -0.5)
        let collapsed = PanelBodyShape(undershoot).rect(in: bounds)
        XCTAssertEqual(collapsed.height, 0)
        XCTAssertGreaterThanOrEqual(collapsed.minY, 0)
    }

    // MARK: - 中间帧

    func testInterpolatedOutlinesStayInsideTheWindowAndNeverReverse() throws {
        for layout in [attached, floating] {
            let bounds = CGRect(origin: .zero, size: layout.frame.size)
            let from = PanelOutline.folded(for: layout)
            let to = PanelOutline.expanded(for: layout)
            var previous = PanelBodyShape(from).rect(in: bounds)
            var steps: [CGFloat] = []
            for step in 0...20 { steps.append(CGFloat(step) / 20) }
            for progress in steps.dropFirst() {
                let rect = PanelBodyShape(from.interpolated(toward: to, at: progress)).rect(in: bounds)
                XCTAssertTrue(bounds.contains(rect))
                XCTAssertGreaterThanOrEqual(rect.minY, previous.minY)
                XCTAssertGreaterThanOrEqual(rect.height, previous.height)
                XCTAssertGreaterThanOrEqual(rect.width, previous.width)
                previous = rect
            }
            XCTAssertEqual(previous, PanelBodyShape(to).rect(in: bounds))
        }
    }

    func testNeckBottomAndBodyTopAreOneLineThroughoutTheMorph() {
        let from = PanelOutline.folded(for: attached)
        let to = PanelOutline.expanded(for: attached)
        for step in 0...20 {
            let outline = from.interpolated(toward: to, at: CGFloat(step) / 20)
            let body = PanelBodyShape(outline).rect(in: bounds)
            let neck = PanelNeckShape(centerX: attached.neckCenterX, width: attached.neckWidth,
                                      bottom: outline.top, fillet: outline.fillet).path(in: bounds)
            XCTAssertEqual(neck.boundingRect.maxY, body.minY, accuracy: 0.001)
            // 凹角补件只往卡片顶缘上方长，始终在颈部两侧、不越过颈部中线。
            XCTAssertLessThanOrEqual(neck.boundingRect.maxX - neck.boundingRect.minX,
                                     attached.neckWidth + 2 * PanelMetrics.fillet + 0.001)
        }
    }

    /// 形变全程，凹角补件的外缘都落在卡片本体顶边的一段直线上：
    /// 补件经一段圆弧把颈侧接到卡片顶边，接的那一点必须在卡片上，否则接缝处会豁开缺口。
    func testFilletPiecesAlwaysLandOnAStraightStretchOfTheCardTop() {
        let from = PanelOutline.folded(for: attached)
        let to = PanelOutline.expanded(for: attached)
        let neck = PanelNeckSpan(layout: attached)
        for step in 0...40 {
            let outline = from.interpolated(toward: to, at: CGFloat(step) / 40)
            let shape = PanelBodyShape(outline, neck: neck)
            let body = shape.rect(in: bounds)
            guard body.height > 0 else { continue }
            let path = shape.path(in: bounds)
            // 紧贴凹角外缘内侧、卡片顶边下方一点：圆角若伸进这一段，这点就落在卡片之外。
            XCTAssertTrue(path.contains(CGPoint(x: neck.leading - outline.fillet + 0.5, y: body.minY + 0.25)),
                          "第 \(step)/40 帧：左凹角接在了卡片的圆角上")
            XCTAssertTrue(path.contains(CGPoint(x: neck.trailing + outline.fillet - 0.5, y: body.minY + 0.25)),
                          "第 \(step)/40 帧：右凹角接在了卡片的圆角上")
            // 颈部正下方的整段顶边都是直的。
            XCTAssertTrue(path.contains(CGPoint(x: neck.leading + 0.5, y: body.minY + 0.25)))
            XCTAssertTrue(path.contains(CGPoint(x: neck.trailing - 0.5, y: body.minY + 0.25)))
        }
    }

    /// 展开后顶角恢复完整的 26pt 圆角：肩部长过凹角之后，圆角必须长回来。
    func testExpandedBodyKeepsItsFullTopCorners() {
        let shape = PanelBodyShape(.expanded(for: attached), neck: PanelNeckSpan(layout: attached))
        let path = shape.path(in: bounds)
        XCTAssertTrue(path.contains(CGPoint(x: 170 - 14 + 0.5, y: 44.25)))
        // 距左缘 1pt、距顶缘 1pt 处在 26pt 圆角之内，不属于卡片。
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 45)))
    }

    /// 没有颈部的悬浮卡片不受这条规则约束：顶角从一开始就按完整半径倒圆。
    func testFloatingBodyAlwaysRoundsItsTopCorners() {
        let from = PanelOutline.folded(for: floating)
        let to = PanelOutline.expanded(for: floating)
        let bounds = CGRect(origin: .zero, size: floating.frame.size)
        for step in 0...20 {
            let shape = PanelBodyShape(from.interpolated(toward: to, at: CGFloat(step) / 20))
            let body = shape.rect(in: bounds)
            guard body.height > 2 else { continue }
            XCTAssertFalse(shape.path(in: bounds).contains(CGPoint(x: body.minX + 0.5, y: body.minY + 0.5)),
                           "第 \(step)/20 帧：悬浮卡片的顶角是方的")
        }
    }
}
