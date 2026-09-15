import GRDB
import SwiftUI

/// 封面下方的小歌词窗口：显示当前句（+翻译），跟随播放进度更新；点击进入全屏歌词。
/// 独立 struct 观察 progress，避免整个 PlayerView 每秒重绘四次。
struct LyricMiniSection: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let lyrics: Lyrics?
    let isLoading: Bool
    /// App 强调色（读环境值；根注入见 ContentView）
    @Environment(\.appAccentColor) private var accentColor

    /// 当前句 index（syncedLyrics 中）；还没到第一句时返回 0
    private var activeIndex: Int? {
        LyricTiming.activeLineIndex(time: progress.playbackTime, in: lyrics?.syncedLyrics ?? []) ?? 0
    }

    private func line(_ index: Int, in lines: [LyricsLine]) -> LyricsLine? {
        guard index >= 0, index < lines.count else { return nil }
        return lines[index]
    }

    var body: some View {
        Group {
            if isLoading {
                Text(NSLocalizedString("lyrics_mini_loading", value: "Loading lyrics…", comment: ""))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            } else if let lines = lyrics?.syncedLyrics, !lines.isEmpty {
                let idx = activeIndex ?? 0
                VStack(spacing: DesignTokens.space6) {
                    miniLine(line(idx - 1, in: lines)?.displayText, isActive: false)
                    miniLine(line(idx, in: lines)?.displayText, isActive: true)
                    miniLine(line(idx + 1, in: lines)?.displayText, isActive: false)
                }
                .frame(maxWidth: .infinity)
            } else if let lyrics = lyrics,
                      let firstLine = lyrics.plainLyrics.split(separator: "\n").first {
                // 无时间轴歌词：显示第一行
                Text(DisplayScriptNormalizer.display(String(firstLine)))
                    .font(.callout.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            } else {
                Text(NSLocalizedString("lyrics_mini_none", value: "No lyrics", comment: ""))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DesignTokens.space12)
        .padding(.horizontal, DesignTokens.space16)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: activeIndex)
    }

    private func miniLine(_ text: String?, isActive: Bool) -> some View {
        Text(text ?? "")
            .font(isActive ? .body.weight(.semibold) : .subheadline)
            .foregroundColor(isActive ? accentColor : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Keeps lyric timing updates inside the presented lyrics content instead of
/// invalidating the player and any underlying list.
struct LiveLyricsSheet: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let lyrics: Lyrics?
    let isLoading: Bool
    let onClose: () -> Void

    var body: some View {
        LyricsView(
            lyrics: lyrics,
            currentTime: progress.playbackTime,
            isLoading: isLoading,
            onClose: onClose
        )
    }
}

struct MiniPlayerView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var isExpanded = false
    @State private var currentArtwork: UIImage?
    @State private var settings = DeleteSettings.load()

    var body: some View {
        Group {
            if playerEngine.currentTrack != nil {
                // Mini player that shows sheet when tapped
                VStack(spacing: DesignTokens.space0) {
                    // Mini player content
                    HStack(spacing: DesignTokens.space12) {
                        // Album artwork
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignTokens.radius8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 60, height: 60)

                            if let artwork = currentArtwork {
                                Image(uiImage: artwork)
                                    .resizable().scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius8))
                            } else {
                                Image(systemName: "music.note")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Track info
                        VStack(alignment: .leading, spacing: DesignTokens.space4) {
                            Text(playerEngine.currentTrack?.displayTitle ?? "")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if let artistId = playerEngine.currentTrack?.artistId,
                               let artist = try? DatabaseManager.shared.read({ db in
                                   try Artist.fetchOne(db, key: artistId)
                               }) {
                                Text(ArtistNameNormalizer.displayName(artist.name))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        // Take the slack rather than leaving it between the
                        // labels and the transport controls, so titles have as
                        // much room as possible before truncating.
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Transport: previous / play-pause / next.
                        // buttonStyle(.plain) and a contentShape per button stop
                        // the row's tap gesture (which expands the player) from
                        // swallowing these taps.
                        HStack(spacing: DesignTokens.space14) {
                            Button(action: {
                                Task { await playerEngine.previousTrack() }
                            }) {
                                Image(systemName: "backward.fill")
                                    .font(.title3)
                                    .foregroundColor(.primary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Button(action: {
                                if playerEngine.isPlaying {
                                    playerEngine.pause()
                                } else {
                                    playerEngine.play()
                                }
                            }) {
                                Image(systemName: playerEngine.isPlaying ? "pause.circle" : "play.circle")
                                    .font(.title)
                                    .foregroundColor(.primary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Button(action: {
                                Task { await playerEngine.nextTrack() }
                            }) {
                                Image(systemName: "forward.fill")
                                    .font(.title3)
                                    .foregroundColor(.primary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    // Trimmed from 16 to give the title and the three transport
                    // buttons a little more room on narrow phones.
                    .padding(.horizontal, DesignTokens.space12)
                    .padding(.vertical, DesignTokens.space12)
                    .background(
                        // Very strong glassy background
                        RoundedRectangle(cornerRadius: DesignTokens.radius16)
                            .fill(.regularMaterial)
                            .opacity(0.98)
                    )
                    .overlay(
                        // Progress bar integrated into the mini player background
                        VStack(spacing: DesignTokens.space0) {
                            Spacer()

                            MiniPlayerProgressBar(
                                duration: playerEngine.duration
                            )
                        }
                    )
                    .cornerRadius(DesignTokens.radius16)
                    .shadow(color: accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                    .padding(.horizontal, DesignTokens.space12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isExpanded = true
                    }
                }
                .fullScreenCover(isPresented: $isExpanded) {
                    // 全屏播放页（2026-08-29：sheet 弹窗改全屏覆盖，无圆角/拖动条/背景露出）
                    PlayerView()
                        .accentColor(accentColor)
                }
                .task(id: playerEngine.currentTrack?.stableId) {
                    if let track = playerEngine.currentTrack {
                        currentArtwork = await artworkManager.getArtwork(for: track)
                    } else {
                        currentArtwork = nil
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { _ in
                    // Minimize the player when artist navigation is requested
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { _ in
                    // Minimize the player when album navigation is requested
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MinimizePlayer"))) { _ in
                    // Minimize the player when artwork is tapped
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                    settings = DeleteSettings.load()
                }
            }
        }
    }
}

/// A render-only progress leaf. Scaling a full-width rectangle changes only
/// its transform; it does not resize the safe-area inset or ask the underlying
/// Library List to perform a collection diff on every playback tick.
private struct MiniPlayerProgressBar: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let duration: TimeInterval
    /// App 强调色（读环境值；根注入见 ContentView）
    @Environment(\.appAccentColor) private var accentColor

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        let value = progress.playbackTime / duration
        return CGFloat(max(0, min(1, value.isFinite ? value : 0)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))

            Rectangle()
                .fill(accentColor)
                .scaleEffect(x: fraction, y: 1, anchor: .leading)
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(height: 2)
        .clipped()
    }
}
