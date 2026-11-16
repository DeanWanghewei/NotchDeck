import SwiftUI

struct PluginMarketplaceView: View {
    @ObservedObject var marketplace: PluginMarketplace
    @ObservedObject var settings: SettingsStore
    let openSettings: (String) -> Void
    @State private var selectedID: String?
    @State private var filter: PluginInstallationState?
    @State private var query: String

    init(marketplace: PluginMarketplace, settings: SettingsStore, selectedID: String? = nil,
         initialFilter: PluginInstallationState? = nil, initialQuery: String = "",
         openSettings: @escaping (String) -> Void) {
        self.marketplace = marketplace
        self.settings = settings
        self.openSettings = openSettings
        _selectedID = State(initialValue: selectedID)
        _filter = State(initialValue: initialFilter)
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if selectedID == nil { controls }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = marketplace.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let id = selectedID, let entry = marketplace.listings.first(where: { $0.id == id }) {
                        PluginMarketplaceDetail(entry: entry, marketplace: marketplace,
                                                settings: settings, openSettings: openSettings)
                    } else {
                        listing
                    }
                }
                .padding(20).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
            }
            .id("\(selectedID ?? "")-\(filter?.rawValue ?? "")")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { marketplace.refreshIfStale() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selectedID != nil {
                    Button { selectedID = nil } label: {
                        Label("插件市场", systemImage: "chevron.left")
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    Text("/ 插件详情").foregroundStyle(.secondary)
                } else {
                    Text("插件市场").font(.title2.weight(.semibold))
                }
                Spacer()
                if marketplace.refreshing { ProgressView().controlSize(.small) }
                Button(marketplace.refreshing ? "检查中…" : "检查更新") { marketplace.refresh() }
                    .disabled(marketplace.refreshing)
            }
            HStack {
                Text("NotchDeck \(marketplace.currentAppVersion)")
                Link("官方插件仓库 ↗", destination: PluginCatalog.repositoryURL)
                Spacer()
                if let date = marketplace.lastChecked {
                    Text("上次检查 \(TimeFormat.string(date, style: .dateTime))")
                } else {
                    Text("随应用提供的目录 · 离线可用")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                filterButton(nil, title: "全部", count: marketplace.listings.count)
                ForEach(PluginInstallationState.allCases, id: \.self) { state in
                    filterButton(state, title: state.rawValue,
                                 count: marketplace.filteredListings(state: state, query: "").count)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索插件名称或用途", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索插件")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
            }.padding(9).marketplaceCard()
            HStack {
                Text("已安装 = 已启用 · 已停用 = 保留配置")
                Spacer()
                Text("\(marketplace.filteredListings(state: filter, query: query).count) 个插件")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func filterButton(_ state: PluginInstallationState?, title: String, count: Int) -> some View {
        Button { filter = state } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").monospacedDigit().fontWeight(.semibold)
            }
            .font(.callout).frame(maxWidth: .infinity).padding(.vertical, 9)
            .foregroundStyle(filter == state ? Color.accentColor : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(filter == state ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(filter == state ? Color.accentColor : Color.clear))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(count) 个插件")
            .accessibilityAddTraits(filter == state ? .isSelected : [])
    }

    private var listing: some View {
        let entries = marketplace.filteredListings(state: filter, query: query)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                Button { selectedID = entry.id } label: {
                    HStack(spacing: 12) {
                        PluginMarketplaceIcon(symbol: entry.systemImage, size: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(.headline).foregroundStyle(.primary)
                            Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).help(entry.summary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 5) {
                            PluginStateBadge(state: marketplace.installationState(entry.id))
                            if let note = updateNote(for: entry) {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.fixedSize()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(12).contentShape(Rectangle()).marketplaceCard()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.name)，\(marketplace.installationState(entry.id).rawValue)，\(updateNote(for: entry) ?? "")，查看详情")
            }
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title2)
                    Text(query.isEmpty ? "此状态下暂无插件" : "没有匹配的插件").font(.headline)
                    Text("切换状态筛选或修改搜索内容。").font(.callout).foregroundStyle(.secondary)
                    Button("显示全部插件") { filter = nil; query = "" }
                }.frame(maxWidth: .infinity).padding(32)
            }
            if filter == nil && query.isEmpty && !marketplace.unavailableInstalledIDs.isEmpty {
                Text("需要处理").font(.headline).padding(.top, 12)
                ForEach(marketplace.unavailableInstalledIDs, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(id).font(.headline)
                            Text("已安装 · 当前应用未提供此插件").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除") { marketplace.remove(id) }
                    }.padding(12).marketplaceCard()
                }
            }
        }
    }

    private func updateNote(for entry: PluginListing) -> String? {
        var notes: [String] = []
        if marketplace.hasNativeUpdate(for: entry) { notes.append("主程序有更新") }
        if marketplace.isInstalled(entry.id),
           case .updatable = marketplace.scriptState(for: entry.id) { notes.append("适配可更新") }
        if !marketplace.isInstalled(entry.id), marketplace.installableListing(entry.id) == nil {
            notes.append("需更新应用")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

}

private struct PluginMarketplaceDetail: View {
    let entry: PluginListing
    @ObservedObject var marketplace: PluginMarketplace
    @ObservedObject var settings: SettingsStore
    let openSettings: (String) -> Void

    private var installed: Bool { marketplace.isInstalled(entry.id) }
    private var local: PluginListing? { marketplace.installableListing(entry.id) }
    private var nativeUpdate: Bool { marketplace.hasNativeUpdate(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                PluginMarketplaceIcon(symbol: entry.systemImage)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(entry.name).font(.title2.bold())
                        PluginStateBadge(state: marketplace.installationState(entry.id))
                    }
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("作者：\(entry.author)").font(.caption).foregroundStyle(.secondary)
                }
            }
            actions
            VStack(alignment: .leading, spacing: 12) {
                Text("功能介绍").font(.headline)
                if nativeUpdate {
                    Text("以下介绍对应目录 v\(entry.version)，本机 v\(marketplace.localVersion(entry.id) ?? "—") 的功能以当前设置为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.details).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(entry.capabilities.enumerated()), id: \.offset) { _, capability in
                    Label(capability, systemImage: "checkmark")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 20) {
                    Link("使用说明 ↗", destination: entry.documentationURL)
                    Link("查看源码 ↗", destination: entry.sourceURL)
                }.font(.callout).padding(.top, 4)
            }
            versionSection
            if installed, entry.script != nil { scriptSection }
            if installed {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("移除插件").font(.callout)
                        Text("停止运行并保留配置，可随时重新添加。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("移除") { marketplace.remove(entry.id) }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if installed {
                if marketplace.isEnabled(entry.id) {
                    Button(marketplace.hasSettings(entry.id) ? "打开设置" : "布局设置") { openSettings(entry.id) }
                        .buttonStyle(.borderedProminent)
                    Button("停用插件") { marketplace.setEnabled(entry.id, enabled: false) }
                    Text("已启用").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("启用插件") { marketplace.setEnabled(entry.id, enabled: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(marketplace.localVersion(entry.id) == nil)
                    Button(marketplace.hasSettings(entry.id) ? "打开设置" : "布局设置") { openSettings(entry.id) }
                    Text("配置已保留").font(.caption).foregroundStyle(.secondary)
                }
            } else if let local {
                Button(nativeUpdate ? "安装本机 v\(local.version)" : "安装插件") {
                    if marketplace.install(entry.id) { openSettings(entry.id) }
                }.buttonStyle(.borderedProminent)
                Text("安装后启用，可随时停用").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("需更新 NotchDeck 后安装", systemImage: "arrow.up.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("插件版本").font(.headline)
            HStack(spacing: 24) {
                Text("本机：\(marketplace.localVersion(entry.id).map { "v\($0)" } ?? "未随附")")
                if nativeUpdate || marketplace.localVersion(entry.id) == nil {
                    Text("目录：v\(entry.version)")
                } else {
                    Text("已是最新版本").foregroundStyle(.secondary)
                }
            }.font(.callout).monospacedDigit()
            if let requirement = marketplace.requirement(for: entry) {
                Text("\(requirement)；当前为 \(marketplace.currentAppVersion)。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("此版本随 NotchDeck 安装包交付。打开下载页，下载安装新版并替换“应用程序”中的 NotchDeck，再重新启动；已有插件配置会保留。若下载页尚无所需版本，请继续使用本机版本，等待正式发布。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("打开 NotchDeck 下载页 ↗", destination: PluginCatalog.releasesURL)
                    .buttonStyle(.borderedProminent)
            } else {
                Text(entry.script == nil
                     ? "插件功能随 NotchDeck 更新。"
                     : "插件功能随 NotchDeck 更新；GLM 解析适配可单独更新。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).marketplaceCard()
    }

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GLM 解析适配").font(.headline)
            Text("用于兼容 GLM 额度接口，在应用内安装或更新后立即生效，无需重启。它不会升级上方的插件功能版本。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch marketplace.scriptState(for: entry.id) {
            case .none:
                EmptyView()
            case .notInstalled:
                Text("当前使用应用内置解析；市场提供 v\(entry.script?.version ?? "—")。")
                    .font(.callout)
                scriptButton("安装解析适配")
            case .installed(let version):
                Label("已安装 v\(version) · 无需更新", systemImage: "checkmark.circle")
                    .font(.callout)
            case .updatable(let current, let available):
                Text("已安装 v\(current) → 可更新至 v\(available)").font(.callout)
                scriptButton("更新解析适配")
            }
            if marketplace.scriptPluginID == entry.id, let message = marketplace.scriptMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).marketplaceCard()
    }

    private func scriptButton(_ title: String) -> some View {
        HStack(spacing: 10) {
            Button(title) { marketplace.updateScript(for: entry.id) }
                .buttonStyle(.borderedProminent).disabled(marketplace.updatingScript)
            if marketplace.updatingScript && marketplace.scriptPluginID == entry.id {
                ProgressView().controlSize(.small)
                Text("正在下载并校验…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PluginStateBadge: View {
    let state: PluginInstallationState

    private var symbol: String {
        switch state {
        case .installed: return "checkmark.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .notInstalled: return "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .installed: return .accentColor
        case .disabled: return .orange
        case .notInstalled: return .secondary
        }
    }

    var body: some View {
        Label(state.rawValue, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(state == .disabled ? Color.primary : tint)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
    }
}

private struct PluginMarketplaceIcon: View {
    let symbol: String
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(Color.accentColor).frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
    }
}

private extension View {
    func marketplaceCard() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}
