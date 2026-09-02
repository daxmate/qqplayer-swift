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
    /// 移到废纸篓（web 版「移到废纸篓」对齐，2026-09-02 A4）：确认弹窗状态
    @State private var showTrashConfirm = false
    @State private var pendingTrashTracks: [Track] = []
    @State private var trashFailureAlert: String?
    /// 播放器（删除当前播放曲目时切下一首/停止）
    @StateObject private var player = PlayerEngine.shared
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
            .alert(Localized.moveToTrash, isPresented: $showTrashConfirm) {
                Button(Localized.moveToTrash, role: .destructive) { movePendingTracksToTrash() }
                Button("cancel".localized, role: .cancel) {}
            } message: {
                Text(trashConfirmMessage)
            }
            .alert(Localized.moveToTrash, isPresented: trashFailureBinding) {
                Button("ok".localized, role: .cancel) { trashFailureAlert = nil }
            } message: {
                Text(trashFailureAlert ?? "")
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

    // MARK: - Toolbar（定位当前播放 / 多选批量条）

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            if !selectedRows.isEmpty {
                // 多选批量条（web 版 PlaylistBatchBar 对齐）：已选 n 首 + 移到废纸篓 + 清空选择
                Label(Localized.selectedCount(selectedRows.count), systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button {
                    let tracks = displayedRows
                        .filter { selectedRows.contains($0.id) }
                        .map(\.track)
                    requestTrash(tracks)
                } label: {
                    Label(Localized.moveToTrash, systemImage: "trash")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(selectedRows.isEmpty)
                Spacer()
                Button {
                    selectedRows.removeAll()
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("clear_selection_help".localized)
            } else {
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
            if selectedIDs.count > 1 {
                // 多选：批量移到废纸篓（web 版多选批量对齐，歌单详情内同样可用——
                // deleteTrack 自动清理歌单引用，PlaylistsChanged 刷新）
                let tracks = displayedRows
                    .filter { selectedIDs.contains($0.id) }
                    .map(\.track)
                if !tracks.isEmpty {
                    Button(role: .destructive) {
                        requestTrash(tracks)
                    } label: {
                        Label(Localized.moveToTrash, systemImage: "trash")
                    }
                }
            } else if let id = selectedIDs.first,
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

        // 移到废纸篓（web 版对齐，全场景）：send2trash 语义 = 系统废纸篓可恢复，
        // deleteTrack 同时清理歌单/收藏引用（歌单内删除后从歌单消失属预期）
        Divider()
        Button(role: .destructive) {
            requestTrash([track])
        } label: {
            Label(Localized.moveToTrash, systemImage: "trash")
        }
    }

    // MARK: - Move to Trash（web 版「移到废纸篓」对齐：send2trash 语义 = 系统废纸篓可恢复）

    private var trashConfirmMessage: String {
        if pendingTrashTracks.count == 1, let title = pendingTrashTracks.first?.title {
            return Localized.moveToTrashConfirm(title)
        }
        return Localized.moveToTrashConfirm(count: pendingTrashTracks.count)
    }

    /// 失败提示（成功数 > 0 时列表仍刷新，失败项保留在原库）
    private var trashFailureBinding: Binding<Bool> {
        Binding(
            get: { trashFailureAlert != nil },
            set: { if !$0 { trashFailureAlert = nil } }
        )
    }

    private func requestTrash(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        pendingTrashTracks = tracks
        showTrashConfirm = true
    }

    private func movePendingTracksToTrash() {
        let tracks = pendingTrashTracks
        guard !tracks.isEmpty else { return }
        pendingTrashTracks = []

        Task { @MainActor in
            let fm = FileManager.default
            let deletedStableIds = Set(tracks.map(\.stableId))
            var failedCount = 0
            var deletedAny = false

            for track in tracks {
                let url = URL(fileURLWithPath: track.path)
                // web 语义：磁盘文件不存在（已丢）→ 照常清理引用计入 deleted；
                // trash 失败且文件还在 → errors（保留曲目）；库内 → 移系统废纸篓
                if fm.fileExists(atPath: url.path) {
                    do {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        failedCount += 1
                        print("🗑️ moveToTrash failed for \(track.title): \(error)")
                        continue
                    }
                }
                do {
                    try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                    deletedAny = true
                } catch {
                    failedCount += 1
                    print("🗑️ deleteTrack failed for \(track.title): \(error)")
                }
            }

            // 播放队列联动（web removeSongsFromQueue 对齐）：从队列移除被删曲目；
            // 正在播放的被删曲目 → 队列仍有歌则自动切下一首，否则停止
            await handleDeletedTracksInPlayback(deletedStableIds)

            selectedRows.removeAll()

            if deletedAny {
                // 先刷新全库（tracks/歌单），再刷新收藏列表——顺序相关：
                // reloadLibrary 先重拉 tracks，reloadLikedTracks 才能用新数据过滤
                NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
                NotificationCenter.default.post(name: NSNotification.Name("FavoritesChanged"), object: nil)
            }
            if failedCount > 0 {
                trashFailureAlert = Localized.moveToTrashFailed(count: failedCount)
            }
        }
    }

    /// 播放队列联动（web removeSongsFromQueue 对齐）：从队列移除被删曲目；
    /// 正在播放的被删曲目 → 队列仍有歌则自动续播原位置的下一首，否则停止。
    /// 走 PlayerEngine 公开 API（playbackQueue/currentTrack 可写 + playTrack/pause），不绕引擎内部。
    @MainActor
    private func handleDeletedTracksInPlayback(_ deletedStableIds: Set<String>) async {
        guard !deletedStableIds.isEmpty else { return }

        let remaining = player.playbackQueue.filter { !deletedStableIds.contains($0.stableId) }
        let currentWasDeleted = player.currentTrack.map { deletedStableIds.contains($0.stableId) } ?? false

        if currentWasDeleted {
            if remaining.isEmpty {
                // 没有可续播的曲目：停止并清空当前曲目
                player.playbackQueue = []
                player.pause()
                player.currentTrack = nil
                return
            }
            // 原队列中被删曲目的下标 → remaining 里同位置的项 = 其后第一个存活曲目
            // （下标越界循环到队首）。rem 保持原相对顺序，前面的删项只会让下标前移
            let deletedIndex = player.playbackQueue.firstIndex {
                deletedStableIds.contains($0.stableId)
            } ?? 0
            let next = remaining[deletedIndex % remaining.count]
            player.playbackQueue = remaining
            player.originalQueue.removeAll { deletedStableIds.contains($0) }
            if player.isPlaying {
                // 正在播放被删曲目 → 自动续播下一首（对齐 web）
                await player.playTrack(next, queue: remaining)
            } else {
                // 暂停/停止状态删当前曲 → 清引用不自动播
                player.pause()
                player.currentTrack = nil
            }
        } else if remaining.count != player.playbackQueue.count {
            // 只删了队列里的后续曲目：替换队列并修正 index
            player.playbackQueue = remaining
            player.originalQueue.removeAll { deletedStableIds.contains($0) }
            player.normalizeIndexAndTrack()
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
