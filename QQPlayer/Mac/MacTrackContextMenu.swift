//
//  MacTrackContextMenu.swift
//  QQPlayer
//
//  macOS 曲目右键菜单的**唯一实现**（2026-11-14，用户拍板：搜索结果的右键菜单必须与曲库完全一致）。
//
//  为什么收口到这里：曲库 Table（MacTrackListView）与两个搜索面
//  （侧栏库内检索 MacSearchResultsView、⌘K MacSearchAnythingLayer）要求同一套菜单项 +
//  同一套动作语义。复制粘贴必然漂移，所以菜单内容、新建歌单 / 编辑标签 / 删除确认
//  的状态宿主、以及删除执行都只在本文件实现，三处都是调用点
//  （契约测试 MacTrackListViewPlaylistMenuContractTests 守护）。
//
//  QQPlayerMac target only（见 project.pbxproj 成员例外表）。
//

import SwiftUI

// MARK: - 菜单状态（弹窗 + 菜单数据）

/// 曲目右键菜单的状态与数据。
///
/// 每个宿主视图用 @State 各持有一份（曲库 / 侧栏检索 / ⌘K 浮层），
/// 弹窗本身由 .macTrackMenu(_:) 统一挂载 —— 三处不需要各写一套 alert/sheet。
@MainActor
@Observable
final class MacTrackMenuModel {
    /// 「添加到歌单」子菜单数据（.playlistsChanged 时重载）
    var playlists: [Playlist] = []
    /// 红心状态（.favoritesChanged 时重载）
    var favoriteIds: Set<String> = []

    /// 编辑标签 / 刮削（.sheet(item:) 驱动，避免 .sheet(isPresented:) 白框竞态）
    var tagEditorTrack: Track?

    /// 新建歌单
    var showNewPlaylistAlert = false
    var newPlaylistName = ""
    var pendingTracks: [Track] = []

    /// 移到废纸篓（与曲库历史语义一致：菜单点击 → 确认 → 执行）
    var showTrashConfirm = false
    var pendingTrashTracks: [Track] = []

    /// 批量删除进度 / 任务句柄（曲库工具栏展示并允许取消；搜索面同样执行，只是不展示进度条）
    var trashProgress: TrackDeletionService.Progress?
    @ObservationIgnored var trashTask: Task<Void, Never>?
    /// 删除失败提示（部分/全部失败时弹一次）
    var trashFailureMessage: String?

    // MARK: 数据

    func reloadPlaylists() {
        playlists = (try? LibraryReads.playlists()) ?? []
    }

    func reloadFavorites(using appCoordinator: AppCoordinator) {
        favoriteIds = Set((try? appCoordinator.getFavorites()) ?? [])
    }

    // MARK: 删除确认

    var trashConfirmMessage: String {
        if pendingTrashTracks.count == 1, let title = pendingTrashTracks.first?.displayTitle {
            return Localized.moveToTrashConfirm(title)
        }
        return Localized.moveToTrashConfirm(count: pendingTrashTracks.count)
    }

    /// 菜单「移到废纸篓」→ 确认弹窗（确认后由 MacTrackMenuModifier 执行）
    func requestTrash(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        pendingTrashTracks = tracks
        showTrashConfirm = true
    }
}

// MARK: - 菜单项（唯一实现）

/// 曲目右键菜单内容。曲库单选右键与两个搜索面共用这一份；
/// 菜单项顺序 / 文案 / 动作语义必须与曲库历史一致（契约测试守护调用点数）。
struct MacTrackContextMenuContent: View {
    @Environment(AppCoordinator.self) private var appCoordinator

    let track: Track
    let model: MacTrackMenuModel
    /// Non-nil inside a playlist detail sheet: additionally offers 「从歌单移除」
    var playlistId: Int64?
    let onPlay: () -> Void
    /// 「下一首播放」：插入当前播放曲目之后（不播放）
    var onPlayNext: ((Track) -> Void)?
    /// 「进歌手 / 进专辑」：切到对应分组并打开详情
    var onShowArtist: ((Track) -> Void)?
    var onShowAlbum: ((Track) -> Void)?

    var body: some View {
        Button("play".localized) {
            onPlay()
        }

        if let onPlayNext {
            Button("play_next".localized) {
                onPlayNext(track)
            }
        }

        Divider()

        let isFavorite = model.favoriteIds.contains(track.stableId)
        Button {
            try? appCoordinator.toggleFavorite(trackStableId: track.stableId)
        } label: {
            Label(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs,
                  systemImage: "heart.fill")
        }

        if let playlistId {
            Divider()
            Button("playlist_manage_remove_from_playlist".localized, role: .destructive) {
                try? appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: .playlistsChanged, object: nil)
            }
        }

