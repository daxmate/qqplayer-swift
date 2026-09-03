//
//  MacLibraryView.swift
//  QQPlayer
//
//  macOS main window: NavigationSplitView with a library sidebar, a track
//  list (or album/artist/playlist grid), and the player detail page.
//  QQPlayerMac target only — kept out of the iOS target via pbxproj
//  membership exceptions.
//

import AppKit
import Combine
import SwiftUI

enum MacLibrarySection: String, CaseIterable, Identifiable {
    case tracks = "songs"
    case likedSongs = "liked_songs"
    case albums = "albums"
    case artists = "artists"
    case playlists = "playlists"

    var id: String { rawValue }

    /// Localized sidebar title (rawValue is a localization key).
    var title: String { rawValue.localized }

    var icon: String {
        switch self {
        case .tracks: return "music.note.list"
        case .likedSongs: return "heart.fill"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .playlists: return "list.bullet.rectangle"
        }
    }
}

struct MacLibraryView: View {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var indexer = LibraryIndexer.shared
    @StateObject private var progress = PlayerEngine.shared.progress

    @State private var section: MacLibrarySection = .tracks
    @State private var tracks: [Track] = []
    @State private var likedTracks: [Track] = []
    /// 外观三态（工具栏月亮按钮循环切换，初值含旧 forceDarkMode 迁移推导）
    @State private var theme: AppearanceTheme = AppearanceTheme.resolved(
        raw: DeleteSettings.load().appearanceTheme,
        forceDarkMode: DeleteSettings.load().forceDarkMode
    )
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var playlists: [Playlist] = []
    @State private var loadError: String?
    @State private var selectedAlbum: Album?
    @State private var selectedArtist: Artist?
    @State private var albumTracks: [Track] = []
    @State private var artistTracks: [Track] = []
    @State private var selectedTrackId: String?
    /// 专辑/歌手详情 sheet 开关（上收自 MacAlbumGridView/MacArtistListView，
    /// 支持歌曲右键「进专辑/进歌手」外部触发）
    @State private var showAlbumSheet = false
    @State private var showArtistSheet = false
    /// 新功能通告（启动时版本变化弹一次，对齐 iOS ContentView 挂载）
    @State private var showWhatsNew = false
    /// 曲库文件夹在扫描中变更 → 索引结束后自动补扫
    @State private var rescanWhenIdle = false
    /// 索引中增量刷新任务（防抖）
    @State private var libraryRefreshTask: Task<Void, Never>?

