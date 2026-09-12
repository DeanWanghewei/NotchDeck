import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置面板（需求 2.5）：触发行为、快捷键、开机自启动
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isRecordingHotKey = false

    var body: some View {
        Form {
            Section("触发") {
                Toggle("悬停刘海自动展开", isOn: $settings.hoverEnabled)
                if settings.hoverEnabled {
                    LabeledContent("悬停延迟") {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0.1...0.5, step: 0.05)
                            Text(String(format: "%.2f 秒", settings.hoverDelay))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Toggle("鼠标离开自动收起", isOn: $settings.collapseEnabled)
                if settings.collapseEnabled {
                    LabeledContent("离开延迟") {
                        HStack {
                            Slider(value: $settings.collapseDelay, in: 0.5...2.0, step: 0.1)
                            Text(String(format: "%.1f 秒", settings.collapseDelay))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }

            Section("快捷键") {
                HotKeyRecorderView(isRecording: $isRecordingHotKey)
            }

            Section("通用") {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("NotchDeck 登录项设置失败: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("NotchDeck 不收集任何数据，所有监控数据仅本地处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 480)
    }
}

/// 快捷键录制：点击后按下新的组合键，Esc 取消
private struct HotKeyRecorderView: View {
    @Binding var isRecording: Bool
    @ObservedObject private var settings = SettingsStore.shared
    @State private var eventMonitor: Any?

    var body: some View {
        LabeledContent("全局快捷键") {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "按下新的组合键（Esc 取消）…" : currentDisplay)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 150)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var currentDisplay: String {
        HotKeyManager.display(keyCode: settings.hotKeyCode,
                              carbonModifiers: settings.hotKeyModifiers)
    }

    private func startRecording() {
        isRecording = true
        HotKeyManager.shared.suspend()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { self.stopRecording() }
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 至少包含 ⌘/⌥/⌃ 之一，避免注册裸键
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return event
            }
            var carbonModifiers: UInt32 = 0
            if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
            if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

            settings.hotKeyCode = UInt32(event.keyCode)
            settings.hotKeyModifiers = carbonModifiers
            DispatchQueue.main.async { self.stopRecording() }
            return event
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        isRecording = false
        HotKeyManager.shared.registerDefault()
    }
}
