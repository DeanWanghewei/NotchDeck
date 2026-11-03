import SwiftUI

struct SubscriptionQuotaView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @Environment(\.modulePresentation) private var presentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

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
                    Button("添加 GLM / Codex / MiniMax 账号") { openSettings() }.controlSize(.small)
                }.padding(.vertical, 8)
            }
            if rings {
                ForEach(Self.accountRows(module.displayedAccounts), id: \.first!.id) { row in
                    if row.count == 2 {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(row) { account in
                                    accountCard(account, tile: true).frame(minWidth: 210, maxWidth: .infinity)
                                }
                            }
                            VStack(spacing: 6) {
                                ForEach(row) { account in accountCard(account) }
                            }
                        }
                    } else if let account = row.first {
                        accountCard(account)
                    }
                }
            } else {
                ForEach(module.displayedAccounts) { account in accountCard(account) }
            }
            Text("图形与数字均为已用")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .opacity(reduceMotion || appeared ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appeared)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: module.displayedAccounts.map(\.id))
        .onAppear { appeared = true }
    }

    /// 同服务账号按原顺序两两配对，服务组按首次出现顺序排列。
    static func accountRows(_ accounts: [SubscriptionAccount]) -> [[SubscriptionAccount]] {
        var providers: [SubscriptionProvider] = []
        for account in accounts where !providers.contains(account.provider) { providers.append(account.provider) }
        return providers.flatMap { provider in
            let group = accounts.filter { $0.provider == provider }
            return stride(from: 0, to: group.count, by: 2).map { Array(group[$0..<min($0 + 2, group.count)]) }
        }
    }

    private func accountCard(_ account: SubscriptionAccount, tile: Bool = false) -> some View {
        let snapshot = module.snapshots[account.id]
        let error = module.errors[account.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(account.displayName(in: module.displayedAccounts))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .help(account.displayName(in: module.displayedAccounts))
                Text(account.provider.badge)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help([account.provider.title, snapshot?.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                Spacer(minLength: 4)
                if let snapshot, !tile {
                    Text(snapshot.fetchedAt, style: .time)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(error == nil ? "最近更新时间" : "当前保留的是上次成功的数据")
                }
                if module.refreshing.contains(account.id) { ProgressView().controlSize(.mini) }

            }
            if let snapshot {
                if rings {
                    if account.provider == .glm {
                        glmConcentricRings(snapshot.windows, tile: tile)
                    } else if tile {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(snapshot.windows) { window in ring(window) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Codex 保留独立圆环，更多窗口横向滚动。
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: 8) {
                                ForEach(snapshot.windows) { window in ring(window) }
                            }.padding(.vertical, 3)
                        }
                    }
                } else {
                    ForEach(snapshot.windows) { window in quotaRow(window) }
                }

            } else if error == nil {
                Text(module.refreshing.contains(account.id) ? "正在查询…" : "等待查询")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tile, let snapshot {
                Text(snapshot.fetchedAt, style: .time)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(error == nil ? "最近更新时间" : "当前保留的是上次成功的数据")
            }
            if let error {
                Text(error.message(for: account.provider)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 6 : 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(compact ? 0.025 : 0.05)))
    }

    // 固定语义顺序，避免接口调换数组顺序后同一额度跳到另一层。
    static func orderedGLMWindows(_ windows: [SubscriptionQuotaWindow]) -> [SubscriptionQuotaWindow] {
        func rank(_ window: SubscriptionQuotaWindow) -> Int {
            if window.title.hasPrefix("5 小时") { return 0 }
            if window.title.hasPrefix("每周") { return 1 }
            if window.title.hasPrefix("工具调用") { return 2 }
            return 3
        }
        return windows.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    private func glmConcentricRings(_ windows: [SubscriptionQuotaWindow], tile: Bool) -> some View {
        let ordered = Self.orderedGLMWindows(windows)
        // 每组最多三层；服务新增额度时继续分组展示，不挤压内环或丢弃读数。
        return VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: ordered.count, by: 3)), id: \.self) { start in
                let group = Array(ordered[start..<min(start + 3, ordered.count)])
                let layout = tile ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
                layout {
                    ZStack {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, window in
                            let diameter = CGFloat(88 - index * 24)
                            ZStack {
                                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
                                if window.fraction > 0 {
                                    Circle().trim(from: 0, to: window.fraction)
                                        .stroke(HeatScale.color(window.fraction), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                }
                            }.frame(width: diameter, height: diameter)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: window.fraction)
                        }
                    }
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, window in
                            HStack(alignment: .top, spacing: 6) {
                                Text(group.count == 1 ? "环" : index == 0 ? "外" : index == group.count - 1 ? "内" : "中")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(window.title).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 4)
                                        Text("\(window.usedPercent, specifier: "%.0f")% · 余 \(window.remainingPercent, specifier: "%.0f")%")
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundStyle(window.fraction >= 0.7 ? HeatScale.color(window.fraction) : .secondary)
                                            .fixedSize()
                                    }
                                    resetText(window).font(.system(size: 9)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(window.title)，已用 \(window.usedPercent.formatted())%，剩余 \(window.remainingPercent.formatted())%，\(window.resetDescription())")
                        }
                    }
                }
            }
        }.padding(.vertical, 3)
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
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: window.fraction)
                Text("\(window.usedPercent, specifier: "%.0f")% · 余 \(window.remainingPercent, specifier: "%.0f")%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(window.fraction >= 0.7 ? HeatScale.color(window.fraction) : .secondary)
                    .frame(width: 104, alignment: .trailing)
            }
            resetText(window).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(window.title)，已用 \(window.usedPercent.formatted())%，剩余 \(window.remainingPercent.formatted())%，\(window.resetDescription())")
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
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: window.fraction)
            VStack(alignment: .leading, spacing: 3) {
                Text(window.title).font(.system(size: 10)).lineLimit(1)
                Text("余 \(window.remainingPercent, specifier: "%.0f")%")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                resetText(window)
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
            }
        }
        .help(window.resetHelpDescription())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title)，已用 \(window.usedPercent, specifier: "%.0f")%，剩余 \(window.remainingPercent, specifier: "%.0f")%，\(window.resetDescription())")
    }

    private func openSettings() {
        NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: module.id)
    }

    /// 重置行为纯文字“还剩 X · 绝对时刻 重置”：窗口时长各行不一（5 小时 / 每周），
    /// 时间进度条的刻度无法跨行统一，且暖色临近重置时会与用量条的“额度告警”语义冲突；
    /// 剩余时长随时间流逝本地刷新（分钟粒度），不触发新的额度查询。
    private func resetText(_ window: SubscriptionQuotaWindow) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(window.resetDescription(now: context.date))
        }
    }
}
