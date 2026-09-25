//
//  MacLibraryView+Content.swift
//  QQPlayer
//
//  `MacLibraryView` 的内容区与播放动作（2026-09-21 从 `MacLibraryView.swift` 纯搬家，零行为/UI 变化）：
//  内容列表四态（歌曲/喜欢/专辑/歌手/歌单）本体，以及列表行点击后的播放与跳转动作
//  （同片理由：这些动作只被本片内容列表的行回调调用）。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//
import SwiftUI

extension MacLibraryView {
    // MARK: - Content

    @ViewBuilder
    /// 分片：跨文件可见（原 private）
    var contentList: some View {
        if !debouncedSearchText.isEmpty {
            MacSearchResultsView(
                results: searchResults,
                activeTrackId: player.currentTrack?.stableId,
                isPlaying: player.isPlaying,
                artistNameResolver: resolveArtistName,
                onPlaySong: playSearchSongs,
                onPlayAlbum: playAlbum,
                onPlayArtist: playArtist,
                onOpenPlaylist: openPlaylist
            )
        } else {
            switch section {
            case .tracks:
                MacTrackListView(
                    tracks: tracks,
                    activeTrackId: player.currentTrack?.stableId,
                    isPlaying: player.isPlaying,
                    artistNameResolver: resolveArtistName,
                    onPlay: playFromTrackList,
                    onSelect: { selectedTrackId = $0.stableId },
                    playlistId: nil,
                    onPlayNext: { player.insertNext($0) },
                    onShowArtist: showArtist(for:),
                    onShowAlbum: showAlbum(for:)
                )
            case .likedSongs:
                MacTrackListView(
                    tracks: likedTracks,
                    activeTrackId: player.currentTrack?.stableId,
                    isPlaying: player.isPlaying,
                    artistNameResolver: resolveArtistName,
                    onPlay: playLikedTracks,
                    onSelect: { selectedTrackId = $0.stableId },
                    playlistId: nil,
                    onPlayNext: { player.insertNext($0) },
                    onShowArtist: showArtist(for:),
                    onShowAlbum: showAlbum(for:)
                )
            case .albums:
                MacAlbumGridView(
                    albums: albums,
                    selectedAlbum: $selectedAlbum,
                    albumTracks: $albumTracks,
                    artistNameResolver: resolveArtistName,
                    onPlayAlbum: playAlbum,
                    showAlbumSheet: $showAlbumSheet
                )
            case .artists:
                MacArtistListView(
                    artists: artists,
                    selectedArtist: $selectedArtist,
                    artistTracks: $artistTracks,
                    artistNameResolver: resolveArtistName,
                    onPlayArtist: playArtist,
                    showArtistSheet: $showArtistSheet
                )
            case .playlists:
                MacPlaylistListView(
                    playlists: playlists,
                    onPlay: openPlaylist
                )
            }
        }
    }

    // MARK: - Playback actions

    private func playFromTrackList(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    private func playLikedTracks(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    /// search anything 设置行：打开设置窗口并定位到分类（有项时滚到该项 + 高亮）
    /// 分片：跨文件可见（原 private）
    func openSettingsRow(_ match: MacSettingsCatalog.Match) {
        // 先开窗再投递定位请求：窗口没建好时通知没有订阅者，由 MacSettingsRouter.pending 兜底
        openSettings()
        MacSettingsRouter.open(.init(category: match.category, itemID: match.itemID))
    }

    /// 分片：跨文件可见（原 private）
    func playSearchSongs(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    /// 分片：跨文件可见（原 private）
    func performSearch(query: String) {
        searchTask?.cancel()

        guard !query.isEmpty else {
            searchResults = MacSearchResults()
            return
        }

        searchTask = Task {
            // Normalize query for better matching (same as iOS SearchView).
            let normalizedQuery = query
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)

            // Run database queries off the main thread.
            let results = await Task.detached(priority: .userInitiated) {
                var songs: [Track] = []
                var artists: [Artist] = []
                var albums: [Album] = []
                var playlists: [Playlist] = []

                do {
                    songs = try LibraryReads.searchTracks(query: normalizedQuery, limit: 50)
                    artists = try LibraryReads.searchArtists(query: normalizedQuery, limit: 20)
                    albums = try LibraryReads.searchAlbums(query: normalizedQuery, limit: 30)
                    playlists = try LibraryReads.searchPlaylists(query: normalizedQuery, limit: 15)
                } catch {
                    AppLog.error(.ui, "❌ macOS search failed: \(error)")
                }

                return MacSearchResults(songs: songs, artists: artists, albums: albums, playlists: playlists)
            }.value

            guard !Task.isCancelled else { return }

            // 渲染期只读（MacSearchAlbumRow / MacArtistRow / MacPlaylistRow 的 body 只查缓存）
            // → 快照覆盖不到的 id 在**结果产出后**（非渲染期）显式补齐，补齐后再发布结果，不闪 0。
            // 2026-09-25：旧的「缓存未命中就同步写被观察状态」已删除（渲染期写入 → 表格重入更新死循环）。
            let facts = libraryFacts
            await facts.ensureFacts(
                albumIds: results.albums.compactMap(\.id),
                artistIds: results.artists.compactMap(\.id),
                playlistIds: results.playlists.compactMap(\.id)
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.searchResults = results
            }
        }
    }

    /// 歌曲右键「进歌手」：切到歌手分组并打开对应歌手详情
    private func showArtist(for track: Track) {
        guard let artistId = track.artistId else { return }
        do {
            artistTracks = try LibraryReads.tracks(artistId: artistId)
        } catch {
            AppLog.error(.ui, "❌ showArtist tracks failed: \(error)")
        }
        selectedArtist = artists.first { $0.id == artistId }
        guard selectedArtist != nil else { return }
        section = .artists
        showArtistSheet = true
    }

    /// 歌曲右键「进专辑」：切到专辑分组并打开对应专辑详情
    private func showAlbum(for track: Track) {
        guard let albumId = track.albumId else { return }
        do {
            albumTracks = try LibraryReads.tracks(albumId: albumId)
        } catch {
            AppLog.error(.ui, "❌ showAlbum tracks failed: \(error)")
        }
        selectedAlbum = albums.first { $0.id == albumId }
        guard selectedAlbum != nil else { return }
        section = .albums
        showAlbumSheet = true
    }

    /// 分片：跨文件可见（原 private）
    func playAlbum(_ album: Album, tracks albumTracks: [Track]) {
        guard let first = albumTracks.first else { return }
        Task {
            await player.playTrack(first, queue: albumTracks)
        }
    }

    /// 分片：跨文件可见（原 private）
    func playArtist(_ artist: Artist, tracks artistTracks: [Track]) {
        guard let first = artistTracks.first else { return }
        Task {
            await player.playTrack(first, queue: artistTracks)
        }
    }

    private func openPlaylist(_ playlist: Playlist) {
        do {
            let items = try LibraryReads.playlistItems(playlistId: playlist.id ?? 0)
            let stableIds = items.map { $0.trackStableId }
            let tracks = try LibraryReads.tracksPreservingOrder(stableIds: stableIds)
            guard let first = tracks.first else { return }
            Task {
                await player.playTrack(first, queue: tracks)
            }
        } catch {
            AppLog.error(.ui, "❌ openPlaylist failed: \(error)")
        }
    }

    /// 分片：跨文件可见（原 private）
    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
}
