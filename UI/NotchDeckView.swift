import SwiftUI

/// 主面板：固定尺寸窗口，内容按展开后的几何一次排好、全程不移动；
/// 展开/收起是轮廓自己的形变（`PanelOutline`），内容只被这团轮廓遮住或露出。
struct NotchDeckView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var presentation: PanelPresentation

    var body: some View {
        ZStack(alignment: .top) {
            // 收起动画结束后才卸载。挂载/卸载本身不参与动画：能缓动的只有形状参数，
            // 带过渡的插入/移除会让面板整块淡入，盖过形变。
            if presentation.isPresented, let layout = presentation.layout {
                PanelRoot(layout: layout)
                    .transition(.identity)
                    .onAppear { presentation.didMount?() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

// MARK: - 面板主体（顶部常驻 + 标签页 + 底部常驻）

private struct PanelRoot: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelOutlineOverride) private var outlineOverride
    let layout: PanelLayout

    /// 展开是 Bool，轮廓却必须是能被缓动的数：这里按目标状态给出两份轮廓中的一份，
    /// `PanelBodyShape` 的 animatableData 让弹簧在两份轮廓的每个长度之间插值。
    private var outline: PanelOutline {
        outlineOverride ?? (app.isExpanded ? .expanded(for: layout) : .folded(for: layout))
    }

    private var surface: PanelSurfaceStyle {
        PanelSurfaceStyle.resolve(glassEnabled: app.settings.liquidGlass,
                                  glassAvailable: PanelSurfaceStyle.glassAvailable,
                                  reduceTransparency: reduceTransparency,
                                  increasedContrast: contrast == .increased)
    }

    var body: some View {
        PanelOutlineLayer(outline: outline, layout: layout,
                          showsContent: app.isExpanded, surface: surface,
                          reduceMotion: reduceMotion) {
            card
        }
        // 接壤卡片保持深色，与硬件刘海融合；悬浮卡片跟随系统浅色/深色。
        .environment(\.colorScheme, layout.isAttached ? .dark : colorScheme)
    }

    private var card: some View {
        let pinned = app.pinnedModules
        let tabs = app.tabModules
        let bottom = app.bottomModules

        return VStack(spacing: 14) {
            ScrollView(.vertical) {
                VStack(spacing: 14) {
                    // 上层：常驻区（为空则整体不占位）
                    if !pinned.isEmpty {
                        VStack(spacing: 14) {
                            ForEach(pinned) { box in
                                VStack(alignment: .leading, spacing: 8) {
                                    if box.descriptor.presentation.showsSectionHeader { sectionHeader(box) }
                                    box.content(in: app.presentationContext(for: box))
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
                        tabs[0].content(in: app.presentationContext(for: tabs[0]))
                    }

                    ForEach(bottom) { box in
                        VStack(alignment: .leading, spacing: 8) {
                            if box.descriptor.presentation.showsSectionHeader { sectionHeader(box) }
                            box.content(in: app.presentationContext(for: box))
                        }
                    }

                    if pinned.isEmpty && tabs.isEmpty && bottom.isEmpty {
                        emptyHint
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PanelFooter()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? NotchMotion.still : NotchMotion.layout, value: app.activeTabID)
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
            get: {
                app.tabModules.first(where: { $0.id == app.activeTabID })?.id ?? app.tabModules.first?.id
            },
            set: { app.activeTabID = $0 })
    }

    private func selectedTabID(in tabs: [ModuleBox]) -> String? {
        tabs.first { $0.id == tabSelection.wrappedValue }?.id ?? tabs.first?.id
    }

    @ViewBuilder
    private func tabContent(in tabs: [ModuleBox]) -> some View {
        if let selected = tabs.first(where: { $0.id == selectedTabID(in: tabs) }) {
            selected.content(in: app.presentationContext(for: selected))
                .transition(reduceMotion ? .opacity : .tabSwitch)
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
    @EnvironmentObject private var app: AppModel

    private var hotKeyHint: String {
        let display = HotKeyManager.display(keyCode: app.settings.hotKeyCode,
                                            carbonModifiers: app.settings.hotKeyModifiers)
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
