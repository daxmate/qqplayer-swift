//
//  MacPlayerView.swift
//  QQPlayer
//
//  macOS player detail page: artwork, track info, playback controls, a
//  draggable progress bar, and a lyrics panel with karaoke controls.
//  QQPlayerMac target only.
//

import SwiftUI

struct MacPlayerView: View {
    let track: Track?
    let artistName: String?
    let isPlaying: Bool
    let duration: TimeInterval
    let playbackTime: TimeInterval
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var artwork: ArtworkImage?
    @State private var artworkTrackId: String?
    @State private var dragTime: TimeInterval?
    @State private var isDragging = false
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var showLyrics = true
    @State private var favoriteIds: Set<String> = []
    @State private var sleepTimerEndDate: Date?
    @State private var sleepTimerTask: Task<Void, Never>?
    @ObservedObject private var karaoke = KaraokeController.shared
    @ObservedObject private var player = PlayerEngine.shared

    /// 播放控制按钮可见性（设置页开关，对齐 iOS 默认：歌词按钮显示、睡眠定时器隐藏）
    @State private var showLyricsButton: Bool = DeleteSettings.load().showLyricsButton
    @State private var showSleepTimerButton: Bool = DeleteSettings.load().showSleepTimerButton

    var body: some View {
        VStack(spacing: 0) {
            // 跟唱大画面：隐藏播放区，把空间全部让给歌词区（决策上收 MacPlaybackGate，有测试）
            if !MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: karaoke.isKaraokeOn) {
                playerSection
            }
            if showLyrics || karaoke.isKaraokeOn {
                Divider()
                MacLyricsView(
                    lyrics: lyrics,
                    currentTime: playbackTime,
                    isLoading: lyricsLoading,
                    onClose: {
                        // 决策上收 MacPlaybackGate.lyricsCloseAction（有测试）
                        switch MacPlaybackGate.lyricsCloseAction(isKaraokeOn: karaoke.isKaraokeOn) {
                        case .exitKaraokeKeepPanel:
                            karaoke.toggleKaraokeMode()
                        case .closePanel:
                            showLyrics = false
                        }
                    }
                )
                .frame(maxHeight: MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: karaoke.isKaraokeOn) ? .infinity : 330)
                .frame(height: MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: karaoke.isKaraokeOn) ? nil : 330)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: karaoke.isKaraokeOn)
        .onChange(of: karaoke.isKaraokeOn) { isOn in
            // 进入跟唱：确保歌词面板可见（大画面依赖歌词区；决策上收 MacPlaybackGate）
            if MacPlaybackGate.shouldAutoShowLyrics(isKaraokeOn: isOn) {
                showLyrics = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FavoritesChanged"))) { _ in
            // 收藏在别处变更（列表心形/右键菜单）后同步当前曲目的心形状态
            favoriteIds = Set((try? AppCoordinator.shared.getFavorites()) ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            // 设置页改了歌词/睡眠定时器开关后同步按钮可见性
            let settings = DeleteSettings.load()
            showLyricsButton = settings.showLyricsButton
            showSleepTimerButton = settings.showSleepTimerButton
        }
        .task(id: track?.stableId) {
            guard let track else {
                artwork = nil
                artworkTrackId = nil
                lyrics = nil
                favoriteIds = []
                // 跟唱：无曲目时清空歌词注入 + 清 AB（对齐 iOS PlayerView 切歌语义）
                KaraokeController.shared.setLyrics([])
                KaraokeController.shared.resetForNewTrack()
                return
            }
            let art = await ArtworkManager.shared.getArtwork(for: track)
            artwork = art
            artworkTrackId = track.stableId
            // 切歌时刷新当前曲目的收藏状态
            favoriteIds = Set((try? AppCoordinator.shared.getFavorites()) ?? [])

            // 歌词：优先缓存/本地，在线搜索失败不阻塞 UI（跟 iOS 语义一致）
            lyricsLoading = true
            lyrics = await LyricsManager.shared.getLyrics(for: track)
            // 跟唱：歌词行注入（句末自动停/单句循环/AB/上一句下一句依赖；对齐 iOS PlayerView:829）
            KaraokeController.shared.setLyrics(lyrics?.syncedLyrics ?? [])
            lyricsLoading = false
        }
    }

    // MARK: - Player section

    private var playerSection: some View {
        VStack(spacing: 16) {
            Spacer()

            // Artwork
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 240, height: 240)
                    .shadow(radius: 8, y: 4)

                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 240, height: 240)

            // Track info
            VStack(spacing: 4) {
                Text(track?.title ?? "not_playing".localized)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(artistName ?? "")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Progress bar
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isDragging ? (dragTime ?? playbackTime) : playbackTime },
                        set: { dragTime = $0 }
                    ),
                    in: 0 ... max(duration, 0.01),
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing, let dragTime {
                            onSeek(dragTime)
                            self.dragTime = nil
                        }
                    }
                )
                .disabled(track == nil || duration <= 0)

                HStack {
                    Text(MacTimeFormat.format(isDragging ? (dragTime ?? playbackTime) : playbackTime))
                    Spacer()
                    Text(MacTimeFormat.format(duration))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            }
            .frame(maxWidth: 420)

            // Controls
            HStack(spacing: 24) {
                Button(action: onPrevious) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)
                .keyboardShortcut(.space)

                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Divider().frame(height: 24)

                // 播放顺序四态：顺序 → 随机 → 循环列表 → 单曲循环
                // （shuffle 分支必须走 toggleShuffle()：保存/恢复 originalQueue，测试锁定）
                Button {
                    player.cyclePlaybackOrderMode()
                } label: {
                    Image(systemName: playOrderIcon)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(isPlayOrderActive ? .accentColor : .secondary)
                .help(playOrderTitle)

                // 当前曲目收藏（红心）
                Button {
                    guard let track else { return }
                    try? AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
                } label: {
                    Image(systemName: currentTrackIsFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(currentTrackIsFavorite ? .pink : .secondary)
                .disabled(track == nil)
                .help(currentTrackIsFavorite ? "remove_from_liked_songs".localized : "add_to_liked_songs".localized)

                // 睡眠定时器：15/30/45/60 分钟，激活后可取消（切歌不清除）
                // 默认隐藏（对齐 iOS showSleepTimerButton=false），设置页可开启
                if showSleepTimerButton {
                    Menu {
                        Button(Localized.sleepTimer15Minutes) { startSleepTimer(minutes: 15) }
                        Button(Localized.sleepTimer30Minutes) { startSleepTimer(minutes: 30) }
                        Button(Localized.sleepTimer45Minutes) { startSleepTimer(minutes: 45) }
                        Button(Localized.sleepTimer60Minutes) { startSleepTimer(minutes: 60) }

                        if sleepTimerEndDate != nil {
                            Divider()
                            Button(Localized.cancelSleepTimer, role: .destructive) { cancelSleepTimer() }
                        }
                    } label: {
                        Image(systemName: sleepTimerEndDate == nil ? "timer" : "timer.circle.fill")
                            .font(.system(size: 16))
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundColor(sleepTimerEndDate == nil ? .secondary : .accentColor)
                    .help("sleep_timer".localized)
                }

                Divider().frame(height: 24)

                // 跟唱模式开关（双击歌词行的 iOS 语义在 Mac 上没有，给显式按钮）
                Button {
                    karaoke.toggleKaraokeMode()
                } label: {
                    Image(systemName: karaoke.isKaraokeOn ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(karaoke.isKaraokeOn ? .accentColor : .secondary)
                .disabled(track == nil)
                .help("karaoke_mode_help".localized)

                // 歌词面板开关（默认显示，设置页可隐藏）
                if showLyricsButton {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLyrics.toggle()
                        }
                    } label: {
                        Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(showLyrics ? .accentColor : .secondary)
                    .help("toggle_lyrics_help".localized)
                }
            }

            Spacer()
        }
        .padding(.top, 24)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Playback order

    private var playOrderMode: PlaybackOrderMode {
        player.playbackOrderMode
    }

    private var playOrderIcon: String {
        switch playOrderMode {
        case .sequential: return "arrow.right.to.line"
        case .shuffle: return "shuffle"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        }
    }

    private var playOrderTitle: String {
        switch playOrderMode {
        case .sequential: return Localized.playOrderSequential
        case .shuffle: return Localized.playOrderShuffle
        case .repeatAll: return Localized.playOrderRepeatAll
        case .repeatOne: return Localized.playOrderRepeatOne
        }
    }

    private var isPlayOrderActive: Bool {
        playOrderMode != .sequential
    }

    // MARK: - Favorite

    private var currentTrackIsFavorite: Bool {
        guard let track else { return false }
        return favoriteIds.contains(track.stableId)
    }

    // MARK: - Sleep timer

    private func startSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate

        sleepTimerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            player.pause()
            sleepTimerEndDate = nil
            sleepTimerTask = nil
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }
}
