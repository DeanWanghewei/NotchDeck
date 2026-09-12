import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置面板：模块管理、自定义子项、触发行为、快捷键、通用
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isRecordingHotKey = false
    @State private var isShowingAddItem = false

    var body: some View {
        Form {
            Section("模块管理") {
                ForEach(AppModel.shared.registry.boxes) { box in
                    ModuleConfigRow(box: box)
                }
                Text("「常驻」固定显示在面板顶部；「切换」显示在下方标签页。关闭后模块不出现在面板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("自定义子项") {
                if settings.customItems.isEmpty {
                    Text("添加 shell 命令小部件，执行结果直接显示在面板中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.customItems) { item in
                        CustomItemRow(item: item)
                    }
                }
                Button("添加子项…") {
                    isShowingAddItem = true
                }
            }

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
        .frame(width: 460, height: 700)
        .sheet(isPresented: $isShowingAddItem) {
            CustomItemEditView()
        }
    }
}

// MARK: - 模块配置行

private struct ModuleConfigRow: View {
    @ObservedObject var box: ModuleBox
    @ObservedObject private var settings = SettingsStore.shared

    private var enabled: Bool {
        settings.config(for: box.id).enabled
    }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { value in
                    settings.updateConfig(for: box.id) { $0.enabled = value }
                })) {
                Label(box.title, systemImage: box.systemImage)
            }
            Spacer()
            if !box.isAvailable() {
                Text("暂不可用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Picker("位置", selection: Binding(
                    get: { settings.config(for: box.id).pinned },
                    set: { value in
                        settings.updateConfig(for: box.id) { $0.pinned = value }
                    })) {
                    Text("常驻").tag(true)
                    Text("切换").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .disabled(!enabled)
            }
        }
    }
}

// MARK: - 自定义子项行

private struct CustomItemRow: View {
    let item: CustomItem
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                Text(item.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                settings.customItems.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除该子项")
        }
    }
}

// MARK: - 自定义子项编辑

private struct CustomItemEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义子项")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("如：本机 IP", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("命令（zsh 执行，超时 6 秒）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("如：ipconfig getifaddr en0", text: $command, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else { return }
                    settings.customItems.append(CustomItem(name: trimmedName, command: trimmedCommand))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380, height: 240)
    }
}

// MARK: - 快捷键录制

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
