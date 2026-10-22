import CoreGraphics
import XCTest

final class PanelVisibilityTests: XCTestCase {
    func testOtherOnScreenWindowsDoNotMakePanelVisible() {
        let windows: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 42)],
            [kCGWindowNumber as String: NSNumber(value: 99)],
        ]
        XCTAssertEqual(PanelVisibility.isOnScreen(windowNumber: 7, windows: windows), false)
        XCTAssertEqual(PanelVisibility.isOnScreen(windowNumber: 42, windows: windows), true)
    }

    func testEmptyMalformedAndUnavailableWindowLists() {
        XCTAssertEqual(PanelVisibility.isOnScreen(windowNumber: 7, windows: []), false)
        XCTAssertEqual(PanelVisibility.isOnScreen(windowNumber: 7, windows: [[:]]), false)
        XCTAssertEqual(PanelVisibility.isOnScreen(windowNumber: -1, windows: [[:]]), false)
        XCTAssertNil(PanelVisibility.isOnScreen(windowNumber: 7, windows: nil))
    }

    func testVisiblePanelWaitsForWindowServerAndConfirmsAfterTransition() {
        let fixture = RecoveryFixture()
        fixture.visible = true
        fixture.recovery.present()
        XCTAssertEqual(fixture.orders, 1)
        XCTAssertEqual(fixture.checks, 0)
        XCTAssertEqual(fixture.nextDelay, 0.1)
        fixture.runNext()
        XCTAssertEqual(fixture.nextDelay, 0.8)
        fixture.runNext()
        XCTAssertEqual(fixture.checks, 2)
        XCTAssertEqual(fixture.reattachments, 0)
        XCTAssertEqual(fixture.failures, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testStrandedPanelReattachesThenStopsRetryingOnceVisible() {
        let fixture = RecoveryFixture()
        fixture.recovery.present()
        fixture.runNext()
        XCTAssertEqual(fixture.orders, 2)
        XCTAssertEqual(fixture.reattachments, 1)
        fixture.visible = true
        fixture.runNext()
        fixture.runNext()
        XCTAssertEqual(fixture.orders, 2)
        XCTAssertEqual(fixture.failures, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testPanelThatDisappearsDuringFullScreenTransitionIsRecovered() {
        let fixture = RecoveryFixture()
        fixture.visible = true
        fixture.recovery.present()
        fixture.runNext()
        fixture.visible = false
        fixture.runNext()
        XCTAssertEqual(fixture.reattachments, 1)
        fixture.visible = true
        fixture.runNext()
        fixture.runNext()
        XCTAssertEqual(fixture.failures, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testPersistentFailureIsBoundedAndReportsFailureOnce() {
        let fixture = RecoveryFixture()
        fixture.recovery.present()
        for _ in 0..<10 where !fixture.pending.isEmpty { fixture.runNext() }
        XCTAssertEqual(fixture.orders, 5)
        XCTAssertEqual(fixture.reattachments, 4)
        XCTAssertEqual(fixture.failures, 1)
        XCTAssertEqual(fixture.delays, [0.1, 0.15, 0.3, 0.6, 1.0])
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testCollapseCancelsPendingRecoveryWithoutReopeningPanel() {
        let fixture = RecoveryFixture()
        fixture.recovery.present()
        fixture.runNext()
        fixture.recovery.cancel()
        fixture.runNext()
        XCTAssertEqual(fixture.orders, 2)
        XCTAssertEqual(fixture.checks, 1)
        XCTAssertEqual(fixture.failures, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testNewPresentationInvalidatesPreviousSpaceRecovery() {
        let fixture = RecoveryFixture()
        fixture.recovery.present()
        fixture.recovery.present()
        fixture.runNext()
        XCTAssertEqual(fixture.checks, 0)
        fixture.visible = true
        fixture.runNext()
        fixture.runNext()
        XCTAssertEqual(fixture.orders, 2)
        XCTAssertEqual(fixture.reattachments, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testUnavailableWindowServerDoesNotDismissOrReattachPanel() {
        let fixture = RecoveryFixture()
        fixture.visible = nil
        fixture.recovery.present()
        fixture.runNext()
        XCTAssertEqual(fixture.orders, 1)
        XCTAssertEqual(fixture.reattachments, 0)
        XCTAssertEqual(fixture.failures, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }
}

private final class RecoveryFixture {
    var visible: Bool? = false
    var checks = 0
    var orders = 0
    var reattachments = 0
    var failures = 0
    var delays: [TimeInterval] = []
    var pending: [(TimeInterval, () -> Void)] = []
    var nextDelay: TimeInterval? { pending.first?.0 }

    lazy var recovery = PanelVisibilityRecovery(
        isOnScreen: { [unowned self] in checks += 1; return visible },
        orderFront: { [unowned self] in orders += 1 },
        reattach: { [unowned self] in reattachments += 1 },
        didFail: { [unowned self] in failures += 1 },
        schedule: { [unowned self] delay, action in
            delays.append(delay)
            pending.append((delay, action))
        })

    func runNext() {
        guard !pending.isEmpty else {
            XCTFail("缺少预期的窗口核验回调")
            return
        }
        pending.removeFirst().1()
    }
}
