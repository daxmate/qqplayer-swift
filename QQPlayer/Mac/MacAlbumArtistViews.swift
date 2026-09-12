//
//  MacAlbumArtistViews.swift
//  QQPlayer
//
//  macOS album grid, artist list, and playlist list (content columns for the
//  专辑 / 艺术家 / 播放列表 sections). QQPlayerMac target only.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Albums

struct MacAlbumGridView: View {
    let albums: [Album]
    @Binding var selectedAlbum: Album?
    @Binding var albumTracks: [Track]
    let artistNameResolver: (Track) -> String?
    let onPlayAlbum: (Album, [Track]) -> Void
    /// 详情 sheet 开关（父视图持有，支持「右键 → 进专辑」外部触发）
    @Binding var showAlbumSheet: Bool

    private let gridColumns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    /// 专辑卡事实缓存（审计 M2：以前每张卡每帧 2 次整表查询）
    @ObservedObject private var facts = MacLibraryFactsStore.shared
    /// 进专辑失败提示（审计 L7：以前只 print）
    @State private var openError: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(albums, id: \.id) { album in
                    let albumFacts = facts.albumFacts(for: album)
                    Button {
                        openAlbum(album)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            MacArtworkThumbnailFill(
                                track: albumFacts.representativeTrack,
                                cornerRadius: 8,
                                placeholderIcon: "square.stack"
                            )
                            Text(album.title)
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(album.albumArtist ?? String(format: "track_count".localized, albumFacts.trackCount))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .alert("error".localized, isPresented: openErrorBinding) {
            Button(Localized.ok, role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .sheet(isPresented: $showAlbumSheet) {
            if let album = selectedAlbum {
                MacAlbumDetailSheet(
                    album: album,
                    tracks: albumTracks,
                    artistNameResolver: artistNameResolver,
                    onPlay: { onPlayAlbum(album, albumTracks) }
                )
            }
        }
    }

    /// 失败弹窗开关（审计 L7）
    private var openErrorBinding: Binding<Bool> {
        Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )
    }

    private func openAlbum(_ album: Album) {
        do {
            let tracks = try DatabaseManager.shared.getTracksByAlbumId(album.id ?? 0)
            albumTracks = tracks
            selectedAlbum = album
            showAlbumSheet = true
        } catch {
            // 审计 L7：不再只 print（用户点卡无任何反应）
            openError = "album_load_failed".localized(with: error.localizedDescription)
            print("❌ openAlbum failed: \(error)")
        }
    }
}

struct MacAlbumDetailSheet: View {
    let album: Album
    let tracks: [Track]
    let artistNameResolver: (Track) -> String?
    let onPlay: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MacArtworkThumbnail(
                    track: MacArtworkResolver.representativeTrack(forAlbum: album),
                    size: 120,
                    cornerRadius: 10,
                    placeholderIcon: "square.stack"
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title)
                        .font(.title2)
                        .fontWeight(.bold)
                    if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
                        Text(ArtistNameNormalizer.displayName(albumArtist))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("play".localized) { onPlay() }
                    .keyboardShortcut(.return)
                Button("close".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            List(tracks, id: \.stableId) { track in
                HStack {
                    Text(track.title)
                        .lineLimit(1)
                    Spacer()
                    Text(artistNameResolver(track) ?? "")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(MacTimeFormat.format(duration(for: track)))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .padding()
    }

    private func duration(for track: Track) -> TimeInterval {
        guard let ms = track.durationMs else { return 0 }
        return Double(ms) / 1000.0
    }
}

// MARK: - Artists

struct MacArtistListView: View {
    let artists: [Artist]
    @Binding var selectedArtist: Artist?
    @Binding var artistTracks: [Track]
    let artistNameResolver: (Track) -> String?
    let onPlayArtist: (Artist, [Track]) -> Void
    /// 详情 sheet 开关（父视图持有，支持「右键 → 进歌手」外部触发）
    @Binding var showArtistSheet: Bool

    /// 歌手行曲目数缓存（审计 M2：以前每行每帧 1 次整表查询）
    @ObservedObject private var facts = MacLibraryFactsStore.shared
    /// 进歌手失败提示（审计 L7）
    @State private var openError: String?

    var body: some View {
        List(artists, id: \.id) { artist in
            Button {
                openArtist(artist)
            } label: {
                HStack {
                    Image(systemName: "music.mic")
                        .foregroundColor(.secondary)
                    Text(artist.name)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "track_count".localized, facts.artistTrackCount(for: artist)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .alert("error".localized, isPresented: openErrorBinding) {
            Button(Localized.ok, role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .sheet(isPresented: $showArtistSheet) {
            if let artist = selectedArtist {
                MacArtistDetailSheet(
                    artist: artist,
                    tracks: artistTracks,
                    artistNameResolver: artistNameResolver,
                    onPlay: { onPlayArtist(artist, artistTracks) }
                )
            }
        }
    }

    /// 失败弹窗开关（审计 L7）
    private var openErrorBinding: Binding<Bool> {
        Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )
    }

    private func openArtist(_ artist: Artist) {
        do {
            let tracks = try DatabaseManager.shared.getTracksByArtistId(artist.id ?? 0)
            artistTracks = tracks
            selectedArtist = artist
            showArtistSheet = true
        } catch {
            // 审计 L7：不再只 print（用户点行无任何反应）
            openError = "artist_load_failed".localized(with: error.localizedDescription)
            print("❌ openArtist failed: \(error)")
        }
    }
}

struct MacArtistDetailSheet: View {
    let artist: Artist
    let tracks: [Track]
    let artistNameResolver: (Track) -> String?
    let onPlay: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(artist.name)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("play".localized) { onPlay() }
                    .keyboardShortcut(.return)
                Button("close".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            List(tracks, id: \.stableId) { track in
                HStack {
                    Text(track.title)
                        .lineLimit(1)
                    Spacer()
                    Text(albumTitle(for: track))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(MacTimeFormat.format(duration(for: track)))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .padding()
    }

    private func albumTitle(for track: Track) -> String {
        guard let albumId = track.albumId,
              let album = try? DatabaseManager.shared.read({ db in
                  try Album.fetchOne(db, key: albumId)
              }) else {
            return ""
        }
        return album.title
    }

    private func duration(for track: Track) -> TimeInterval {
        guard let ms = track.durationMs else { return 0 }
        return Double(ms) / 1000.0
    }
}

// MARK: - Playlists

/// 播放列表页详情目标：自动歌单（smart）或普通歌单（manual）。详情直接在
/// 内容区展示（2026-09-05 用户反馈：不应弹 sheet，而应像其他列表一样显示在
/// 列表/内容区），主页与详情在同一内容列内切换，返回按钮回到歌单主页。
private enum MacPlaylistDetailTarget {
    case smart(SmartPlaylistKind)
    case manual(Playlist)
}

struct MacPlaylistListView: View {
    let playlists: [Playlist]
    /// Plays the whole playlist (queue = playlist tracks), used by the manual detail.
    let onPlay: (Playlist) -> Void

    @State private var smartCards: [SmartPlaylistCardInfo] = []
    @State private var smartCoverTracks: [SmartPlaylistKind: [Track]] = [:]
    @State private var detailTarget: MacPlaylistDetailTarget?
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    /// 歌单行事实缓存（审计 M2：以前每行每帧 2–3 次查询）
    @ObservedObject private var facts = MacLibraryFactsStore.shared
    /// 卡片条重算任务句柄（审计 M2）
    @State private var smartTask: Task<Void, Never>?
    /// 新建歌单失败提示（审计 L7：以前弹窗静默关闭）
    @State private var createError: String?

    var body: some View {
        Group {
            if let detailTarget {
                detail(for: detailTarget)
            } else {
                home
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaylistsChanged"))) { _ in
            // 歌单变化 → 详情内重载（MacManualPlaylistDetailView 内部也监听），
            // 主页可见时重算卡片计数/封面
            reloadSmartCards()
        }
        // 刮削保存/批量刮削/重扫后：自动歌单卡片计数与封面可能变化（如年代分组），
        // 主页可见时一并重算（2026-09-06 单曲刮削后不刷新修复）
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            reloadSmartCards()
        }
    }

    // MARK: 主页（自动歌单卡片 + 普通歌单列表）

    private var home: some View {
        VStack(spacing: 0) {
            // Pinned automatic playlists — always visible, never user-editable.
            MacSmartPlaylistCardStrip(cards: smartCards, coverTracks: smartCoverTracks) { kind in
                detailTarget = .smart(kind)
            }
            Divider()

            List {
                Section {
                    Button {
                        newPlaylistName = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Label("create_new_playlist".localized, systemImage: "plus")
                    }
                }

                Section {
                    ForEach(playlists, id: \.id) { playlist in
                        let playlistFacts = facts.playlistFacts(for: playlist)
                        Button {
                            detailTarget = .manual(playlist)
                        } label: {
                            HStack(spacing: 10) {
                                MacArtworkThumbnail(
                                    track: playlistFacts.representativeTrack,
                                    size: 36,
                                    cornerRadius: 6,
                                    placeholderIcon: "list.bullet.rectangle"
                                )
                                Text(playlist.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "track_count".localized, playlistFacts.itemCount))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // 文件拖到歌单行 → 导入并加入该歌单（web 侧栏 drop 的
                        // 等价物；B 组，2026-09-03）。行级 drop 优先于窗口级。
                        .onDrop(
                            of: [UTType.fileURL],
                            isTargeted: nil
                        ) { providers in
                            guard let playlistId = playlist.id else { return false }
                            handleDrop(on: providers, playlistId: playlistId)
                            return true
                        }
                    }
                }
            }
        }
        .alert("create_new_playlist".localized, isPresented: $showNewPlaylistAlert) {
            TextField("playlist_name_placeholder".localized, text: $newPlaylistName)
            Button("create".localized) { createPlaylist() }
            Button("cancel".localized, role: .cancel) {}
        }
        .alert("error".localized, isPresented: createErrorBinding) {
            Button(Localized.ok, role: .cancel) { createError = nil }
        } message: {
            Text(createError ?? "")
        }
        .onAppear { reloadSmartCards() }
        .onDisappear { smartTask?.cancel() }
    }

    /// 失败弹窗开关（审计 L7）
    private var createErrorBinding: Binding<Bool> {
        Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )
    }

    // MARK: 详情（内容区直接展示，2026-09-05 起不再弹 sheet）

    @ViewBuilder
    private func detail(for target: MacPlaylistDetailTarget) -> some View {
        switch target {
        case .smart(let kind):
            MacSmartPlaylistDetailView(kind: kind) {
                detailTarget = nil
            }
        case .manual(let playlist):
            MacManualPlaylistDetailView(
                playlist: playlist,
                onPlayAll: { onPlay(playlist) },
                onExit: { detailTarget = nil }
            )
        }
    }

    /// 文件拖到歌单行：复制入曲库并加入该歌单（web 侧栏 drop 等价物）。
    private func handleDrop(on providers: [NSItemProvider], playlistId: Int64) {
        guard !providers.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await MacImportService.importFiles(urls, intoPlaylistId: playlistId)
        }
    }

    private func createPlaylist() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try DatabaseManager.shared.createPlaylist(title: title)
            NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
        } catch {
            // 审计 L7：不再弹窗静默关闭——用户至少知道没建成
            createError = "playlist_create_failed".localized(with: error.localizedDescription)
            print("❌ MacPlaylistListView createPlaylist failed: \(error)")
        }
    }

    /// 卡片条取数（审计 M2：一次 5 次查询，以前同步跑在 onAppear / 通知回调里）
    private func reloadSmartCards() {
        smartTask?.cancel()
        smartTask = Task { @MainActor in
            let payload = await MacSmartPlaylistLoader.cardStrip()
            guard !Task.isCancelled else { return }
            guard let payload else {
                // Keep the four cards visible with zero counts on failure.
                smartCards = SmartPlaylistKind.allCases.map {
                    SmartPlaylistCardInfo(kind: $0, title: $0.rawValue, count: 0)
                }
                smartCoverTracks = [:]
                print("❌ MacPlaylistListView smart cardInfos failed")
                return
            }
            smartCards = payload.cards
            smartCoverTracks = payload.covers
        }
    }
}