        Divider()
        Menu(Localized.addToPlaylist) {
            MacAddToPlaylistMenu(tracks: [track], model: model)
        }

        if let onShowArtist {
            Divider()
            Button("show_artist".localized) {
                presentAfterTrackMenuDismisses {
                    onShowArtist(track)
                }
            }
        }
        if let onShowAlbum {
            Button("show_album".localized) {
                presentAfterTrackMenuDismisses {
                    onShowAlbum(track)
                }
            }
        }

        // 编辑标签 / 刮削：单曲编辑弹窗（自动刮削 + 表单 + 保存改名）
        Divider()
        Button {
            presentAfterTrackMenuDismisses {
                model.tagEditorTrack = track
            }
        } label: {
            Label("context_edit_tags".localized, systemImage: "tag")
        }

        // 移到废纸篓：send2trash 语义 = 系统废纸篓可恢复（deleteTrack 同时清理歌单/收藏引用）
        Divider()
        Button(role: .destructive) {
            presentAfterTrackMenuDismisses {
                model.requestTrash([track])
            }
        } label: {
            Label(Localized.moveToTrash, systemImage: "trash")
        }
    }
}

/// 「添加到歌单」子菜单内容（唯一实现，单选 / 多选 / 搜索面共用）：
/// 列歌单（整批逐首添加，循环后统一 post 一次）+ 新建歌单。
struct MacAddToPlaylistMenu: View {
    @Environment(AppCoordinator.self) private var appCoordinator

    let tracks: [Track]
    let model: MacTrackMenuModel

    var body: some View {
        ForEach(model.playlists, id: \.id) { playlist in
            Button(playlist.title) {
                // 整批逐首加入（addToPlaylist 自带「已在歌单 → 跳过」判据）
                tracks.forEach { try? appCoordinator.addToPlaylist(playlistId: playlist.id ?? 0, trackStableId: $0.stableId) }
                NotificationCenter.default.post(name: .playlistsChanged, object: nil)
            }
        }
        Divider()
        Button("create_new_playlist".localized) {
            presentAfterTrackMenuDismisses {
                model.pendingTracks = tracks
                model.newPlaylistName = ""
                model.showNewPlaylistAlert = true
            }
        }
    }
}

// MARK: - 弹窗宿主 + 删除执行（唯一实现）

/// 曲目右键菜单的弹窗宿主 + 删除执行。挂在宿主视图上（.macTrackMenu(menu)）：
/// 新建歌单 alert / 编辑标签 sheet / 删除确认 alert / 删除失败 alert 都只在这里挂一次。
struct MacTrackMenuModifier: ViewModifier {
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(PlayerEngine.self) private var player

    let model: MacTrackMenuModel
    /// 删除完成回调：宿主用来做本地行移除（曲库传，搜索面刷新靠通知链）
    var onDeleted: ((Set<String>) -> Void)?

