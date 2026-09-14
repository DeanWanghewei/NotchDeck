import AppKit
import XCTest

final class PanelLayoutTests: XCTestCase {
    private var notchedScreen: PanelScreenGeometry {
        PanelScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874),
                            safeAreaTop: 38, menuBarThickness: 24,
                            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 656, height: 38),
                            auxiliaryTopRightArea: CGRect(x: 856, y: 944, width: 656, height: 38))
    }

    func testFloatingPanelClearsMenuBarAndDock() {
        let screen = notchedScreen
        let layout = PanelLayout(screen: screen, attached: false)
        XCTAssertEqual(layout.frame, CGRect(x: 496, y: 358, width: 520, height: 580))
        XCTAssertTrue(screen.visibleFrame.contains(layout.frame))
        XCTAssertEqual(layout.cardTop, 0)
        XCTAssertFalse(layout.isAttached)
    }

    func testAttachedPanelSharesCardTopAndHardwareCenter() {
        let layout = PanelLayout(screen: notchedScreen, attached: true)
        XCTAssertTrue(layout.isAttached)
        XCTAssertEqual(layout.frame.maxY, 982)
        XCTAssertEqual(layout.cardTop, 44)
        XCTAssertEqual(layout.frame.height - layout.cardTop, 580)
        XCTAssertEqual(layout.frame.minX + layout.neckCenterX, 756)
        XCTAssertEqual(layout.neckWidth, 180)
    }

    func testSideDockDoesNotShiftPanelAwayFromNotch() {
        var screen = notchedScreen
        screen.visibleFrame = CGRect(x: 80, y: 0, width: 1432, height: 944)
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertEqual(layout.frame.midX, screen.frame.midX)
        XCTAssertNotEqual(layout.frame.midX, screen.visibleFrame.midX)
    }

    func testClampedWindowKeepsNeckAlignedWithOffCenterNotch() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 700, height: 900),
            visibleFrame: CGRect(x: 120, y: 0, width: 580, height: 860),
            safeAreaTop: 40, menuBarThickness: 24,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 860, width: 250, height: 40),
            auxiliaryTopRightArea: CGRect(x: 410, y: 860, width: 290, height: 40))
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertTrue(layout.isAttached)
        XCTAssertEqual(layout.frame.minX, 120)
        XCTAssertEqual(layout.neckWidth, 160)
        XCTAssertEqual(layout.frame.minX + layout.neckCenterX, 330)
        XCTAssertEqual(screen.hotZone?.midX, 330)
    }

    func testAutoHiddenMenuBarStillReservesHardwareSafeArea() {
        var screen = notchedScreen
        screen.visibleFrame = screen.frame
        XCTAssertEqual(screen.menuBarHeight, 38)
        XCTAssertEqual(PanelLayout(screen: screen, attached: false).frame.maxY, 938)
    }

    func testMenuBarHeightChangeUpdatesWindowAndCardTogether() {
        var screen = notchedScreen
        screen.visibleFrame.size.height -= 12
        let attached = PanelLayout(screen: screen, attached: true)
        let floating = PanelLayout(screen: screen, attached: false)
        XCTAssertEqual(attached.cardTop, 56)
        XCTAssertEqual(attached.frame.maxY - attached.cardTop, floating.frame.maxY)
    }

    func testNoNotchFallsBackToFloatingAndSystemMenuBarThickness() {
        let screen = PanelScreenGeometry(frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                                         visibleFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                                         safeAreaTop: 0, menuBarThickness: 32)
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertFalse(layout.isAttached)
        XCTAssertEqual(layout.cardTop, 0)
        XCTAssertEqual(layout.frame.maxY, 1242)
        XCTAssertEqual(layout.frame.midX, -960)
        XCTAssertNil(screen.hotZone)
    }

    func testSmallScreenKeepsPanelWithinVisibleBounds() {
        let screen = PanelScreenGeometry(frame: CGRect(x: 0, y: -400, width: 400, height: 400),
                                         visibleFrame: CGRect(x: 60, y: -340, width: 340, height: 310),
                                         safeAreaTop: 0, menuBarThickness: 30)
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertEqual(layout.frame.width, 340)
        XCTAssertEqual(layout.frame.height, 304)
        XCTAssertTrue(screen.visibleFrame.contains(layout.frame))
    }

    func testNarrowNotchedScreenFallsBackWhenShouldersDoNotFit() {
        var screen = notchedScreen
        screen.visibleFrame = CGRect(x: 640, y: 70, width: 230, height: 874)
        let layout = PanelLayout(screen: screen, attached: true)
        XCTAssertFalse(layout.isAttached)
        XCTAssertTrue(screen.visibleFrame.contains(layout.frame))
    }

    func testHotZoneDoesNotLeakIntoDisplayAboveAndSupportsNegativeCoordinates() {
        var screen = notchedScreen
        screen.frame.origin = CGPoint(x: -1512, y: -982)
        screen.auxiliaryTopLeftArea = .zero
        screen.auxiliaryTopRightArea = .zero
        XCTAssertTrue(screen.containsInHotZone(CGPoint(x: -756, y: 0)))
        XCTAssertTrue(screen.containsInHotZone(CGPoint(x: -756, y: -4)))
        XCTAssertFalse(screen.containsInHotZone(CGPoint(x: -756, y: 1)))
        XCTAssertFalse(screen.containsInHotZone(CGPoint(x: -756, y: -6)))
        XCTAssertFalse(screen.containsInHotZone(CGPoint(x: -900, y: -2)))
    }
}
