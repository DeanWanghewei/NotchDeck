import Carbon.HIToolbox
import Foundation

/// Carbon RegisterEventHotKey 全局快捷键（无需辅助功能/输入监控权限）
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// 回调载体：Carbon C 函数指针无法捕获上下文，经 userData 传递
    private final class Target {
        var action: (() -> Void)?
    }
    private let target = Target()

    func registerDefault() {
        let settings = SettingsStore.shared
        register(keyCode: settings.hotKeyCode, carbonModifiers: settings.hotKeyModifiers)
    }

    func register(keyCode: UInt32, carbonModifiers: UInt32) {
        unregister()
        installEventHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("NDEK"), id: 1)
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }
    }

    /// 录制新快捷键期间临时注销，避免旧组合键抢先触发
    func suspend() {
        unregister()
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        target.action = { [weak self] in self?.onTrigger?() }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr, hotKeyID.id == 1 {
                let target = Unmanaged<Target>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { target.action?() }
            }
            return noErr
        }
        let userData = Unmanaged.passUnretained(target).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, userData, &eventHandler)
    }

    private static func fourCharCode(_ string: String) -> OSType {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }
}

// MARK: - 显示辅助

extension HotKeyManager {

    /// 组合键显示文本，如 "⌘⇧I"
    static func display(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        modifierSymbols(carbonModifiers: carbonModifiers) + keySymbol(keyCode: keyCode)
    }

    static func modifierSymbols(carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    /// 键码 → 当前键盘布局下的字符（UCKeyTranslate）
    static func keySymbol(keyCode: UInt32) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(keyCode)" }
        let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout,
                                    UInt16(keyCode),
                                    UInt16(kUCKeyActionDisplay),
                                    0,
                                    UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState,
                                    characters.count,
                                    &length,
                                    &characters)
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
