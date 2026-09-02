//
//  MacTrackListView.swift
//  QQPlayer
//
//  macOS track list (content column for the 歌曲 section). QQPlayerMac target only.
//
//  2026-09-02 三修：回归 SwiftUI Table——macOS 平台惯例「单击选中、双击播放」
//  由 Table 原生 primaryAction 保证（AppKit NSTableView 底层），不再用手势模拟
//  （List + onTapGesture 与选中手势冲突导致双击失效，教训：平台基础交互交给
//  原生控件）。保留：列头原生排序（sortOrder）、右键菜单补全（contextMenu
//  forSelectionType）、定位当前播放（选中 + 尽量滚动可见）、播放队列跟随排序。
//

import AppKit
import SwiftUI

/// Table 行包装：携带排序字段（artist 显示名经 resolver 解析）。
/// macOS 13+/26 SDK 的排序 TableColumn(value:) 与 SortDescriptor 都要求行类型
/// 继承 NSObject 且排序 KeyPath 指向 @objc 存储属性（OC runtime 内省）——
/// 用计算属性/纯 Swift 属性会运行时 fatal："must be introspectable by the
/// objective-c runtime"（2026-09-02 用户实测）。
private final class MacTrackTableRow: NSObject, Identifiable {
    let id: String
    let track: Track
    /// 排序/显示字段：@objc 存储属性（title/artist/duration）
    @objc let title: String
    @objc let artistName: String
    @objc let durationMs: Int64

    init(id: String, track: Track, artistName: String) {
        self.id = id
        self.track = track
        self.title = track.title
        self.artistName = artistName
        self.durationMs = Int64(track.durationMs ?? 0)
    }
}

struct MacTrackListView: View {
    let tracks: [Track]
    let activeTrackId: String?
    let isPlaying: Bool
    let artistNameResolver: (Track) -> String?
    /// 双击/播放回调：队列 = 当前排序后显示列表（web 版「以当前视图为队列」语义）
    let onPlay: (Track, [Track]) -> Void
    let onSelect: (Track) -> Void
    /// Non-nil inside a playlist detail sheet: the context menu additionally
    /// offers "remove from playlist" for the owning playlist.
    var playlistId: Int64?
    /// 「下一首播放」：插入当前播放曲目之后（不播放）
    var onPlayNext: ((Track) -> Void)?
    /// 「进歌手 / 进专辑」：切到对应分组并打开详情
    var onShowArtist: ((Track) -> Void)?
    var onShowAlbum: ((Track) -> Void)?

    @State private var selectedRows = Set<String>()
    @State private var favoriteIds: Set<String> = []
    @State private var playlists: [Playlist] = []
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var pendingTrack: Track?
    /// Table 原生列头排序（点击表头升/降；显示与播放队列都跟随）。
    /// macOS 26 SDK 的 Table sortOrder 使用 SortDescriptor。
    @State private var sortOrder: [SortDescriptor<MacTrackTableRow>] = []
    /// 当前显示的排序后行（播放队列跟随，与 Table 显示一致）
    @State private var displayedRows: [MacTrackTableRow] = []

