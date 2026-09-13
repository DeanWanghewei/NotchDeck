import AppKit
import SwiftUI

/// 已安装应用选择器：搜索、白名单"已适配"标记、点击添加/移除
struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared

    @State private var installed: [InstalledApps.InstalledApp] = []
    @State private var searchText = ""
    @State private var isLoading = true

    private var filtered: [InstalledApps.InstalledApp] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return installed }
        return installed.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) ||
            $0.bundleID.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加应用到面板")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            TextField("搜索已安装的应用", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)

            if isLoading {
                Spacer()
                ProgressView("正在扫描已安装应用…")
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text("没有匹配的应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { app in
                            row(app)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 480, height: 540)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = InstalledApps.scan()
                DispatchQueue.main.async {
                    installed = apps
                    isLoading = false
                }
            }
        }
    }

    private func isAdded(_ app: InstalledApps.InstalledApp) -> Bool {
        settings.panelApps.contains { $0.bundleID == app.bundleID }
    }

    private func row(_ app: InstalledApps.InstalledApp) -> some View {
        let added = isAdded(app)
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if AdaptedApps.isAdapted(app.bundleID) {
                        AdaptedBadge()
                    }
                }
                Text(app.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                if added {
                    settings.panelApps.removeAll { $0.bundleID == app.bundleID }
                } else {
                    settings.panelApps.append(PanelApp(bundleID: app.bundleID,
                                                       name: app.name,
                                                       path: app.path))
                }
            } label: {
                Text(added ? "已添加" : "添加")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 52, height: 22)
                    .background(
                        Capsule().fill(added ? Color.green.opacity(0.16) : Color.accentColor.opacity(0.16))
                    )
                    .foregroundStyle(added ? Color.green : Color.accentColor)
            }
            .buttonStyle(ScalingButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(added ? Color.primary.opacity(0.03) : Color.clear)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.panelApps)
    }
}
