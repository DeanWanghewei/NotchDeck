import SwiftUI

/// 媒体控制：封面、标题、进度、播放控制（系统级正在播放，覆盖常用媒体 App）
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
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("暂无媒体播放")
                    .font(.callout)
                Text("支持 Music、Spotify 及浏览器等媒体 App")
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
            let elapsed = min(track.duration,
                              track.elapsed + (track.isPlaying
                                               ? context.date.timeIntervalSince(module.trackUpdatedAt)
                                               : 0))
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
        .buttonStyle(.plain)
        .help(help)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
