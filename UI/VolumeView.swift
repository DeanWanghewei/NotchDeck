import SwiftUI

/// 音量控制：滑杆 + 静音切换
struct VolumeView: View {
    @ObservedObject var module: VolumeModule

    var body: some View {
        HStack(spacing: 12) {
            Button {
                module.toggleMute()
            } label: {
                Image(systemName: speakerIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(module.muted ? Color.orange : Color.secondary)
                    .frame(width: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalingButtonStyle())
            .disabled(!module.canMute)
            .help(module.muted ? "取消静音" : "静音")

            Slider(value: Binding(
                get: { module.volume },
                set: { module.setVolume($0, immediate: false) }),
                   in: 0...100,
                   onEditingChanged: { editing in
                       module.setEditing(editing)
                   })
                .tint(.accentColor)
                .disabled(!module.canSetVolume)
                .help(module.canSetVolume ? "输出音量" : "当前输出设备不支持系统音量调节")

            Text(module.canSetVolume ? "\(Int(module.volume.rounded()))" : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 36)
    }

    private var speakerIcon: String {
        if module.muted || module.volume == 0 { return "speaker.slash.fill" }
        if module.volume < 33 { return "speaker.wave.1.fill" }
        if module.volume < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
