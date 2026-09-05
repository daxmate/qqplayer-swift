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

    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(albums, id: \.id) { album in
                    Button {
                        openAlbum(album)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            MacArtworkThumbnailFill(
                                track: MacArtworkResolver.representativeTrack(forAlbum: album),
                                cornerRadius: 8,
                                placeholderIcon: "square.stack"
                            )
                            Text(album.title)
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(album.albumArtist ?? String(format: "track_count".localized, albumTrackCount(album)))
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

    private func openAlbum(_ album: Album) {
        do {
            let tracks = try DatabaseManager.shared.getTracksByAlbumId(album.id ?? 0)
            albumTracks = tracks
            selectedAlbum = album
            showAlbumSheet = true
        } catch {
            print("❌ openAlbum failed: \(error)")
        }
    }

    private func albumTrackCount(_ album: Album) -> Int {
        (try? DatabaseManager.shared.getTracksByAlbumId(album.id ?? 0).count) ?? 0
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
                    Text(String(format: "track_count".localized, artistTrackCount(artist)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    private func openArtist(_ artist: Artist) {
        do {
            let tracks = try DatabaseManager.shared.getTracksByArtistId(artist.id ?? 0)
            artistTracks = tracks
            selectedArtist = artist
            showArtistSheet = true
        } catch {
            print("❌ openArtist failed: \(error)")
        }
    }

    private func artistTrackCount(_ artist: Artist) -> Int {
        (try? DatabaseManager.shared.getTracksByArtistId(artist.id ?? 0).count) ?? 0
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
                        Button {
                            detailTarget = .manual(playlist)
                        } label: {
                            HStack(spacing: 10) {
                                MacArtworkThumbnail(
                                    track: MacArtworkResolver.representativeTrack(forPlaylist: playlist),
                                    size: 36,
                                    cornerRadius: 6,
                                    placeholderIcon: "list.bullet.rectangle"
                                )
                                Text(playlist.title)
                                    .lineLimit(1)
                                Spacer()
                                if let itemCount = try? DatabaseManager.shared.getPlaylistItems(playlistId: playlist.id ?? 0).count {
                                    Text(String(format: "track_count".localized, itemCount))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
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
        .onAppear { reloadSmartCards() }
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
            print("❌ MacPlaylistListView createPlaylist failed: \(error)")
        }
    }

    private func reloadSmartCards() {
        do {
            smartCards = try SmartPlaylistStore.cardInfos()
            var covers: [SmartPlaylistKind: [Track]] = [:]
            for kind in SmartPlaylistKind.allCases {
                covers[kind] = try SmartPlaylistStore.coverTracks(for: kind, limit: 4)
            }
            smartCoverTracks = covers
        } catch {
            // Keep the four cards visible with zero counts on failure.
            smartCards = SmartPlaylistKind.allCases.map {
                SmartPlaylistCardInfo(kind: $0, title: $0.rawValue, count: 0)
            }
            smartCoverTracks = [:]
            print("❌ MacPlaylistListView smart cardInfos failed: \(error)")
        }
    }
}
