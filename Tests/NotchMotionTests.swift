import SwiftUI
import XCTest

final class NotchMotionTests: XCTestCase {
    /// 展开弹簧必须是欠阻尼的：收起方向上过零后位移为负，那段时间屏幕上已经空了，
    /// 状态机才有机会把窗口悄悄移出去。临界阻尼不过零，`unfoldHold` 的前提就不成立。
    func testUnfoldSpringOvershootsOnce() throws {
        let crossings = try XCTUnwrap(NotchMotion.zeroCrossings(response: NotchMotion.unfoldResponse,
                                                                damping: NotchMotion.unfoldDamping))
        // 首次到位约 0.34s：不得比原先 0.42/0.85 的展开过渡明显慢，否则悬停唤起会觉得拖。
        XCTAssertLessThan(crossings.first, 0.4)
        XCTAssertGreaterThan(crossings.first, 0.2)
        XCTAssertLessThan(crossings.second, 1.0)
    }

    /// 状态机的等待时间必须落在"过零后为负"的窗口期内。
    /// 偏早：轮廓还没缩完，窗口被移出屏幕时会被截断成一帧；偏晚：弹簧回到正值，
    /// 已经空了的屏幕上会再冒出一条细边然后才消失。
    func testUnfoldHoldFallsInsideTheInvisibleWindow() throws {
        let crossings = try XCTUnwrap(NotchMotion.zeroCrossings(response: NotchMotion.unfoldResponse,
                                                                damping: NotchMotion.unfoldDamping))
        XCTAssertLessThan(crossings.first, NotchMotion.unfoldHold)
        XCTAssertLessThan(NotchMotion.unfoldHold, crossings.second)
    }

    func testDampedSpringsNeverCrossZero() {
        XCTAssertNil(NotchMotion.zeroCrossings(response: 0.62, damping: 1))
        XCTAssertNil(NotchMotion.zeroCrossings(response: 0.62, damping: 1.2))
        XCTAssertNil(NotchMotion.zeroCrossings(response: 0, damping: 0.72))
    }

    func testZeroCrossingsScaleWithResponse() throws {
        let quick = try XCTUnwrap(NotchMotion.zeroCrossings(response: 0.31, damping: 0.72))
        let slow = try XCTUnwrap(NotchMotion.zeroCrossings(response: 0.62, damping: 0.72))
        XCTAssertEqual(slow.first / quick.first, 2, accuracy: 0.001)
        XCTAssertEqual(slow.second / quick.second, 2, accuracy: 0.001)
    }

    /// 减弱动态效果去掉的是动画本身，不是把动画缩短——缩短后的位移仍然是位移。
    func testReducedMotionRemovesMovement() {
        XCTAssertNil(NotchMotion.unlessReducedMotion(NotchMotion.unfold, true))
        XCTAssertNotNil(NotchMotion.unlessReducedMotion(NotchMotion.unfold, false))
        XCTAssertNotNil(NotchMotion.unlessReducedMotion(NotchMotion.press, false))
    }

    func testReducedMotionOnlyKeepsAShortFade() {
        XCTAssertLessThanOrEqual(NotchMotion.stillDuration, 0.15)
    }
}