    func body(content: Content) -> some View {
        content
            .onAppear {
                model.reloadPlaylists()
                model.reloadFavorites(using: appCoordinator)
            }
            .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
                model.reloadFavorites(using: appCoordinator)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistsChanged)) { _ in
                model.reloadPlaylists()
            }
            .alert("create_new_playlist".localized, isPresented: showNewPlaylistAlert) {
                TextField("playlist_name_placeholder".localized, text: newPlaylistName)
                Button("create".localized) { createPlaylistAndAdd() }
                Button("cancel".localized, role: .cancel) {}
            }
            .alert(Localized.moveToTrash, isPresented: showTrashConfirm) {
                Button(Localized.moveToTrash, role: .destructive) { startTrash() }
                Button("cancel".localized, role: .cancel) { model.pendingTrashTracks = [] }
            } message: {
                Text(model.trashConfirmMessage)
            }
            .alert(Localized.moveToTrash, isPresented: trashFailurePresented) {
                Button("ok".localized, role: .cancel) { model.trashFailureMessage = nil }
            } message: {
                Text(model.trashFailureMessage ?? "")
            }
            .sheet(item: tagEditorTrack) { track in
                MacTagEditorView(track: track)
            }
    }

    // MARK: Bindings

    private var showNewPlaylistAlert: Binding<Bool> {
        Binding(get: { model.showNewPlaylistAlert }, set: { model.showNewPlaylistAlert = $0 })
    }

    private var newPlaylistName: Binding<String> {
        Binding(get: { model.newPlaylistName }, set: { model.newPlaylistName = $0 })
    }

    private var showTrashConfirm: Binding<Bool> {
        Binding(get: { model.showTrashConfirm }, set: { model.showTrashConfirm = $0 })
    }

    private var trashFailurePresented: Binding<Bool> {
        Binding(get: { model.trashFailureMessage != nil }, set: { if !$0 { model.trashFailureMessage = nil } })
    }

    private var tagEditorTrack: Binding<Track?> {
        Binding(get: { model.tagEditorTrack }, set: { model.tagEditorTrack = $0 })
    }

    // MARK: 新建歌单

    private func createPlaylistAndAdd() {
        let title = model.newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = model.pendingTracks
        guard !title.isEmpty, !pending.isEmpty else { return }
        do {
            let playlist = try appCoordinator.createPlaylist(title: title)
            let playlistId = playlist.id ?? 0
            for track in pending {
                try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            }
            NotificationCenter.default.post(name: .playlistsChanged, object: nil)
        } catch {
            AppLog.error(.ui, "❌ MacTrackContextMenu createPlaylistAndAdd failed: \(error)")
        }
        model.pendingTracks = []
    }

    // MARK: 移到废纸篓

    /// 统一删除执行（曲库 / 搜索面同一份）：磁盘 trash + DB 删除走 TrackDeletionService，
    /// 主线程只落状态与发通知；删除后再做播放队列联动（顺序与曲库历史一致）。
    private func startTrash() {
        let tracks = model.pendingTrashTracks
        model.pendingTrashTracks = []
        guard !tracks.isEmpty else { return }

        let items = tracks.map {
            TrackDeletionService.Item(stableId: $0.stableId, title: $0.title, path: $0.path)
        }
        let requestedIds = Set(items.map(\.stableId))

        // 重入保护：上一批仍在跑时先取消它（避免两次批次交错写同一批状态）
        model.trashTask?.cancel()
        model.trashProgress = TrackDeletionService.Progress(done: 0, total: items.count)
        model.trashTask = Task { @MainActor in
            let outcome = await TrackDeletionService.trash(
                items: items,
                environment: .live(
                    log: { MacTrashLogger.log($0) },
                    isCancelled: { Task.isCancelled },
                    libraryRoot: MacLibraryRoot.resolvedRootURL
                ),
                onProgress: { done, total in
                    DispatchQueue.main.async {
                        model.trashProgress = TrackDeletionService.Progress(done: done, total: total)
                    }
                }
            )
            let failedCount = outcome.failed
            let deletedAny = outcome.deletedAny
            model.trashProgress = nil
            model.trashTask = nil

            // 宿主本地视图先对齐（曲库：立刻消失 + 序号重排、多选清空）
            onDeleted?(requestedIds)

            // 通知先发（UI 立即刷新），播放队列联动后置（SFB 引擎切歌/加载可能耗时，
            // 若 await 在通知前，加载慢会拖住曲库刷新）
            if deletedAny {
                // 先刷新全库（tracks/歌单），再刷新收藏列表——顺序相关：
                // reloadLibrary 先重拉 tracks，reloadLikedTracks 才能用新数据过滤
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
                NotificationCenter.default.post(name: .playlistsChanged, object: nil)
                NotificationCenter.default.post(name: .favoritesChanged, object: nil)
            } else if failedCount > 0 {
                // 全部失败（文件仍在）：也发一次 LibraryNeedsRefresh，让列表与 DB 对齐
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
            }
            if failedCount > 0 {
                model.trashFailureMessage = Localized.moveToTrashFailed(count: failedCount)
            }

            await handleDeletedTracksInPlayback(requestedIds)
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
}

// MARK: - 视图扩展

extension View {
    /// 挂载曲目右键菜单的弹窗宿主（新建歌单 / 编辑标签 / 删除确认 / 删除失败）。
    /// - Parameters:
    ///   - model: 宿主用 @State 持有的菜单状态
    ///   - onDeleted: 删除执行后回调（宿主本地行移除等）；搜索面靠通知链刷新，可不传
    func macTrackMenu(_ model: MacTrackMenuModel, onDeleted: ((Set<String>) -> Void)? = nil) -> some View {
        modifier(MacTrackMenuModifier(model: model, onDeleted: onDeleted))
    }
}

// MARK: - 菜单 → 弹窗的延迟呈现

/// 右键菜单（context menu）自身以 modal 形式呈现，点击菜单项时菜单仍在收起动画中；
/// 此刻若同步触发 sheet/alert，会与菜单 dismiss 冲突 → 弹窗卡成空白小窗。
/// 所有从右键菜单触发的弹窗统一延迟到菜单完全收起后再呈现（~0.15s 无感）。
/// 注：白框根因另有其因（.sheet(isPresented:) 的 item 竞态，2026-09-08 已改
/// .sheet(item:)）；此延迟仍保留——菜单 tracking 冲突独立存在，两类叠加才致“永久卡”。
@MainActor
func presentAfterTrackMenuDismisses(_ action: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        action()
    }
}
