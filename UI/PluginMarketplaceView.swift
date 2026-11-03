import SwiftUI

struct PluginMarketplaceView: View {
    @ObservedObject var marketplace: PluginMarketplace
    @ObservedObject var settings: SettingsStore
    let openSettings: (String) -> Void
    @State private var selectedID: String?

    init(marketplace: PluginMarketplace, settings: SettingsStore, selectedID: String? = nil,
         openSettings: @escaping (String) -> Void) {
        self.marketplace = marketplace
        self.settings = settings
        self.openSettings = openSettings
        _selectedID = State(initialValue: selectedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                .padding(24).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
            }
            .id(selectedID)
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
                Spacer()
                if let date = marketplace.lastChecked {
                    Text("上次检查 \(TimeFormat.string(date, style: .dateTime))")
                } else {
                    Text("随应用提供的目录 · 离线可用")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }

    private var listing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("为信息岛添加更多内容，选择插件查看详情与更新方式。")
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(marketplace.listings) { entry in
                Button { selectedID = entry.id } label: {
                    HStack(spacing: 14) {
                        PluginMarketplaceIcon(symbol: entry.systemImage)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.name).font(.headline).foregroundStyle(.primary)
                            Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Text(status(for: entry)).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(18).contentShape(Rectangle())
                    .marketplaceCard()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.name)，\(status(for: entry))，查看详情")
            }
            ForEach(marketplace.unavailableInstalledIDs, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(id).font(.headline)
                        Text("已添加，当前应用未提供此插件").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("移除") { marketplace.remove(id) }
                }.padding(18).marketplaceCard()
            }
            if marketplace.listings.isEmpty && marketplace.unavailableInstalledIDs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.largeTitle)
                    Text("暂无插件").font(.headline)
                    Text("点击“检查更新”重新获取目录。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(40)
            }
        }
    }

    private func status(for entry: PluginListing) -> String {
        if marketplace.hasNativeUpdate(for: entry) { return "随主程序更新" }
        if marketplace.isInstalled(entry.id) {
            if case .updatable = marketplace.scriptState(for: entry.id) { return "适配可更新" }
            return settings.config(for: entry.id).enabled ? "已添加" : "已停用"
        }
        return marketplace.installableListing(entry.id) == nil ? "查看版本要求" : "可添加"
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
                    Text(entry.name).font(.title2.bold())
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("作者：\(entry.author)").font(.caption).foregroundStyle(.secondary)
                }
            }
            actions
            versionSection
            if installed, entry.script != nil { scriptSection }
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
            if installed {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("移除插件").font(.callout)
                        Text("停止运行并保留账号、配置和解析适配，可随时重新添加。")
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
                Button("打开设置") { openSettings(entry.id) }
                    .buttonStyle(.borderedProminent).disabled(!marketplace.hasSettings(entry.id))
                Label(settings.config(for: entry.id).enabled ? "已添加" : "已添加 · 已停用", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let local {
                Button(nativeUpdate ? "添加本机 v\(local.version)" : "添加插件") {
                    if marketplace.install(entry.id) { openSettings(entry.id) }
                }.buttonStyle(.borderedProminent)
                Text("添加后可配置账号与展示位置").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("当前应用未提供可添加的版本").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("插件版本").font(.headline)
            HStack(spacing: 24) {
                Text("本机：\(marketplace.localVersion(entry.id).map { "v\($0)" } ?? "未随附")")
                Text("目录：v\(entry.version)")
            }.font(.callout).monospacedDigit()
            if let requirement = marketplace.requirement(for: entry) {
                Text("\(requirement)；当前为 \(marketplace.currentAppVersion)。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("此版本随 NotchDeck 安装包交付。打开下载页，下载安装新版并替换“应用程序”中的 NotchDeck，再重新启动；已有插件配置会保留。若下载页尚无所需版本，请继续使用本机版本，等待正式发布。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("打开 NotchDeck 下载页 ↗", destination: PluginCatalog.releasesURL)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("本机已包含此插件版本。插件功能升级随 NotchDeck 更新；下方解析适配可单独更新。")
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

private struct PluginMarketplaceIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 23, weight: .medium))
            .foregroundStyle(Color.accentColor).frame(width: 48, height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
    }
}

private extension View {
    func marketplaceCard() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}
