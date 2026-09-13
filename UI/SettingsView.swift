import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置面板：媒体源、应用快捷控制、模块管理、自定义子项、触发行为、快捷键、通用
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isRecordingHotKey = false
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case addItem
        case appPicker
        var id: Int { hashValue }
    }

    var body: some View {
        Form {
            Section("媒体源") {
                let installed = MediaModule.installedSources
                if installed.isEmpty {
                    Text("未检测到受支持的媒体 App（Music / Spotify）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installed, id: \.bundleID) { source in
                        Toggle(isOn: mediaSourceBinding(source)) {
                            HStack(spacing: 6) {
                                Label(source.displayName, systemImage: source.symbol)
                                AdaptedBadge()
                            }
                        }
                    }
                    let notInstalled = MediaModule.knownSources.filter { source in
                        !installed.contains(where: { $0.bundleID == source.bundleID })
                    }
                    if !notInstalled.isEmpty {
                        Text("未安装：" + notInstalled.map(\.displayName).joined(separator: "、"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("默认不申请任何权限。开启媒体源后，该 App 运行时首次读取会请求自动化授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("应用快捷控制") {
                if settings.panelApps.isEmpty {
                    Text("从已安装应用中挑选常用 App 添加到面板，一键启动 / 退出、查看运行状态。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.panelApps) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(app.name)
                            if AdaptedApps.isAdapted(app.bundleID) {
                                AdaptedBadge()
                            }
                            Spacer()
                            Button {
                                settings.panelApps.removeAll { $0.id == app.id }
                          } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(ScalingButtonStyle())
                            .foregroundStyle(.secondary)
                            .help("从面板移除")
                        }
                    }
                }
                Button("添加应用…") {
                    activeSheet = .appPicker
                }
            }

            Section("模块管理") {
                ForEach(AppModel.shared.registry.boxes) { box in
                    ModuleConfigRow(box: box)
                }
                Text("「常驻」固定显示在面板顶部；「切换」显示在下方标签页。关闭后停止后台采集与命令执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("进程监控") {
                Picker("展示方式", selection: $settings.processDisplay) {
                    Text("块状").tag("grid")
                    Text("列表").tag("list")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
                Toggle("显示 App 进程占用的端口", isOn: $settings.showAppProcesses)
                Toggle("显示脚本进程占用的端口（node / python / java 等）", isOn: $settings.showScriptProcesses)
                Text("列出当前用户所有监听 TCP 端口的进程（系统守护进程除外），可一键结束（SIGTERM）。")
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
                    activeSheet = .addItem
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
        .frame(width: 460, height: 760)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addItem:
                CustomItemEditView()
            case .appPicker:
                AppPickerSheet()
            }
        }
    }
    // MARK: - 媒体源绑定

    /// 启用即触发一次读取：授权弹窗在用户主动开启的时刻出现，语境清晰
    private func mediaSourceBinding(_ source: MediaModule.MediaSource) -> Binding<Bool> {
        Binding(
            get: { settings.mediaSources.contains(source.bundleID) },
            set: { enabled in
                if enabled {
                    settings.mediaSources.append(source.bundleID)
                } else {
                    settings.mediaSources.removeAll { $0 == source.bundleID }
                }
            })
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
                .labelsHidden()
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
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if let error = hotKeys.registrationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { if isRecording { stopRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { stopRecording() }
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
                return nil
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

            settings.updateHotKey(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
            DispatchQueue.main.async { self.stopRecording() }
            return nil
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
