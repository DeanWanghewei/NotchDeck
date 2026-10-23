import SwiftUI

struct SubscriptionQuotaView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @Environment(\.modulePresentation) private var presentation

    private var compact: Bool { presentation.displayModeID == "compact" }
    private var rings: Bool { presentation.displayModeID == "rings" }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack {
                Label("订阅额度", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                if preferences.value.demoMode {
                    Text("演示数据").font(.caption2).foregroundStyle(Color.accentColor)
                } else {
                    Button { module.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("刷新所有账号的订阅额度")
                        .disabled(!module.refreshing.isEmpty)
                }
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("管理订阅账号")
            }
            if preferences.value.demoMode && !compact {
                Text("以下为多账号演示。在组件设置中添加账号并关闭演示模式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if module.displayedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂无启用的订阅账号").font(.caption).foregroundStyle(.secondary)
                    Button("添加 GLM / Codex 账号") { openSettings() }.controlSize(.small)
                }.padding(.vertical, 8)
            }
            ForEach(module.displayedAccounts) { account in accountCard(account) }
            Text(compact ? "悬停用量行查看重置时间，读数以官方用量页为准。" : "已用百分比 · 额度与重置时间以官方用量页为准。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func accountCard(_ account: SubscriptionAccount) -> some View {
        let snapshot = module.snapshots[account.id]
        let error = module.errors[account.id]
        return VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName(in: module.displayedAccounts))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .help(account.displayName(in: module.displayedAccounts))
                    Text([account.provider.title, compact ? nil : snapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if module.refreshing.contains(account.id) { ProgressView().controlSize(.mini) }
                Link(destination: account.provider.usageURL) { Image(systemName: "arrow.up.right.square") }
                    .help("打开官方用量页，网页账号可能与此处保存的账号不同")
            }
            if let snapshot {
                if rings {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(2, max(1, snapshot.windows.count))), spacing: 12) {
                        ForEach(snapshot.windows) { window in ring(window) }
                    }
                } else {
                    ForEach(snapshot.windows) { window in quotaRow(window) }
                }
                if !preferences.value.demoMode {
                    HStack(spacing: 3) {
                        Text(error == nil ? "更新于" : "保留上次数据 ·")
                        Text(snapshot.fetchedAt, style: .time)
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            } else if error == nil {
                Text(module.refreshing.contains(account.id) ? "正在查询…" : "等待查询")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error.message(for: account.provider)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 8 : 12)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 12).fill(Color.primary.opacity(compact ? 0.025 : 0.05)))
    }

    private func quotaRow(_ window: SubscriptionQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(window.title).font(.caption).frame(width: 64, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(HeatScale.color(window.fraction))
                            .frame(width: proxy.size.width * window.fraction)
                    }
                }.frame(height: compact ? 5 : 8)
                Text(String(format: "已用 %.0f%%", window.usedPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(window.fraction >= 0.7 ? HeatScale.color(window.fraction) : .secondary)
                    .frame(width: 72, alignment: .trailing)
            }
            HStack {
                if !compact { Text(resetDescription(window)) }
                Spacer(minLength: 4)
                Text("剩余 \(window.remainingPercent, specifier: "%.0f")%").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .help(resetDescription(window))
    }

    private func ring(_ window: SubscriptionQuotaWindow) -> some View {
        VStack(spacing: 6) {
            Text(window.title).font(.caption).lineLimit(1)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
                if window.fraction > 0 {
                    Circle().trim(from: 0, to: window.fraction)
                        .stroke(HeatScale.color(window.fraction), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 1) {
                    Text("\(window.usedPercent, specifier: "%.0f")%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(window.fraction >= 0.7 ? HeatScale.color(window.fraction) : .secondary)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("已用").font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(8)
            }.frame(width: 76, height: 76).padding(4)
            Text("剩余 \(window.remainingPercent, specifier: "%.0f")%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(resetDescription(window)).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .help(resetDescription(window))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title)，已用 \(window.usedPercent, specifier: "%.0f")%，剩余 \(window.remainingPercent, specifier: "%.0f")%，\(resetDescription(window))")
    }

    private func openSettings() {
        NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: module.id)
    }

    private func resetDescription(_ window: SubscriptionQuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "重置时间见官方用量页" }
        return reset <= Date() ? "周期已到，等待刷新" : "重置 \(reset.formatted(.dateTime.month().day().hour().minute()))"
    }
}
