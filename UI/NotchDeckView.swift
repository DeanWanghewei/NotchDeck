import SwiftUI

/// 主面板：顶部黑色"刘海帽"与系统刘海融合，主体从刘海向下生长
struct NotchDeckView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            BottomRoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
                .frame(width: PanelMetrics.capWidth, height: PanelMetrics.menuBarHeight)

            ZStack(alignment: .top) {
                if app.isExpanded {
                    PanelBody()
                        .transition(.opacity)
                }
            }
            .frame(height: app.isExpanded ? PanelMetrics.bodyHeight : 0, alignment: .top)
            .clipped()
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: app.isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct PanelBody: View {
    var body: some View {
        VStack(spacing: 12) {
            MusicView()
            PanelDivider()
            SystemMonitorView()
            PanelDivider()
            NodeListView()
            PanelFooter()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(height: PanelMetrics.bodyHeight, alignment: .top)
        .background(VisualEffectBackground())
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
        .clipShape(BottomRoundedRectangle(cornerRadius: PanelMetrics.cornerRadius))
        .overlay(
            BottomRoundedRectangle(cornerRadius: PanelMetrics.cornerRadius)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
    }
}

private struct PanelFooter: View {
    @ObservedObject private var settings = SettingsStore.shared

    private var hotKeyHint: String {
        let display = HotKeyManager.display(keyCode: settings.hotKeyCode,
                                            carbonModifiers: settings.hotKeyModifiers)
        return "\(display) 呼出面板"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(hotKeyHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开设置")
            Button {
                NotificationCenter.default.post(name: AppModel.quitRequest, object: nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("退出 NotchDeck")
        }
    }
}
