import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 基础页面与组件设置分离，组件数量增加时无需扩展宿主枚举或分支。
enum SettingsPage: Hashable {
    case modules
    case marketplace
    case module(String)
    case general
    case about

    static func resolve(_ requested: String?, boxes: [ModuleBox]) -> SettingsPage {
        switch requested {
        case "通用", "general": return .general
        case "关于", "about": return .about
        case "插件市场", "marketplace": return .marketplace
        default:
            if let box = boxes.first(where: {
                $0.makeSettings != nil && ($0.id == requested || $0.title == requested)
            }) { return .module(box.id) }
            return .modules
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var app: AppModel
    @ObservedObject private var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isRecordingHotKey = false
    @State private var selectedPage: SettingsPage?

    init(app: AppModel = .shared, page: SettingsPage? = nil) {
        self.app = app
        self.settings = app.settings
        let arguments = ProcessInfo.processInfo.arguments
        var requested: String?
        if let index = arguments.firstIndex(of: "-NotchDeckSettingsTab"), arguments.indices.contains(index + 1) {
            requested = arguments[index + 1]
        }
        _selectedPage = State(initialValue: page ?? SettingsPage.resolve(requested, boxes: app.registry.boxes))
    }

    private var settingsModules: [ModuleBox] { app.orderedBoxes.filter { $0.makeSettings != nil } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
            .id(selectedPage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 560, idealHeight: 700)
        .onChange(of: app.registry.boxes.map(\.id)) { ids in
            if let page = selectedPage, case .module(let id) = page, !ids.contains(id) {
                selectedPage = .modules
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                navigationButton("模块管理", symbol: "square.grid.2x2", page: .modules)
                navigationButton("插件市场", symbol: "shippingbox", page: .marketplace)
                navigationButton("通用", symbol: "gearshape", page: .general)
                navigationButton("关于", symbol: "info.circle", page: .about)
                Text("组件设置").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 16)
                ForEach(settingsModules) { box in
                    navigationButton(box.title, symbol: box.systemImage, page: .module(box.id))
                }
            }
            .padding(10)
            .padding(.top, 8)
        }
        .frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func navigationButton(_ title: String, symbol: String, page: SettingsPage) -> some View {
        let selected = selectedPage == page
        return Button { selectedPage = page } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var detail: some View {
        if selectedPage == .marketplace {
            PluginMarketplaceView(marketplace: app.marketplace, settings: settings) { id in
                selectedPage = .module(id)
            }
        } else {
            Form {
                switch selectedPage ?? .modules {
                case .modules: moduleSections
                case .module(let id):
                    if let box = settingsModules.first(where: { $0.id == id }), let makeSettings = box.makeSettings {
                        ModulePresentationSettingsView(box: box, settings: settings)
                        makeSettings()
                    }
                case .general: generalSections
                case .about: aboutSections
                case .marketplace: EmptyView()
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var moduleSections: some View {
        Section {
            ForEach(app.orderedBoxes) { box in
                ModuleConfigRow(box: box, settings: settings, registryBoxes: app.registry.boxes)
            }
        } header: {
            Text("模块管理")
        } footer: {
            Text("位置与样式由组件声明，可在支持的选项中调整。顶部常驻、标签页、底部常驻依次排列，内容统一滚动；上下箭头调整各区域内的顺序。关闭后停止采集。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Button { selectedPage = .marketplace } label: {
                Label("前往插件市场添加更多内容", systemImage: "shippingbox")
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
            HotKeyRecorderView(isRecording: $isRecordingHotKey, settings: settings)
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

}

// MARK: - 模块配置行

private struct ModuleConfigRow: View {
    @ObservedObject var box: ModuleBox
    @ObservedObject var settings: SettingsStore
    let registryBoxes: [ModuleBox]

    private var registryIDs: [String] { registryBoxes.map(\.id) }
    private var regionIDs: [String] {
        let placement = box.descriptor.presentationContext(for: settings.config(for: box.id, default: box.descriptor.defaultConfig)).placement
        return registryBoxes.filter { candidate in
            candidate.descriptor.presentationContext(for: settings.config(for: candidate.id, default: candidate.descriptor.defaultConfig)).placement == placement
        }.map(\.id)
    }

    private var enabled: Bool {
        settings.config(for: box.id, default: box.descriptor.defaultConfig).enabled
    }

    private var unavailableHint: String { box.unavailableReason() ?? "暂不可用" }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { value in
                    settings.updateConfig(for: box.id, default: box.descriptor.defaultConfig) { $0.enabled = value }
                })) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(box.title, systemImage: box.systemImage)
                    Text(box.descriptor.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !box.isAvailable() {
                Text(unavailableHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("查看此组件的设置与可用条件")
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    ModulePlacementPicker(box: box, settings: settings)
                        .help("设置组件在展开信息岛内的区域")
                    if box.descriptor.presentation.displayModes.count > 1 {
                        ModuleDisplayModePicker(box: box, settings: settings)
                            .help("使用组件提供的数据展示方式")
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 112)
                .disabled(!enabled)
            }
            reorderControls
        }
    }

    /// 跨区域交换不改变视觉顺序，因此按钮只移动同一区域的组件。
    private var reorderControls: some View {
        let index = settings.effectiveModuleOrder(registryIDs: regionIDs)
            .firstIndex(of: box.id)
        return VStack(spacing: 1) {
            reorderButton("chevron.up", offset: -1, disabled: (index ?? 0) <= 0, help: "上移")
            reorderButton("chevron.down", offset: 1,
                          disabled: index.map { $0 >= regionIDs.count - 1 } ?? true, help: "下移")
        }
    }

    private func reorderButton(_ symbol: String, offset: Int, disabled: Bool, help: String) -> some View {
        Button {
            settings.moveModule(box.id, offset: offset,
                                registryIDs: registryIDs, within: regionIDs)
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

// MARK: - 快捷键录制

private struct HotKeyRecorderView: View {
    @Binding var isRecording: Bool
    @ObservedObject var settings: SettingsStore
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
