import SwiftUI

struct ModulePresentationSettingsView: View {
    let box: ModuleBox
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Section("布局与展示") {
            ModulePlacementPicker(box: box, settings: settings)
            if box.descriptor.presentation.displayModes.count > 1 {
                ModuleDisplayModePicker(box: box, settings: settings)
            }
            Text("顶部常驻 → 标签页 → 底部常驻，均位于展开的信息岛内。各区域内的顺序在模块管理中调整。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ModulePlacementPicker: View {
    let box: ModuleBox
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Picker("摆放位置", selection: Binding(
            get: { box.descriptor.presentationContext(for: settings.config(for: box.id, default: box.descriptor.defaultConfig)).placement },
            set: { value in settings.updateConfig(for: box.id, default: box.descriptor.defaultConfig) { $0.placement = value } }
        )) {
            ForEach(box.descriptor.presentation.placements) { placement in
                Text(placement.title).tag(placement)
            }
        }
    }
}

struct ModuleDisplayModePicker: View {
    let box: ModuleBox
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Picker("展示样式", selection: Binding(
            get: { box.descriptor.presentationContext(for: settings.config(for: box.id, default: box.descriptor.defaultConfig)).displayModeID },
            set: { value in settings.updateConfig(for: box.id, default: box.descriptor.defaultConfig) { $0.displayModeID = value } }
        )) {
            ForEach(box.descriptor.presentation.displayModes) { mode in
                Text(mode.title).tag(mode.id)
            }
        }
    }
}
