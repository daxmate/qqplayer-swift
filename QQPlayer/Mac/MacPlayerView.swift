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
    @State private var favoriteIds: Set<String> = []
    @State private var sleepTimerEndDate: Date?
    @State private var sleepTimerTask: Task<Void, Never>?
    @ObservedObject private var karaoke = KaraokeController.shared
    @ObservedObject private var player = PlayerEngine.shared

    /// 播放控制按钮可见性（设置页开关，对齐 iOS 默认：睡眠定时器隐藏）
    @State private var showSleepTimerButton: Bool = DeleteSettings.load().showSleepTimerButton
    /// 歌词搜索 sheet（手动指定歌词）
    @State private var showLyricsSearch = false
    /// 播放队列面板（B 组队列排序持久化：可拖排/删除/点行跳转，重排即持久化）
    @State private var showQueuePanel = false

    var body: some View {
        VStack(spacing: 0) {
            // 跟唱大画面：隐藏播放区，把空间全部让给歌词区（决策上收 MacPlaybackGate，有测试）
            if !MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: karaoke.isKaraokeOn) {
                playerSection
            }
            // 歌词常驻显示（2026-09-02 用户拍板：歌词是本 APP 第一重要功能，不提供隐藏入口）
            Divider()
            MacLyricsView(
                lyrics: lyrics,
                currentTime: playbackTime,
                isLoading: lyricsLoading,
                onLyricsSearch: {
                    showLyricsSearch = true
                }
            )
            .frame(maxHeight: MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: karaoke.isKaraokeOn) ? .infinity : 330)
            .frame(height: MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: karaoke.isKaraokeOn) ? nil : 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLyricsSearch) {
            if let track = player.currentTrack {
                MacLyricsSearchView(
                    track: track,
                    onClose: { showLyricsSearch = false },
                    onApply: { newLyrics in
                        // 应用搜索结果：更新歌词显示 + 跟唱行注入（nil = 恢复自动）
                        lyrics = newLyrics
                        KaraokeController.shared.setLyrics(newLyrics?.syncedLyrics ?? [])
                    }
                )
            }
        }
        .sheet(isPresented: $showQueuePanel) {
            MacQueuePanelView(player: player)
        }
        .animation(.easeInOut(duration: 0.25), value: karaoke.isKaraokeOn)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FavoritesChanged"))) { _ in
            // 收藏在别处变更（列表心形/右键菜单）后同步当前曲目的心形状态
            favoriteIds = Set((try? AppCoordinator.shared.getFavorites()) ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            // 设置页改了睡眠定时器开关后同步按钮可见性
            let settings = DeleteSettings.load()
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

                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

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

                // 播放队列（B 组队列排序持久化）：打开可拖排/删除/跳转的面板。
                // 只有当前在播且非随机时队列面板才有意义——随机模式下播放顺序
                // 由 shuffle 决定（isQueueReorderable=false，面板内提示）。
                Button {
                    showQueuePanel = true
                } label: {
                    Image(systemName: "list.number")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(track == nil || player.playbackQueue.isEmpty)
                .help("playing_queue".localized)

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

// MARK: - 播放队列面板（B 组队列排序持久化，2026-09-03）

/// macOS 播放队列管理：显示当前队列，支持拖拽重排 / 移除（当前播放项除外）/
/// 点行跳转。每次变更经 PlayerEngine.moveQueueItems/removeQueueItems/jumpToQueueIndex
/// 立即持久化（savePlayerState 落盘 queueTrackIds），重启 restoreUIStateOnly 恢复——
/// web 版 persistQueueOrder/applyQueueOrder 语义的 Swift 端形态（队列=播放引擎队列，
/// 启动恢复 = 现成 QQPlayerState 恢复链路）。
private struct MacQueuePanelView: View {
    @ObservedObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var header: some View {
        HStack {
            Text(Localized.playingQueue)
                .font(.headline)
            Spacer()
            Button("close".localized) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if player.playbackQueue.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text(Localized.noSongsInQueue)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if !player.isQueueReorderable {
                    Text(Localized.queueShuffleDisabledHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                List {
                    ForEach(Array(player.playbackQueue.enumerated()), id: \.element.stableId) { index, track in
                        row(for: track, at: index)
                    }
                    // macOS List：onMove 直接支持鼠标拖拽重排（无需 iOS EditMode）
                    .onMove(perform: player.moveQueueItems)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(for track: Track, at index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .frame(width: 14)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if let artist = try? DatabaseManager.shared.getArtistDisplayName(
                    forTrackStableId: track.stableId,
                    fallbackArtistId: track.artistId
                ) {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            if !isCurrent {
                Button {
                    player.removeQueueItems(at: IndexSet(integer: index))
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(Localized.removeFromQueue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCurrent else { return }
            Task { await player.jumpToQueueIndex(index) }
        }
    }
}
