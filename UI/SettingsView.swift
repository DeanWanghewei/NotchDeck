import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置面板：按功能分区（模块 / 进程监控 / 自定义 / 通用），顶部标签切换
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isRecordingHotKey = false
    @State private var activeSheet: ActiveSheet?
    @State private var selectedTab: SettingsTab = SettingsView.initialTab

    private enum ActiveSheet: Identifiable {
        case addItem
        case appPicker
        var id: Int { hashValue }
    }

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case modules = "模块"
        case process = "进程监控"
        case custom = "自定义"
        case general = "通用"
        var id: String { rawValue }
    }

    /// UI 调试用：-NotchDeckSettingsTab <模块|进程监控|自定义|通用>
    private static var initialTab: SettingsTab {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-NotchDeckSettingsTab"),
           arguments.indices.contains(index + 1),
           let tab = SettingsTab.allCases.first(where: { $0.rawValue == arguments[index + 1] }) {
            return tab
        }
        return .modules
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分区", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Form {
                switch selectedTab {
                case .modules: moduleSections
                case .process: processSection
                case .custom: customSection
                case .general: generalSections
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 460)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addItem:
                CustomItemEditView()
            case .appPicker:
                AppPickerSheet()
            }
        }
    }

    // MARK: - 模块页

    @ViewBuilder
    private var moduleSections: some View {
        Section("媒体源") {
            Toggle(isOn: $settings.experimentalNowPlaying) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实验性：读取系统正在播放")
                    Text("支持任意播放器（飞牛影视 / IINA / 浏览器等），无需逐个添加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.experimentalNowPlaying) { _ in
                AppModel.shared.media.requestRefresh()
            }

            // 系统兼容性信息
            LabeledContent("当前系统") {
                Text(SystemCompat.currentDescription)
                    .monospacedDigit()
            }
            LabeledContent("适配状态") {
                switch SystemCompat.adaptation {
                case .verified:
                    Label("已实测适配", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .untested:
                    Label("机制可用，此版本未经实测", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                case .unsupported:
                    Label("机制不可用（需 macOS 15.4+）", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("运行状态") {
                let media = AppModel.shared.media
                if !settings.experimentalNowPlaying {
                    Text("未开启").foregroundStyle(.secondary)
                } else if media.experimentalAvailable {
                    Label("运行正常", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("失败中，每 60 秒自动重试", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("支持范围") {
                Text("macOS 15.4+（更早版本自动回退手动媒体源）")
                    .foregroundStyle(.secondary)
            }

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
                if settings.experimentalNowPlaying {
                    Text("实验性说明：经由系统 Perl 加载只读适配器读取系统「正在播放」汇总（机制依赖 macOS 15.4+ 的 com.apple.perl 授权路径），随系统更新可能失效；失效时自动回退到上方手动媒体源。开启后优先于手动源。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

        Section {
            ForEach(AppModel.shared.registry.boxes) { box in
                ModuleConfigRow(box: box)
            }
        } header: {
            HStack(spacing: 4) {
                Text("模块管理")
                Button {
                    // 说明图标：无操作，仅悬停显示帮助
                } label: {
                    Image(systemName: "question.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("常驻：固定显示在面板顶部，呼出即见。\n切换：收进面板下方标签页，点图标切换。\n关闭：不出现在面板，并停止后台采集。")
            }
        } footer: {
            Text("常驻 = 固定在面板顶部；切换 = 收进下方标签页。关闭后停止后台采集。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 进程监控页

    @ViewBuilder
    private var processSection: some View {
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

        Section("系统监控显示") {
            Toggle("CPU 近 15 分钟热力图", isOn: $settings.showCPUHeatmap)
            Toggle("交换内存（swap）", isOn: $settings.showSwap)
            Toggle("电池（电量 / 容量 / 循环次数）", isOn: $settings.showBattery)
            HStack {
                Toggle("风扇转速", isOn: .constant(false))
                    .disabled(true)
                Text("此系统不提供")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Toggle("GPU 使用率", isOn: .constant(false))
                    .disabled(true)
                Text("此系统不提供")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("GPU 与风扇需要系统提供的统计接口，当前 macOS 版本已移除，相关选项暂不可用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 自定义页

    private var customSection: some View {
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
    }

    // MARK: - 通用页

    @ViewBuilder
    private var generalSections: some View {
        Section("面板") {
            Toggle(isOn: $settings.notchAttached) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("与刘海接壤（视觉一体）")
                    Text("凸字形颈部与刘海同宽，向上延伸与刘海融合，不遮挡菜单栏图标；关闭则悬浮于菜单栏下方")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        Slider(value: $settings.collapseDelay, in: 0.3...2.0, step: 0.1)
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
