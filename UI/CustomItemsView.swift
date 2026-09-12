import SwiftUI

/// 自定义子项：执行用户定义的 shell 命令并展示输出
struct CustomItemsView: View {
    @ObservedObject var module: CustomItemsModule
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(settings.customItems) { item in
                itemCard(item)
            }
            HStack(spacing: 6) {
                if module.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("执行中…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    module.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("重新执行")
                Text("在设置中添加 / 编辑子项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func itemCard(_ item: CustomItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
            }
            Text(module.output(for: item) ?? "…")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(6)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
