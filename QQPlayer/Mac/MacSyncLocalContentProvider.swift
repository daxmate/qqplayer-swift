//
//  MacSyncLocalContentProvider.swift
//  QQPlayer
//
//  T10（2026-09-12）同步页**本端内容提供者**（QQPlayerMac target only）。
//
//  职责：把「本端（Mac）曲库/歌单/单曲」读成选择区行模型。原实现在
//  `MacSyncRunViewModel` 内（T3 直读 DB）——T10 内容面板要按方向在「本端 / 对端」
//  两条数据源间切换，故把这半边抽成独立提供者，ViewModel 只做编排（两条路径对称）。
//
//  口径（逐条复用既有单一事实源，不另起一套）：
//  - 歌单：`getAllPlaylists()`（标识 = `slug`）+ `getPlaylistItems()` 成员；
//    「收藏」用保留标识 `@favorites`（`getFavoriteTracks()`）。
//  - 曲目相对路径：`SyncManifestGenerator.relativePath(of:baseDirectory:)`
//    ——与 manifest / 对端清单**同一口径**（绝不自己拼字符串）。
//  - 歌手展示名：`getArtistDisplayNames(...)`（批量 + 简繁归一，与列表同口径）。
//  - 分页：`getTracksPaginated(limit:offset:)`；搜索 `searchTracks(query:limit:)`。
//
//  线程：本类型只被 `@MainActor` 的 ViewModel 调用（DB 读走 `DatabaseManager` 的
//  既有线程纪律），内部无并发状态（歌手名缓存随提供者一起被主线程持有）。
//

import Foundation

/// 本端内容读取（Mac 侧；一次同步页会话一个实例）。
struct MacSyncLocalContentProvider {
    /// 单曲级列表每页条数（懒加载；量大不分页会卡主线程）。
    static let trackPageSize = SyncUIContentLimits.trackPageSize
    /// 单曲级搜索结果上限（搜索走 DB 的 ranked search，不再分页）。
    static let trackSearchLimit = SyncUIContentLimits.trackSearchLimit

    let database: DatabaseManager
    /// 曲库根（相对路径基准；与 `MacSyncCoordinatorFactory` / `MacSyncLibraryHost` 同源）。
    let libraryRoot: URL
    /// 歌手展示名缓存（stableId → 名称；按需增长，只增不减）。
    private let artistNames: ArtistNameCache

    init(database: DatabaseManager, libraryRoot: URL) {
        self.database = database
        self.libraryRoot = libraryRoot
        self.artistNames = ArtistNameCache()
    }

    // MARK: - 歌单

    /// 歌单选项（含「收藏」伪歌单，置顶；每项带曲目数与大小合计）。
    func playlistOptions() -> [SyncUIPlaylistOption] {
        var options: [SyncUIPlaylistOption] = []

        let favorites = (try? database.getFavoriteTracks()) ?? []
        options.append(
            SyncUIPlaylistOption(
                id: SyncCollectionSelection.favoritesPlaylistID,
                title: "sync_run_favorites".localized,
                trackCount: favorites.count,
                totalBytes: totalBytes(of: favorites),
                missingSizeCount: favorites.filter { ($0.fileSize ?? 0) <= 0 }.count
            )
        )

        // 一次取全库曲目建索引，避免「每个歌单成员一次查询」把主线程拖住。
        let tracksByStableId = Dictionary(
            ((try? database.getAllTracks()) ?? []).map { ($0.stableId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for playlist in (try? database.getAllPlaylists()) ?? [] {
            guard let playlistID = playlist.id,
                  let items = try? database.getPlaylistItems(playlistId: playlistID)
            else { continue }
            let members = items.compactMap { tracksByStableId[$0.trackStableId] }
            options.append(
                SyncUIPlaylistOption(
                    id: playlist.slug,
                    title: playlist.title,
                    trackCount: members.count,
                    totalBytes: totalBytes(of: members),
                    missingSizeCount: members.filter { ($0.fileSize ?? 0) <= 0 }.count
                )
            )
        }
        return options
    }

    // MARK: - 曲目

    /// 单曲级一页（`query` 非空 = 搜索，返回的 `hasMore` 恒 false：搜索结果不分页）。
    func trackPage(query: String, offset: Int) -> (options: [SyncUITrackOption], hasMore: Bool) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [Track]
        if normalized.isEmpty {
            rows = (try? database.getTracksPaginated(
                limit: Self.trackPageSize,
                offset: max(0, offset)
            )) ?? []
        } else {
            rows = (try? database.searchTracks(query: normalized, limit: Self.trackSearchLimit)) ?? []
        }
        artistNames.loadIfNeeded(for: rows, database: database)
        let options = rows.compactMap(trackOption(for:))
        return (options, normalized.isEmpty && rows.count == Self.trackPageSize)
    }

    // MARK: - 全库规模

    /// 全库规模事实（曲目数 + 文件大小合计）。
    func libraryFacts() -> SyncUILibraryFacts {
        let count = (try? database.getTrackCount()) ?? 0
        let bytes = (try? database.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(file_size), 0) FROM track")
        }) ?? 0
        return SyncUILibraryFacts(trackCount: count, totalBytes: bytes)
    }

    // MARK: - 内部

    /// 一条 Track → 单曲选项（不在曲库根内 → nil = 跳过）。
    func trackOption(for track: Track) -> SyncUITrackOption? {
        guard let relativePath = SyncManifestGenerator.relativePath(
            of: URL(fileURLWithPath: track.path),
            baseDirectory: libraryRoot
        ) else {
            return nil
        }
        return SyncUITrackOption(
            relativePath: relativePath,
            title: track.title,
            artistName: artistNames.name(forStableId: track.stableId),
            fileSize: track.fileSize
        )
    }

    private func totalBytes(of tracks: [Track]) -> Int64 {
        tracks.reduce(Int64(0)) { total, track in
            total + max(0, track.fileSize ?? 0)
        }
    }
}

/// 歌手展示名缓存（批量补齐；只增不减，避免翻页时重复查库）。
final class ArtistNameCache {
    private var names: [String: String] = [:]

    /// 缺失的补一批（失败不抛：拿不到名字就显示无歌手，不阻塞列表）。
    func loadIfNeeded(for tracks: [Track], database: DatabaseManager) {
        let missing = tracks.filter { names[$0.stableId] == nil }
        guard !missing.isEmpty else { return }
        let fallback = Dictionary(
            missing.compactMap { track in track.artistId.map { (track.stableId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let loaded = (try? database.getArtistDisplayNames(
            forTrackStableIds: missing.map(\.stableId),
            fallbackArtistIdsByStableId: fallback
        )) ?? [:]
        names.merge(loaded) { _, new in new }
    }

    func name(forStableId stableId: String) -> String? { names[stableId] }
}
