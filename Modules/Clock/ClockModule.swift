import Combine
import Foundation
import SwiftUI

struct ClockPreferences: Codable, Equatable {
    var showSeconds = true
    var showTimeZone = true
}

/// 使用系统本地时间，无权限、无外部数据源；默认关闭以保留已有面板布局。
final class ClockModule: ObservableObject, NotchModule {
    static let descriptor = ModuleDescriptor(id: "clock", title: "时钟", systemImage: "clock",
        summary: "本地时间、日期与时区，无需权限", defaultConfig: ModuleConfig(enabled: false, pinned: false))

    @Published private(set) var date = Date()
    let preferences: ModulePreferences<ClockPreferences>
    private var timer: Timer?

    init(settings: SettingsStore = .shared) {
        preferences = settings.modulePreferences(for: Self.descriptor.id, default: ClockPreferences())
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        date = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.date = Date() }
        timer?.tolerance = 0.1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func panelDidExpand() { date = Date() }
    func content() -> some View { ClockView(module: self, preferences: preferences) }
    func settingsContent() -> some View { ClockModuleSettingsView(preferences: preferences) }
}
