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
        case about = "关于"
        var id: String { rawValue }
    }

    /// UI 调试用：-NotchDeckSettingsTab <模块|进程监控|自定义|通用|关于>
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
                case .custom:
                    customSection
                    presetSection
                case .general: generalSections
                case .about: aboutSections
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
            ForEach(AppModel.shared.orderedBoxes) { box in
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
                .help("常驻：固定显示在面板顶部，呼出即见。\n切换：收进面板下方标签页，点图标切换。\n关闭：不出现在面板，并停止后台采集。\n排序：用行尾的上下箭头调整模块在面板中的前后顺序。")
            }
        } footer: {
            Text("常驻 = 固定在面板顶部；切换 = 收进下方标签页。关闭后停止后台采集。行尾上下箭头调整模块顺序，常驻区与标签页同步生效。")
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
            Toggle("CPU 近 15 分钟走势图", isOn: $settings.showCPUHeatmap)
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
                Text("添加 shell 命令小部件：文本显示执行结果，或热力图按数字大小着色。可从下方示例模板一键添加。")
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
            Picker("热力图保留时长", selection: $settings.heatmapRetentionHours) {
                ForEach([1.0, 2.0, 4.0, 8.0, 12.0, 24.0], id: \.self) { hours in
                    Text("\(Int(hours)) 小时").tag(hours)
                }
            }
            .help("热力图子项只保留最近该时长的探测样本（每 30 秒一次），更早的自动清除；面板中单行显示，样本过多时相邻样本自动合并")
        }
    }

    /// 示例模板：命令写法的内置引导，点击「添加」即创建子项
    private var presetSection: some View {
        Section {
            ForEach(CustomItemPresets.all) { preset in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(preset.name)
                                .font(.callout)
                            DisplayStyleBadge(display: preset.display)
                        }
                        Text(preset.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(preset.note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("添加") {
                        settings.customItems.append(preset.item)
                    }
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("示例模板")
        } footer: {
            Text("热力图：命令输出数字（空格 / 逗号 / 换行分隔）按大小着色；退出码非 0 或超时显示为红色；每 30 秒后台探测。完整写法见仓库 docs/custom-items.md")
        }
    }

    // MARK: - 通用页

    @ViewBuilder
    private var generalSections: some View {
        Section("面板") {
            Toggle(isOn: $settings.notchAttached) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("与刘海接壤（视觉一体）")
                    Text("颈部按屏幕安全区与刘海对齐；无刘海屏自动使用悬浮样式。关闭则悬浮于菜单栏下方")
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
    // MARK: - 关于页

    @ViewBuilder
    private var aboutSections: some View {
        Section {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("NotchDeck")
                    .font(.title2.weight(.semibold))
                Text("版本 \(Self.marketingVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            Text("把 MacBook Pro 的刘海变成随手可用的信息控制台。悬停刘海展开悬浮信息岛，媒体控制、系统监控、进程管理、音量、应用快捷启动与自定义命令小部件按模块自由组合（常驻 + 标签页双层布局）。默认最小权限：不申请任何权限即完整可用，媒体源按需添加、按需授权，所有数据仅本地处理，不上传任何信息。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section("开源") {
            LabeledContent("项目地址") {
                Link("github.com/DeanWanghewei/NotchDeck",
                     destination: URL(string: "https://github.com/DeanWanghewei/NotchDeck")!)
            }
            LabeledContent("开源协议") {
                Text("MIT License")
            }
            Text("本项目以 MIT 协议开源，完整协议文本见仓库根目录的 LICENSE 文件。内置的实验性「系统正在播放」功能使用了第三方开源组件 MediaRemoteAdapter（BSD 3-Clause License，© Jonas van den Berg and contributors）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("问题反馈") {
                Link("提交 Issue", destination: URL(string: "https://github.com/DeanWanghewei/NotchDeck/issues")!)
            }
        }
    }

    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
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

    /// 模块不可用时的具体原因（按模块给出该添加什么）
    private var unavailableHint: String {
        switch box.id {
        case "apps": return "未添加应用"
        case "custom": return "未添加子项"
        default: return "未添加内容"
        }
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
                Text(unavailableHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("在设置对应区块添加内容后，此模块即可用")
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
            reorderControls
        }
    }

    /// 上/下移动一位；面板常驻区与标签页按此顺序显示
    private var reorderControls: some View {
        let registryIDs = AppModel.shared.registry.boxes.map(\.id)
        let index = settings.effectiveModuleOrder(registryIDs: registryIDs)
            .firstIndex(of: box.id)
        return VStack(spacing: 1) {
            reorderButton("chevron.up", offset: -1, disabled: (index ?? 0) <= 0, help: "上移")
            reorderButton("chevron.down", offset: 1,
                          disabled: index.map { $0 >= registryIDs.count - 1 } ?? true, help: "下移")
        }
    }

    private func reorderButton(_ symbol: String, offset: Int, disabled: Bool, help: String) -> some View {
        Button {
            settings.moveModule(box.id, offset: offset,
                                registryIDs: AppModel.shared.registry.boxes.map(\.id))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 18, height: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .secondary)
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - 展示方式徽章

/// 子项 / 模板行的展示方式标记：热力图 = 绿色，文本 = 灰色
private struct DisplayStyleBadge: View {
    let display: CustomItem.Display

    var body: some View {
        let heatmap = display == .heatmap
        Text(heatmap ? "热力图" : "文本")
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill((heatmap ? Color.green : Color.secondary).opacity(0.15)))
            .foregroundStyle(heatmap ? .green : .secondary)
            .help(heatmap ? "命令输出的数字按大小着色显示" : "命令输出原样显示")
    }
}

// MARK: - 自定义子项行

private struct CustomItemRow: View {
    let item: CustomItem
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.callout)
                    DisplayStyleBadge(display: item.display)
                }
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

/// 命令用多行编辑器：长命令自动换行完整可见，可直接粘贴多行脚本（整串交给 zsh -lc 执行）
struct CustomItemEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @State private var name = ""
    @State private var command = ""
    @State private var display: CustomItem.Display = .text

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
                Text("展示方式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("展示方式", selection: $display) {
                    Text("文本").tag(CustomItem.Display.text)
                    Text("热力图").tag(CustomItem.Display.heatmap)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(displayHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(commandCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                commandEditor
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else { return }
                    settings.customItems.append(
                        CustomItem(name: trimmedName, command: trimmedCommand, display: display))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    /// 多行命令编辑器：占位提示在空内容时显示，长内容滚动查看
    private var commandEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $command)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150)
                .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            if command.isEmpty {
                Text(commandPlaceholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(EdgeInsets(top: 12, leading: 10, bottom: 0, trailing: 10))
                    .allowsHitTesting(false)
            }
        }
    }

    private var displayHint: String {
        switch display {
        case .text:
            return "命令的执行结果原样显示在面板中。"
        case .heatmap:
            return "命令输出一个或多个数字（空格 / 逗号 / 换行分隔），按数值大小着色成方格图；单个数字会随刷新累积为趋势，且每 30 秒后台探测一次。命令非 0 退出或超时记为一次失败，显示为红色方格——适合探测网络地址。"
        }
    }

    private var commandCaption: String {
        display == .heatmap
            ? "命令（zsh 执行，超时 6 秒，输出数字；支持多行脚本）"
            : "命令（zsh 执行，超时 6 秒；支持多行脚本）"
    }

    private var commandPlaceholder: String {
        display == .heatmap
            ? "如：curl -sfo /dev/null -w '%{time_total}' --max-time 5 http://boom-fn:5666/\n\n也支持多行脚本：\nfor i in 1 2 3; do\n  echo $i\ndone"
            : "如：ipconfig getifaddr en0\n\n也支持多行脚本（整串交给 zsh 执行）"
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
