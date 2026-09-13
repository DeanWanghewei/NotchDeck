import SwiftUI

/// 主面板：固定尺寸悬浮岛屿，内容填满窗口（展开/收起动画由 SwiftUI 过渡完成）
struct NotchDeckView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            if app.isExpanded {
                PanelRoot()
                    .transition(.panelExpand)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: app.isExpanded)
    }
}

// MARK: - 面板主体（常驻区 + 标签页区）

private struct PanelRoot: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let pinned = app.pinnedModules
        let tabs = app.tabModules

        VStack(spacing: 14) {
            // 上层：常驻区（为空则整体不占位）
            if !pinned.isEmpty {
                VStack(spacing: 14) {
                    ForEach(pinned) { box in
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader(box)
                            box.makeContent()
                        }
                    }
                }
            }

            // 下层：标签页区
            if tabs.count > 1 {
                ModuleTabBar(boxes: tabs, selection: tabSelection)
                tabContent(in: tabs)
                    .id(selectedTabID(in: tabs))
            } else if tabs.count == 1 {
                tabs[0].makeContent()
            }

            if pinned.isEmpty && tabs.isEmpty {
                emptyHint
            }

            Spacer(minLength: 0)

            PanelFooter()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffectBackground())
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.activeTabID)
    }

    private func sectionHeader(_ box: ModuleBox) -> some View {
        HStack(spacing: 5) {
            Image(systemName: box.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(box.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var tabSelection: Binding<String?> {
        Binding(
            get: { app.activeTabID ?? app.tabModules.first?.id },
            set: { app.activeTabID = $0 })
    }

    private func selectedTabID(in tabs: [ModuleBox]) -> String? {
        tabs.first { $0.id == tabSelection.wrappedValue }?.id ?? tabs.first?.id
    }

    @ViewBuilder
    private func tabContent(in tabs: [ModuleBox]) -> some View {
        if let selected = tabs.first(where: { $0.id == selectedTabID(in: tabs) }) {
            selected.makeContent()
                .transition(.tabSwitch)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("没有可显示的模块")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("在设置中开启或添加模块")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
    }
}

// MARK: - 底栏

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
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(ScalingButtonStyle())
            .foregroundStyle(.secondary)
            .help("打开设置")
            Button {
                NotificationCenter.default.post(name: AppModel.quitRequest, object: nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(ScalingButtonStyle())
            .foregroundStyle(.secondary)
            .help("退出 NotchDeck")
        }
    }
}
