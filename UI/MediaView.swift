import SwiftUI

/// 已启用媒体源的封面、标题、进度与播放控制。
struct MediaView: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        if let track = module.track {
            HStack(spacing: 12) {
                artworkButton(for: track)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle(for: track))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if track.duration > 1 {
                        progressBar(for: track)
                    }
                }
                Spacer(minLength: 8)
                controls(for: track)
            }
            .frame(minHeight: 64)
        } else if module.noSourceConfigured {
            noSourceState
        } else {
            emptyState
        }
    }

    /// 未配置媒体源：引导去设置（默认最小权限，添加源后才申请授权）
    private var noSourceState: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("未添加媒体源")
                    .font(.callout)
                Text("在设置中开启 Music / Spotify")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: AppModel.openSettingsRequest, object: nil)
            } label: {
                Text("去添加")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            }
            .buttonStyle(ScalingButtonStyle())
            .foregroundStyle(Color.accentColor)
            .help("打开设置添加媒体源")
        }
        .frame(minHeight: 56)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("暂无媒体播放")
                    .font(.callout)
                Text("已启用的媒体源上没有正在播放的内容")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 56)
    }

    private func subtitle(for track: MediaTrack) -> String {
        var parts: [String] = [track.artist.isEmpty ? "未知艺术家" : track.artist]
        if !track.appName.isEmpty {
            parts.append("· \(track.appName)")
        }
        return parts.joined(separator: " ")
    }

    private func artworkButton(for track: MediaTrack) -> some View {
        Group {
            if let artwork = track.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { module.openApp() }
        .help("在 \(track.appName.isEmpty ? "媒体 App" : track.appName) 中打开")
    }

    private func progressBar(for track: MediaTrack) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, min(track.duration,
                              track.elapsed + (track.isPlaying
                                               ? context.date.timeIntervalSince(module.trackUpdatedAt)
                                               : 0)))
            VStack(spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: max(2, proxy.size.width * min(1, elapsed / track.duration)))
                    }
                }
                .frame(height: 3)
                HStack {
                    Text(timeString(elapsed))
                    Spacer()
                    Text(timeString(track.duration))
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func controls(for track: MediaTrack) -> some View {
        HStack(spacing: 16) {
            controlButton("backward.end.fill", help: "上一首") {
                module.playPrevious()
            }
            controlButton(track.isPlaying ? "pause.fill" : "play.fill",
                          size: 18,
                          help: track.isPlaying ? "暂停" : "播放") {
                module.togglePlayPause()
            }
            controlButton("forward.end.fill", help: "下一首") {
                module.playNext()
            }
        }
    }

    private func controlButton(_ systemName: String,
                               size: CGFloat = 14,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScalingButtonStyle())
        .help(help)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
