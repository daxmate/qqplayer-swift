//
//  PlayerView+TitleAndLyrics.swift
//  QQPlayer
//
//  播放页**标题 / 歌手 / 歌词区**：标题与歌手按钮（跳专辑 / 艺术家）、收藏与入歌单按钮、
//  标题歌手元数据缓存、小歌词窗（点击 / 左右滑 / 双击手势）、空态视图，
//  以及歌词加载与收藏切换。
//
//  2026-09-21 从 PlayerView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Player/PlayerView.swift                   — 视图壳：stored property + body 装配
//    · Views/Player/PlayerView+Artwork.swift           — 封面区视图 / 手势 / 封面加载
//    · Views/Player/PlayerView+PlaybackSupport.swift   — 睡眠定时、曲库加载、AirPlay
//
// target: ios-only（PlayerView 分片：消费端全在 iOS；Mac 侧为 MacPlayerView）
//
import AVKit
import SwiftUI

extension PlayerView {
    // MARK: - Title and Artist Section

    /// 分片：跨文件可见（原 private）
    func titleAndArtistSection(track: Track) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.space16) {
            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                titleButton(track: track)
                artistButton(track: track)
            }

            Spacer()

            HStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
                likeButton
                addToPlaylistButton
            }
        }
        .padding(.horizontal, DesignTokens.space8)
    }

    private func titleButton(track: Track) -> some View {
        Group {
            if let album = trackAlbum {
                Button(action: {
                    let userInfo = ["album": album, "allTracks": allTracks] as [String: Any]
                    NotificationCenter.default.post(name: .navigateToAlbumFromPlayer, object: nil, userInfo: userInfo)
                }) {
                    Text(track.displayTitle)
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text(track.displayTitle)
                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func artistButton(track: Track) -> some View {
        Group {
            if let artist = trackArtist {
                Button(action: {
                    let userInfo = ["artist": artist, "allTracks": allTracks] as [String: Any]
                    NotificationCenter.default.post(name: .navigateToArtistFromPlayer, object: nil, userInfo: userInfo)
                }) {
                    Text(trackArtistDisplayName ?? ArtistNameNormalizer.displayName(artist.name))
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .caption : .subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    /// 标题/歌手按钮元数据缓存（切歌/首次出现时加载一次，替代 body 求值中同步 DB 读）
    /// 分片：跨文件可见（原 private）
    func loadTrackMetadata() {
        guard let currentTrack = playerEngine.currentTrack else {
            trackAlbum = nil
            trackArtist = nil
            trackArtistDisplayName = nil
            return
        }

        if let albumId = currentTrack.albumId {
            trackAlbum = try? LibraryReads.album(id: albumId)
        } else {
            trackAlbum = nil
        }

        if let artistId = currentTrack.artistId {
            let artist = try? LibraryReads.artist(id: artistId)
            trackArtist = artist
            trackArtistDisplayName = artist.map {
                (try? LibraryReads.artistDisplayName(forTrackStableId: currentTrack.stableId, fallbackArtistId: artistId)) ?? ArtistNameNormalizer.displayName($0.name)
            }
        } else {
            trackArtist = nil
            trackArtistDisplayName = nil
        }
    }

    private var likeButton: some View {
        Button(action: {
            toggleFavorite()
        }) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(isFavorite ? .red : .primary)
        }
    }

    private var addToPlaylistButton: some View {
        Button(action: {
            showPlaylistDialog = true
        }) {
            Image(systemName: "plus.circle")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Mini Lyrics Section

    // 封面下方的小歌词窗口：三行（上一句/当前句/下一句），当前句放大 + 主题色
    // 点击/左滑进入全屏歌词，右滑打开歌词搜索页（从左滑入）
    /// 分片：跨文件可见（原 private）
    var lyricMiniSection: some View {
        LyricMiniSection(
            lyrics: currentLyrics,
            isLoading: isLoadingLyrics
        )
        .padding(.horizontal, DesignTokens.space8)
        // 点击进全屏歌词页（普通视图 + onTapGesture：与 DragGesture 仲裁标准，
        // 不用 Button——Button 手势优先级高，快速右滑会误触发 tap 直接进歌词页）
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.26)) {
                showLyricsSheet = true
            }
            if currentLyrics == nil && !isLoadingLyrics {
                loadLyrics()
            }
        }
        // 左滑 → 全屏歌词页（从右侧滑入）；右滑 → 歌词搜索页（从左侧滑入）
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if MiniLyricSwipeGesture.shouldOpenLyricsSheet(
                        translation: value.translation.width,
                        predictedTranslation: value.predictedEndTranslation.width
                    ) {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSheet = true
                        }
                        if currentLyrics == nil && !isLoadingLyrics {
                            loadLyrics()
                        }
                    } else if MiniLyricSwipeGesture.shouldOpenLyricsSearch(
                        translation: value.translation.width,
                        predictedTranslation: value.predictedEndTranslation.width
                    ) {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSearch = true
                        }
                    }
                }
        )
        // 双击：进全屏歌词页并开启跟唱（跟唱只发生在全屏歌词页，小窗口空间小不做控制条）。
        // 与单击（仅进全屏歌词页）共存：双击优先，单击等双击窗口判定失败后触发（~0.3s 延迟可接受）；
        // 与左/右滑 DragGesture 也不冲突（双击无位移，拖动判失败后滑动手势接管）。
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    karaoke.setKaraokeOn(true)
                    withAnimation(.easeOut(duration: 0.26)) {
                        showLyricsSheet = true
                    }
                    if currentLyrics == nil && !isLoadingLyrics {
                        loadLyrics()
                    }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            withAnimation(.easeOut(duration: 0.26)) {
                showLyricsSheet = true
            }
            if currentLyrics == nil && !isLoadingLyrics {
                loadLyrics()
            }
        }
    }

    /// 分片：跨文件可见（原 private）
    var emptyStateView: some View {
        VStack {
            Image(systemName: "music.note")
                .font(.system(size: DesignTokens.font60))
                .foregroundColor(.secondary)

            Text(Localized.noTrackSelected)
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    /// 分片：跨文件可见（原 private）
    func loadLyrics() {
        guard let currentTrack = playerEngine.currentTrack else { return }

        // 捕获发起时的歌曲身份：切歌后旧请求完成必须丢弃（网易云歌词耗时 2-10s，
        // 期间切歌会让旧结果覆盖新歌歌词，跟唱行号也随之错乱），与 loadCurrentArtwork 同款防护
        let trackId = currentTrack.stableId
        isLoadingLyrics = true

        Task {
            let lyrics = await services.lyricsManager.getLyrics(for: currentTrack)

            await MainActor.run {
                // 切歌后当前歌曲已变，丢弃旧请求结果，不写任何状态（isLoadingLyrics 由新任务接管）
                guard playerEngine.currentTrack?.stableId == trackId else { return }
                currentLyrics = lyrics
                // 跟唱模式歌词注入（LyricsView / 控制条共用 PlayerView 的 currentLyrics 数据源）
                karaoke.setLyrics(lyrics?.syncedLyrics ?? [])
                isLoadingLyrics = false
            }
        }
    }

    private func toggleFavorite() {
        guard let currentTrack = playerEngine.currentTrack else { return }

        do {
            try appCoordinator.toggleFavorite(trackStableId: currentTrack.stableId)
            isFavorite.toggle()
        } catch {
            AppLog.error(.ui, "Failed to toggle favorite: \(error)")
        }
    }
}
