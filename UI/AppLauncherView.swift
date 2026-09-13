import SwiftUI

/// 应用快捷控制：图标、运行状态、启动/退出，白名单应用带"已适配"标记
struct AppLauncherView: View {
    @ObservedObject var module: AppLauncherModule
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(settings.panelApps) { app in
                row(app)
            }
            HStack {
                Spacer()
                Text("在设置中添加 / 管理应用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.panelApps)
    }

    private func row(_ app: PanelApp) -> some View {
        let running = module.isRunning(app)
        return HStack(spacing: 10) {
            Image(nsImage: module.icon(for: app))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if module.isAdapted(app) {
                        AdaptedBadge()
                    }
                }
                Text(running ? "运行中" : "未运行")
                    .font(.caption2)
                    .foregroundStyle(running ? Color.green : Color.secondary)
            }
            Spacer()
            Button {
                if running {
                    module.quit(app)
                } else {
                    module.open(app)
                }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(running ? Color.red.opacity(0.14) : Color.accentColor.opacity(0.14)))
                    .foregroundStyle(running ? Color.red : Color.accentColor)
                    .contentShape(Circle())
            }
            .buttonStyle(ScalingButtonStyle())
            .help(running ? "退出 \(app.name)" : "启动 \(app.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
