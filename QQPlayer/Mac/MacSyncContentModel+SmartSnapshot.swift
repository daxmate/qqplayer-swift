//
//  MacSyncContentModel+SmartSnapshot.swift
//  QQPlayer
//
//  P1b（2026-11-16）：选择集入口（含智能源整组勾选 = 快照）——从
//  `MacSyncContentModel.swift` 原样搬出（结构预算：单文件 ≤ 600 行，语义零变化）。
//  声明仍是 `MacSyncContentModel` 的成员，只是换了文件；为此把被本扩展访问的
//  成员从 `private` 提为 `internal`（**只改可见性**）。
//

import Foundation

@MainActor
extension MacSyncContentModel {
    // MARK: - 选择集

    /// 切到「全曲库」模式（View 二次确认后才调）。
    func setLibraryWide() { setMode(.library) }

    /// 切到歌单级（保留已勾选的歌单）。
    func setPlaylistsMode() { setMode(.playlists) }

    /// 切到单曲级（保留已勾选的单曲）。
    func setTracksMode() { setMode(.tracks) }

    /// 勾选 / 取消勾选一个歌单（智能源快照原样保留）。
    func togglePlaylist(_ id: String) {
        var picks = selectedPlaylistIDs
        if picks.contains(id) { picks.remove(id) } else { picks.insert(id) }
        applyPicks(
            mode: .playlists,
            playlistIDs: picks,
            trackPaths: selectedTrackPaths,
            smartSnapshots: smartSnapshots
        )
    }

    /// 勾选 / 取消勾选一个智能源（P1b 口径：**整组勾选 = 快照**）。
    ///
    /// - 勾选：走**现有**取数链路（`MacSyncLocalContentProvider.trackPage` 分页取该来源
    ///   当前曲目的相对路径）→ 写入快照；不跟随源后续变化（用户 2026-11-16 拍板）。
    /// - 取消：删该源快照；两个集合都空 → 回落空选择。
    /// - 源 0 首：**不写入** + 返回行内提示（复用既有「没有找到歌曲」文案，不新增键）。
    ///
    /// 返回值 = 本次操作产生的行内提示（nil = 无提示）。提示由 View 用 `@State` 持有，
    /// 不进模型发布状态（避免新增迁移家族标记）。
    @discardableResult
    func toggleSmartSource(_ ref: SyncBrowseSourceRef) -> String? {
        // 智能源行只在本端（上传方向）出现；对端没有该来源 → 不给它造快照
        guard source == .local, ref.kind == .smart else { return nil }
        if isSmartSourceSelected(ref.id) {
            apply(selection.removingSmartSnapshot(sourceID: ref.id))
            return nil
        }
        let paths = currentRelativePaths(of: ref)
        guard !paths.isEmpty else { return "sync_run_tracks_empty".localized }
        apply(selection.settingSmartSnapshot(sourceID: ref.id, paths: paths))
        return nil
    }

    /// 该来源**当前**曲目全集（按既有分页链路逐页取；不新写 SQL / 网络）。
    private func currentRelativePaths(of source: SyncBrowseSourceRef) -> [String] {
        var paths: [String] = []
        var offset = 0
        while true {
            let page = local.trackPage(source: source, query: "", offset: offset)
            paths.append(contentsOf: page.options.map(\.relativePath))
            guard page.hasMore, !page.options.isEmpty else { break }
            offset += page.options.count
        }
        return paths
    }

    /// 勾选 / 取消勾选一首歌。
    func toggleTrack(_ relativePath: String) {
        var picks = selectedTrackPaths
        if picks.contains(relativePath) { picks.remove(relativePath) } else { picks.insert(relativePath) }
        applyPicks(
            mode: .tracks,
            playlistIDs: selectedPlaylistIDs,
            trackPaths: picks,
            smartSnapshots: smartSnapshots
        )
    }

    /// 手动指定单曲集合（替换整个单曲级选择）。
    func setManualTracks(_ relativePaths: [String]) {
        applyPicks(
            mode: .tracks,
            playlistIDs: selectedPlaylistIDs,
            trackPaths: Set(relativePaths),
            smartSnapshots: smartSnapshots
        )
    }

    /// 清空选择（不推不拉）。
    func clearSelection() { clearSelection(persist: true) }
}