    private var rows: [MacTrackTableRow] {
        tracks.map { MacTrackTableRow(id: $0.stableId, track: $0, artistName: artistNameResolver($0) ?? "") }
    }

    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("library_empty".localized)
                    .font(.title3)
                Text("library_empty_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                toolbarRow
                Divider()
                table
            }
            .alert("create_new_playlist".localized, isPresented: $showNewPlaylistAlert) {
                TextField("playlist_name_placeholder".localized, text: $newPlaylistName)
                Button("create".localized) { createPlaylistAndAdd() }
                Button("cancel".localized, role: .cancel) {}
            }
            .onAppear {
                reloadFavorites()
                reloadPlaylists()
                syncDisplayedRows()
            }
            .onChange(of: sortOrder) { _ in
                syncDisplayedRows()
            }
            .onChange(of: tracks.map(\.stableId)) { _ in
                syncDisplayedRows()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FavoritesChanged"))) { _ in
                reloadFavorites()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaylistsChanged"))) { _ in
                reloadPlaylists()
            }
        }
    }

    // MARK: - Toolbar（定位当前播放）

    private var toolbarRow: some View {
        HStack {
            Button {
                locateActiveTrack()
            } label: {
                Label(Localized.locatePlayingTrack, systemImage: "location")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(activeTrackId == nil)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Table

    private var table: some View {
        Table(displayedRows, selection: $selectedRows, sortOrder: $sortOrder) {
            TableColumn("#") { row in
                if row.track.stableId == activeTrackId {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Text(row.track.trackNo.map(String.init) ?? "")
                        .foregroundColor(.secondary)
                }
            }
            .width(32)

            TableColumn("title".localized, value: \.title) { row in
                Text(row.track.title)
                    .fontWeight(row.track.stableId == activeTrackId ? .semibold : .regular)
                    .lineLimit(1)
            }

            TableColumn("artist".localized, value: \.artistName) { row in
                Text(row.artistName)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            TableColumn("album".localized) { row in
                Text(albumTitle(for: row.track))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            TableColumn("duration".localized, value: \.durationMs) { row in
                Text(MacTimeFormat.format(duration(for: row.track)))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .width(56)

            TableColumn("") { row in
                let isFavorite = favoriteIds.contains(row.track.stableId)
                Button {
                    try? AppCoordinator.shared.toggleFavorite(trackStableId: row.track.stableId)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundColor(isFavorite ? .pink : .secondary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "remove_from_liked_songs".localized : "add_to_liked_songs".localized)
            }
            .width(32)
        }
        // macOS 惯例：单击选中、双击播放（Table primaryAction 原生实现，
        // AppKit NSTableView 底层；勿改手势模拟）
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let id = selectedIDs.first,
               let row = displayedRows.first(where: { $0.id == id }) {
                contextMenuItems(row.track)
            }
        } primaryAction: { selectedIDs in
            if let id = selectedIDs.first,
               let row = displayedRows.first(where: { $0.id == id }) {
                play(row.track)
            }
        }
        .onChange(of: locateRequestID) { _ in
            // 定位当前播放：选中当前行（Table 无公开 scrollTo，选中高亮定位）
            if let activeTrackId {
                selectedRows = [activeTrackId]
            }
        }
    }

    /// 定位请求信号：按钮点击自增触发 onChange
    @State private var locateRequestID = 0

    private func locateActiveTrack() {
        locateRequestID += 1
    }

    // MARK: - Playback

    private func play(_ track: Track) {
        onPlay(track, displayedRows.map(\.track))
        onSelect(track)
    }

    /// 让显示行与排序状态同步（Table 内部按 sortOrder 重排，此处镜像供播放队列用）
    private func syncDisplayedRows() {
        displayedRows = rows.sorted(using: sortOrder)
    }

    // MARK: - Context menu（web 版 7 项对齐：播放/下一首播放/收藏/加歌单/进歌手/进专辑/歌单内移除）

    @ViewBuilder
    private func contextMenuItems(_ track: Track) -> some View {
        Button("play".localized) {
            play(track)
        }

        if let onPlayNext {
            Button("play_next".localized) {
                onPlayNext(track)
            }
        }

        Divider()

        let isFavorite = favoriteIds.contains(track.stableId)
        Button {
            try? AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
        } label: {
            Label(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs,
                  systemImage: "heart.fill")
        }

        if let playlistId {
            Divider()
            Button("playlist_manage_remove_from_playlist".localized, role: .destructive) {
                try? DatabaseManager.shared.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
            }
        }

        Divider()
        Menu("add_to_playlist".localized) {
            ForEach(playlists, id: \.id) { playlist in
                Button(playlist.title) {
                    try? DatabaseManager.shared.addToPlaylist(playlistId: playlist.id ?? 0, trackStableId: track.stableId)
                    NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
                }
            }
            Divider()
            Button("create_new_playlist".localized) {
                pendingTrack = track
                newPlaylistName = ""
                showNewPlaylistAlert = true
            }
        }

        if let onShowArtist {
            Divider()
            Button("show_artist".localized) {
                onShowArtist(track)
            }
        }
        if let onShowAlbum {
            Button("show_album".localized) {
                onShowAlbum(track)
            }
        }
    }

    // MARK: - Data helpers

    private func reloadFavorites() {
        favoriteIds = Set((try? AppCoordinator.shared.getFavorites()) ?? [])
    }

    private func reloadPlaylists() {
        playlists = (try? DatabaseManager.shared.getAllPlaylists()) ?? []
    }

    private func createPlaylistAndAdd() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let track = pendingTrack else { return }
        do {
            let playlist = try DatabaseManager.shared.createPlaylist(title: title)
            try DatabaseManager.shared.addToPlaylist(playlistId: playlist.id ?? 0, trackStableId: track.stableId)
            NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
        } catch {
            print("❌ MacTrackListView createPlaylistAndAdd failed: \(error)")
        }
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
