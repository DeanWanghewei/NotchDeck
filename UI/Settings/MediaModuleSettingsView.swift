import SwiftUI

struct MediaModuleSettingsView: View {
    @ObservedObject var module: MediaModule
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Section("媒体源") {
            Toggle(isOn: $settings.experimentalNowPlaying) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实验性：读取系统正在播放")
                    Text("支持任意播放器（飞牛影视 / IINA / 浏览器等），无需逐个添加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("当前系统") {
                Text(SystemCompat.currentDescription)
                    .monospacedDigit()
            }
            LabeledContent("适配状态") {
                switch SystemCompat.adaptation {
                case .verified:
                    Label("已实测适配", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .untested:
                    Label("机制可用，此版本未经实测", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                case .unsupported:
                    Label("机制不可用（需 macOS 15.4+）", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("运行状态") {
                if !settings.experimentalNowPlaying {
                    Text("未开启").foregroundStyle(.secondary)
                } else if module.experimentalAvailable {
                    Label("运行正常", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("失败中，每 60 秒自动重试", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("支持范围") {
                Text("macOS 15.4+（更早版本自动回退手动媒体源）")
                    .foregroundStyle(.secondary)
            }

            let installed = MediaModule.installedSources
            if installed.isEmpty {
                Text("未检测到受支持的媒体 App（Music / Spotify）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(installed, id: \.bundleID) { source in
                    Toggle(isOn: mediaSourceBinding(source)) {
                        HStack(spacing: 6) {
                            Label(source.displayName, systemImage: source.symbol)
                            AdaptedBadge()
                        }
                    }
                }
                let notInstalled = MediaModule.knownSources.filter { source in
                    !installed.contains(where: { $0.bundleID == source.bundleID })
                }
                if !notInstalled.isEmpty {
                    Text("未安装：" + notInstalled.map(\.displayName).joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text("默认不申请任何权限。开启媒体源后，该 App 运行时首次读取会请求自动化授权。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.experimentalNowPlaying {
                Text("实验性说明：经由系统 Perl 加载只读适配器读取系统「正在播放」汇总（机制依赖 macOS 15.4+ 的 com.apple.perl 授权路径），随系统更新可能失效；失效时自动回退到上方手动媒体源。开启后优先于手动源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 启用即触发一次读取：授权弹窗在用户主动开启的时刻出现，语境清晰
    private func mediaSourceBinding(_ source: MediaModule.MediaSource) -> Binding<Bool> {
        Binding(
            get: { settings.mediaSources.contains(source.bundleID) },
            set: { enabled in
                if enabled {
                    settings.mediaSources.append(source.bundleID)
                } else {
                    settings.mediaSources.removeAll { $0 == source.bundleID }
                }
            })
    }
}