    // Search state (sidebar search field + grouped results)
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchResults = MacSearchResults()
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            contentList
                .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 600)
        } detail: {
            MacPlayerView(
                track: player.currentTrack,
                artistName: currentArtistName,
                isPlaying: player.isPlaying,
                duration: player.duration,
                playbackTime: progress.playbackTime,
                onPlayPause: togglePlayPause,
                onNext: { Task { await player.nextTrack(autoplay: true) } },
                onPrevious: { Task { await player.previousTrack(autoplay: true) } },
                onSeek: { time in
                    Task { await player.seek(to: time) }
                }
            )
        }
        .navigationTitle("QQPlayer")
        .frame(minWidth: 1000, minHeight: 640)
        .toolbar {
            ToolbarItem {
                Button {
                    cycleTheme()
                } label: {
                    Image(systemName: themeIconName)
                }
                .help(Localized.appearanceTheme)
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                WhatsNewStore.shared.markSeen(WhatsNewContent.currentVersion)
                showWhatsNew = false
            })
        }
        .task {
            reloadLibrary()
            if !indexer.isIndexing {
                indexer.start()
            }
            player.ensureRemoteCommandsSetup()
            // 启动即应用全局外观（NSApp.appearance，设置窗口等所有窗口跟随）
            applyMacAppearance()
            // 新功能通告：当前版本未读过则弹（升级场景）；全新安装也会弹一次
            if WhatsNewStore.shared.shouldShowCurrent() {
                showWhatsNew = true
            }
        }
        .onReceive(indexer.$isIndexing) { isIndexing in
            if !isIndexing {
                reloadLibrary()
                if !debouncedSearchText.isEmpty {
                    performSearch(query: debouncedSearchText)
                }
                // 曲库文件夹在扫描中变更：索引结束后补一次重扫
                if rescanWhenIdle {
                    rescanWhenIdle = false
                    indexer.start()
                }
            }
        }
        .onReceive(indexer.$tracksFound) { _ in
            // 索引中增量刷新：新解析完成的歌陆续出现在列表，不让用户干等
            // （防抖 1.5s，避免每首歌都全量 reload）
            libraryRefreshTask?.cancel()
            guard indexer.isIndexing else { return }
            libraryRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                reloadLibrary()
            }
        }
        .onChange(of: searchText) { newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
                performSearch(query: newValue)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            searchTask?.cancel()
            libraryRefreshTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FavoritesChanged"))) { _ in
            // 收藏变化后刷新“我喜欢的音乐”列表（含正在展示时的实时移除）
            reloadLikedTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            // 设置页改了主题/强调色后同步工具栏按钮状态（双向同步）
            let settings = DeleteSettings.load()
            theme = AppearanceTheme.resolved(
                raw: settings.appearanceTheme,
                forceDarkMode: settings.forceDarkMode
            )
            applyMacAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaylistsChanged"))) { _ in
            // 歌单管理（新建/重命名/删除/增删曲目）后刷新歌单列表与自动歌单计数
            reloadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            // iOS 同款标准通知：曲目删除/移动后整库重载（与 PlaylistsChanged 双通道，
            // 2026-09-02 A4 用户反馈删除后曲库不刷新——deleteTrack 后必须重拉 tracks）
            reloadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryFoldersChanged"))) { _ in
            // 设置页「音乐库」添加/移除文件夹后重扫曲库（reconcile 自动清理旧目录曲目）。
            // 若正在扫描，start() 会被 guard 吞掉 → 标记等索引结束自动补扫。
            MacScanLogger.log("LibraryFoldersChanged received, isIndexing=\(indexer.isIndexing)")
            reloadLibrary()
            if indexer.isIndexing {
                rescanWhenIdle = true
            } else {
                indexer.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryScanCriteriaChanged)) { _ in
            // 设置页「文件类型」改动后重扫曲库（取消的格式由 reconcile 收尾移除，
            // 与 LibraryFoldersChanged 同款排队语义：扫描中则标记等索引结束补扫）。
            MacScanLogger.log("libraryScanCriteriaChanged received, isIndexing=\(indexer.isIndexing)")
            reloadLibrary()
            if indexer.isIndexing {
                rescanWhenIdle = true
            } else {
                indexer.start()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            MacSearchField(text: $searchText)
            List(MacLibrarySection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if indexer.isIndexing {
                    ProgressView(value: indexer.indexingProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(String(format: "indexing_progress".localized, indexer.tracksFound))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        // 手动刷新语义收紧（2026-09-03 复查 A4 反馈）：先立即用 DB
                        // 真值重载列表，再排队/启动扫描。之前只 start()——扫描被占用
                        // 或启动被吞时列表不重读 DB，用户观感"点刷新没反应"；若曲库
                        // 数据已被其它路径改掉（删除/回收站/iCloud），点一下立刻对齐。
                        reloadLibrary()
                        // 2026-09-02 A4 修复：dataless 自动补扫在跑时 start() 会被
                        // guard !isIndexing 静默吞掉 → 手动刷新"没反应"。改为排队：
                        // 扫描结束后由 onReceive(isIndexing) 补一次重扫
                        if indexer.isIndexing {
                            MacScanLogger.log("手动刷新时正在扫描，标记排队（rescanWhenIdle）")
                            rescanWhenIdle = true
                        } else {
                            indexer.start()
                        }
                    } label: {
                        Label("refresh_library".localized, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentList: some View {
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

    // MARK: - Data

    private func reloadLibrary() {
        do {
            tracks = try DatabaseManager.shared.getAllTracks()
            albums = try DatabaseManager.shared.getAllAlbums()
            artists = try DatabaseManager.shared.getAllArtists()
            playlists = try DatabaseManager.shared.getAllPlaylists()
            loadError = nil
        } catch {
            loadError = "load_library_failed".localized(with: error.localizedDescription)
            print("❌ macOS reloadLibrary failed: \(error)")
        }
        reloadLikedTracks()
    }

    private func reloadLikedTracks() {
        do {
            let favoriteIds = try AppCoordinator.shared.getFavorites()
            likedTracks = tracks.filter { favoriteIds.contains($0.stableId) }
        } catch {
            print("❌ macOS reloadLikedTracks failed: \(error)")
        }
    }

    /// 工具栏月亮按钮：三态循环 system → dark → light → system。
    private func cycleTheme() {
        let next: AppearanceTheme
        switch theme {
        case .system: next = .dark
        case .dark: next = .light
        case .light: next = .system
        }
        theme = next
        var settings = DeleteSettings.load()
        settings.appearanceTheme = next.rawValue
        settings.forceDarkMode = next == .dark
        settings.save()
    }

    private var themeIconName: String {
        switch theme {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    /// 全局外观：NSApp.appearance 控制所有窗口（主窗/设置窗/sheet）立即生效，
    /// system = nil 跟随系统立即恢复。不用 .preferredColorScheme（只作用于
    /// 挂载视图，且从 .dark 切回 nil 时系统不重新解析——2026-09-02 用户实测）。
    private func applyMacAppearance() {
        MacAppearance.apply(theme: theme)
    }

    private func resolveArtistName(for track: Track) -> String? {
        try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }

    private var currentArtistName: String? {
        guard let track = player.currentTrack else { return nil }
        return resolveArtistName(for: track)
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

    private func playSearchSongs(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    private func performSearch(query: String) {
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
                    songs = try DatabaseManager.shared.searchTracks(query: normalizedQuery, limit: 50)
                    artists = try DatabaseManager.shared.searchArtists(query: normalizedQuery, limit: 20)
                    albums = try DatabaseManager.shared.searchAlbums(query: normalizedQuery, limit: 30)
                    playlists = try DatabaseManager.shared.searchPlaylists(query: normalizedQuery, limit: 15)
                } catch {
                    print("❌ macOS search failed: \(error)")
                }

                return MacSearchResults(songs: songs, artists: artists, albums: albums, playlists: playlists)
            }.value

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
            artistTracks = try DatabaseManager.shared.getTracksByArtistId(artistId)
        } catch {
            print("❌ showArtist tracks failed: \(error)")
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
            albumTracks = try DatabaseManager.shared.getTracksByAlbumId(albumId)
        } catch {
            print("❌ showAlbum tracks failed: \(error)")
        }
        selectedAlbum = albums.first { $0.id == albumId }
        guard selectedAlbum != nil else { return }
        section = .albums
        showAlbumSheet = true
    }

    private func playAlbum(_ album: Album, tracks albumTracks: [Track]) {
        guard let first = albumTracks.first else { return }
        Task {
            await player.playTrack(first, queue: albumTracks)
        }
    }

    private func playArtist(_ artist: Artist, tracks artistTracks: [Track]) {
        guard let first = artistTracks.first else { return }
        Task {
            await player.playTrack(first, queue: artistTracks)
        }
    }

    private func openPlaylist(_ playlist: Playlist) {
        do {
            let items = try DatabaseManager.shared.getPlaylistItems(playlistId: playlist.id ?? 0)
            let stableIds = items.map { $0.trackStableId }
            let tracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(stableIds)
            guard let first = tracks.first else { return }
            Task {
                await player.playTrack(first, queue: tracks)
            }
        } catch {
            print("❌ openPlaylist failed: \(error)")
        }
    }

    private func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
}
