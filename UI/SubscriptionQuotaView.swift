import SwiftUI

struct SubscriptionQuotaView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @Environment(\.modulePresentation) private var presentation

    private var compact: Bool { presentation.displayModeID == "compact" }
    private var rings: Bool { presentation.displayModeID == "rings" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("订阅额度", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Button { module.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新所有账号的订阅额度")
                    .disabled(!module.refreshing.isEmpty)
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("管理订阅账号")
            }
            if module.displayedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂无启用的订阅账号").font(.caption).foregroundStyle(.secondary)
                    Button("添加 GLM / Codex 账号") { openSettings() }.controlSize(.small)
                }.padding(.vertical, 8)
            }
            ForEach(module.displayedAccounts) { account in accountCard(account) }
            Text("图形与数字均为已用")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func accountCard(_ account: SubscriptionAccount) -> some View {
        let snapshot = module.snapshots[account.id]
        let error = module.errors[account.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(account.displayName(in: module.displayedAccounts))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .help(account.displayName(in: module.displayedAccounts))
                Text(account.provider == .glm ? "GLM" : "Codex")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help([account.provider.title, snapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                Spacer(minLength: 4)
                if let snapshot {
                    Text(snapshot.fetchedAt, style: .time)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(error == nil ? "最近更新时间" : "当前保留的是上次成功的数据")
                }
                if module.refreshing.contains(account.id) { ProgressView().controlSize(.mini) }

            }
            if let snapshot {
                if rings {
                    // 单条横向轨道，更多窗口横向滚动，绝不因第三个额度撑出第二行。
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(snapshot.windows) { window in ring(window) }
                        }.padding(.vertical, 3)
                    }

                } else {
                    ForEach(snapshot.windows) { window in quotaRow(window) }
                }

            } else if error == nil {
                Text(module.refreshing.contains(account.id) ? "正在查询…" : "等待查询")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error.message(for: account.provider)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 6 : 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(compact ? 0.025 : 0.05)))
    }

    private func quotaRow(_ window: SubscriptionQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.title).font(.system(size: 10)).lineLimit(1)
                    .frame(width: 68, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(HeatScale.color(window.fraction))
                            .frame(width: proxy.size.width * window.fraction)
                    }
                }.frame(height: 5)
                Text("\(window.usedPercent, specifier: "%.0f")% · 余 \(window.remainingPercent, specifier: "%.0f")%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(window.fraction >= 0.7 ? HeatScale.color(window.fraction) : .secondary)
                    .frame(width: 104, alignment: .trailing)
            }
            Text(resetDescription(window)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(window.title)，已用 \(window.usedPercent.formatted())%，剩余 \(window.remainingPercent.formatted())%，\(resetDescription(window))")
    }

    private func ring(_ window: SubscriptionQuotaWindow) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                if window.fraction > 0 {
                    Circle().trim(from: 0, to: window.fraction)
                        .stroke(HeatScale.color(window.fraction), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(window.usedPercent, specifier: "%.0f")%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6).lineLimit(1).padding(3)
            }.frame(width: 40, height: 40).padding(2)
            VStack(alignment: .leading, spacing: 3) {
                Text(window.title).font(.system(size: 10)).lineLimit(1)
                Text("余 \(window.remainingPercent, specifier: "%.0f")%")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Text(resetDescription(window))
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
            }
        }
        .help(resetDescription(window))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title)，已用 \(window.usedPercent, specifier: "%.0f")%，剩余 \(window.remainingPercent, specifier: "%.0f")%，\(resetDescription(window))")
    }

    private func openSettings() {
        NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: module.id)
    }

    private func resetDescription(_ window: SubscriptionQuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "服务未提供重置时间" }
        return reset <= Date() ? "周期已到，等待刷新" : "重置 \(reset.formatted(.dateTime.month().day().hour().minute()))"
    }
}
