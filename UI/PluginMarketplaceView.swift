import SwiftUI

struct PluginMarketplaceView: View {
    @ObservedObject var marketplace: PluginMarketplace
    @ObservedObject var settings: SettingsStore
    let openSettings: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = marketplace.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
                if marketplace.listings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
                        Text("暂无插件").font(.headline)
                        Text("刷新目录或前往 GitHub 查看。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                }
                ForEach(marketplace.listings) { entry in
                    PluginMarketplaceCard(entry: entry, marketplace: marketplace, settings: settings,
                                          openSettings: openSettings)
                }
                ForEach(marketplace.unavailableInstalledIDs, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(id).font(.headline)
                            Text("已添加，当前版本暂不可用").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除") { marketplace.remove(id) }
                    }.padding(18)
                }
                Text("新插件和版本升级通过更新 NotchDeck 获取。移除会停止插件运行，保留配置；GLM 密钥可在插件设置中单独删除。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("插件市场").font(.title2.weight(.semibold))
                    Text("为信息岛添加更多内容").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Link(destination: PluginCatalog.repositoryURL) {
                    Label("GitHub 目录", systemImage: "arrow.up.right.square")
                }.font(.caption)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(marketplace.lastChecked == nil ? "随应用提供的目录 · 离线可用" : "GitHub 目录 · 已缓存到本机")
                    if let date = marketplace.lastChecked {
                        Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if marketplace.refreshing { ProgressView().controlSize(.small) }
                Button(marketplace.refreshing ? "刷新中…" : "刷新目录") { marketplace.refresh() }
                    .disabled(marketplace.refreshing).help("从 GitHub 获取最新插件说明和兼容版本")
            }
        }
    }
}

private struct PluginMarketplaceCard: View {
    let entry: PluginListing
    @ObservedObject var marketplace: PluginMarketplace
    @ObservedObject var settings: SettingsStore
    let openSettings: (String) -> Void

    private var installed: Bool { marketplace.isInstalled(entry.id) }
    private var requirement: String? { marketplace.requirement(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.name).font(.headline)
                        Text("v\(entry.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Text(entry.details).font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.capabilities.enumerated()), id: \.offset) { _, capability in
                    Label(capability, systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Text(entry.author).font(.caption).foregroundStyle(.secondary)
                Link("使用说明", destination: entry.documentationURL).font(.caption)
                Link("源码", destination: entry.sourceURL).font(.caption)
                Spacer(minLength: 0)
            }
            if let requirement {
                HStack {
                    Text(requirement).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Link("获取新版", destination: PluginCatalog.releasesURL).font(.caption)
                }
            }
            actions
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if installed {
                Label(settings.config(for: entry.id).enabled ? "已添加" : "已添加 · 已停用", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let version = marketplace.installedVersion(entry.id), version != entry.version {
                    Text("本机 v\(version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("移除") { marketplace.remove(entry.id) }
                Button("设置") { openSettings(entry.id) }.buttonStyle(.borderedProminent)
                    .disabled(!marketplace.hasSettings(entry.id))
            } else {
                Text(requirement == nil ? "添加后可在模块管理中调整位置" : "当前应用尚未随附此版本")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("添加插件") {
                    if marketplace.install(entry.id) { openSettings(entry.id) }
                }.buttonStyle(.borderedProminent).disabled(requirement != nil)
            }
        }
    }
}
