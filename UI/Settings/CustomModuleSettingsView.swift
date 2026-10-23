import SwiftUI

struct CustomModuleSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var showAddItem = false

    var body: some View {
        Group {
            customSection
            presetSection
        }
        .sheet(isPresented: $showAddItem) { CustomItemEditView(settings: settings) }
    }

    private var customSection: some View {
        Section("自定义子项") {
            if settings.customItems.isEmpty {
                Text("添加 shell 命令小部件：文本显示执行结果，或热力图按数字大小着色。可从下方示例模板一键添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.customItems) { item in
                    CustomItemRow(item: item, settings: settings)
                }
            }
            Button("添加子项…") {
                showAddItem = true
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
    @ObservedObject var settings: SettingsStore

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
    @ObservedObject var settings: SettingsStore
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
