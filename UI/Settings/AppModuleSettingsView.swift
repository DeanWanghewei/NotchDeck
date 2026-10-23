import SwiftUI

struct AppModuleSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var showAppPicker = false

    var body: some View {
        Section("应用快捷控制") {
            if settings.panelApps.isEmpty {
                Text("从已安装应用中挑选常用 App 添加到面板，一键启动 / 退出、查看运行状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.panelApps) { app in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(app.name)
                        if AdaptedApps.isAdapted(app.bundleID) {
                            AdaptedBadge()
                        }
                        Spacer()
                        Button {
                            settings.panelApps.removeAll { $0.id == app.id }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(ScalingButtonStyle())
                        .foregroundStyle(.secondary)
                        .help("从面板移除")
                    }
                }
            }
            Button("添加应用…") {
                showAppPicker = true
            }
        }

        .sheet(isPresented: $showAppPicker) { AppPickerSheet(settings: settings) }
    }
}
