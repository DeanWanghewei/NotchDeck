import SwiftUI

struct SubscriptionQuotaView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @Environment(\.modulePresentation) private var presentation

    private var compact: Bool { presentation.displayModeID == "compact" }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack {
                Label("订阅额度", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                if preferences.value.demoMode {
                    Text("演示数据").font(.caption2).foregroundStyle(Color.accentColor)
                } else {
                    Button { module.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("刷新订阅额度")
                        .disabled(!module.refreshing.isEmpty)
                }
                Button {
                    NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: module.id)
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("配置订阅额度")
            }
            if preferences.value.demoMode && !compact {
                Text("当前数字为示例。在组件设置中关闭演示模式并连接账号。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(SubscriptionProvider.allCases) { provider in
                providerCard(provider)
            }
            Text(compact ? "悬停用量行查看重置时间，读数以官方用量页为准。" : "额度与重置时间以官方用量页为准。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func providerCard(_ provider: SubscriptionProvider) -> some View {
        let snapshot = module.snapshots[provider]
        let error = module.errors[provider]
        return VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title).font(.system(size: 12, weight: .semibold))
                    if !compact, let plan = snapshot?.plan, !plan.isEmpty {
                        Text(plan.capitalized).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if module.refreshing.contains(provider) { ProgressView().controlSize(.mini) }
                Link(destination: provider.usageURL) {
                    Image(systemName: "arrow.up.right.square")
                }.help("打开官方用量页")
            }
            if let snapshot {
                ForEach(snapshot.windows) { window in quotaRow(window) }
                if !preferences.value.demoMode {
                    HStack(spacing: 3) {
                        Text(error == nil ? "更新于" : "保留上次数据 ·")
                        Text(snapshot.fetchedAt, style: .time)
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            } else if error == nil {
                Text(module.refreshing.contains(provider) ? "正在查询…" : "尚未连接，在组件设置中连接账号")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error.message(for: provider)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 8 : 12)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 12).fill(Color.primary.opacity(compact ? 0.025 : 0.05)))
    }

    private func quotaRow(_ window: SubscriptionQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(window.title).font(.caption).frame(width: 64, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(HeatScale.color(window.fraction))
                            .frame(width: proxy.size.width * window.fraction)
                    }
                }.frame(height: 5)
                Text(compact ? String(format: "已用 %.0f%% · 剩余 %.0f%%", window.usedPercent, window.remainingPercent) :
                        String(format: "已用 %.0f%%", window.usedPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(window.fraction >= 0.7 ? HeatScale.color(window.fraction) : .secondary)
                    .frame(width: compact ? 136 : 72, alignment: .trailing)
            }
            if !compact {
                HStack {
                    Text(resetDescription(window))
                    Spacer(minLength: 4)
                    Text("剩余 \(window.remainingPercent, specifier: "%.0f")%")
                        .monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .help(resetDescription(window))
    }

    private func resetDescription(_ window: SubscriptionQuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "重置时间见官方用量页" }
        return reset <= Date() ? "周期已到，等待刷新" : "重置 \(reset.formatted(.dateTime.month().day().hour().minute()))"
    }
}
