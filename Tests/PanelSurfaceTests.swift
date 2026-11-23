import SwiftUI
import XCTest

/// 表面解析：玻璃开关、系统能力与辅助功能设置的归一结果。
final class PanelSurfaceTests: XCTestCase {
    func testAccessibilitySettingsAlwaysWinOverTheSwitch() {
        for enabled in [false, true] {
            for available in [false, true] {
                XCTAssertEqual(PanelSurfaceStyle.resolve(glassEnabled: enabled, glassAvailable: available,
                                                         reduceTransparency: true, increasedContrast: false), .solid)
                XCTAssertEqual(PanelSurfaceStyle.resolve(glassEnabled: enabled, glassAvailable: available,
                                                         reduceTransparency: false, increasedContrast: true), .solid)
            }
        }
    }

    func testSwitchOffIsSolidOnEverySystem() {
        XCTAssertEqual(PanelSurfaceStyle.resolve(glassEnabled: false, glassAvailable: true,
                                                 reduceTransparency: false, increasedContrast: false), .solid)
        XCTAssertEqual(PanelSurfaceStyle.resolve(glassEnabled: false, glassAvailable: false,
                                                 reduceTransparency: false, increasedContrast: false), .solid)
    }

    func testSwitchOnUsesGlassOnlyWhereTheSystemHasIt() {
        XCTAssertEqual(PanelSurfaceStyle.resolve(glassEnabled: true, glassAvailable: true,
                                                 reduceTransparency: false, increasedContrast: false), .glass)
        // macOS 13–25：开关打开也只是毛玻璃，不能因为解析不出玻璃而掉成纯色块。
        XCTAssertEqual(PanelSurfaceStyle.resolve(glassEnabled: true, glassAvailable: false,
                                                 reduceTransparency: false, increasedContrast: false), .legacyBlur)
    }

    /// 默认开启：悬浮面板自 macOS 26 起一直使用系统玻璃，开关不能让既有用户的默认外观发生回退。
    func testGlassSwitchDefaultsOnAndPersists() throws {
        let suite = "com.notchdeck.surface.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SettingsStore(defaults: defaults).liquidGlass)
        let settings = SettingsStore(defaults: defaults)
        settings.liquidGlass = false
        XCTAssertFalse(SettingsStore(defaults: defaults).liquidGlass)
    }
}
