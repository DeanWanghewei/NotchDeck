import SwiftUI

/// 音乐控制：封面、标题、歌手、播放控制（Music / Spotify）
struct MusicView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let track = app.music.track {
            HStack(spacing: 12) {
                artworkButton(for: track)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? "未知艺术家" : track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(track.source.rawValue,
                          systemImage: track.source == .appleMusic ? "music.note" : "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                controls(for: track)
            }
            .frame(height: 64)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("未检测到正在播放的音乐")
                        .font(.callout)
                    Text("支持 Music 与 Spotify")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 64)
        }
    }

    private func artworkButton(for track: TrackInfo) -> some View {
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
        .onTapGesture { MusicController.openApp(source: track.source) }
        .help("在 \(track.source.rawValue) 中打开")
    }

    private func controls(for track: TrackInfo) -> some View {
        HStack(spacing: 16) {
            controlButton("backward.end.fill", help: "上一首") {
                MusicController.playPrevious(source: track.source)
            }
            controlButton(track.isPlaying ? "pause.fill" : "play.fill",
                          size: 18,
                          help: track.isPlaying ? "暂停" : "播放") {
                MusicController.togglePlayPause(source: track.source)
            }
            controlButton("forward.end.fill", help: "下一首") {
                MusicController.playNext(source: track.source)
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
}
