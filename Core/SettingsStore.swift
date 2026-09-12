import Carbon.HIToolbox
import Combine
import Foundation

/// UserDefaults 封装的设置存储（需求 2.5）
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let hotKeyDidChange = Notification.Name("NotchDeckHotKeyDidChange")

    @Published var hoverEnabled: Bool {
        didSet { defaults.set(hoverEnabled, forKey: Keys.hoverEnabled) }
    }
    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) }
    }
    @Published var collapseEnabled: Bool {
        didSet { defaults.set(collapseEnabled, forKey: Keys.collapseEnabled) }
    }
    @Published var collapseDelay: Double {
        didSet { defaults.set(collapseDelay, forKey: Keys.collapseDelay) }
    }
    @Published var hotKeyCode: UInt32 {
        didSet {
            defaults.set(Int(hotKeyCode), forKey: Keys.hotKeyCode)
            NotificationCenter.default.post(name: Self.hotKeyDidChange, object: nil)
        }
    }
    @Published var hotKeyModifiers: UInt32 {
        didSet {
            defaults.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers)
            NotificationCenter.default.post(name: Self.hotKeyDidChange, object: nil)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hoverEnabled = "settings.hoverEnabled"
        static let hoverDelay = "settings.hoverDelay"
        static let collapseEnabled = "settings.collapseEnabled"
        static let collapseDelay = "settings.collapseDelay"
        static let hotKeyCode = "settings.hotKeyCode"
        static let hotKeyModifiers = "settings.hotKeyModifiers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverEnabled = defaults.object(forKey: Keys.hoverEnabled) as? Bool ?? true
        hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? 0.2
        collapseEnabled = defaults.object(forKey: Keys.collapseEnabled) as? Bool ?? true
        collapseDelay = defaults.object(forKey: Keys.collapseDelay) as? Double ?? 1.0

        let storedKeyCode = defaults.integer(forKey: Keys.hotKeyCode)
        hotKeyCode = storedKeyCode == 0 ? UInt32(kVK_ANSI_I) : UInt32(storedKeyCode)
        let storedModifiers = defaults.integer(forKey: Keys.hotKeyModifiers)
        hotKeyModifiers = storedModifiers == 0 ? UInt32(cmdKey | shiftKey) : UInt32(storedModifiers)
    }
}
