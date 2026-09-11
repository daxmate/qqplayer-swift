//
//  DatabaseSyncPeerLibraryFacts.swift
//  QQPlayer
//
//  T9（2026-09-12）「对端内容清单」的**生产事实装配**（契约 C2 风格：纯 DB 读、
//  平台无关、可单测）。
//
//  背景：`SyncPeerLibraryResponder`（应答帧 15 → 帧 16）需要「本端有什么歌单、
//  每个歌单几首、曲目标题/歌手/大小/指纹」这些事实；事实从哪来由本文件收口
//  （Mac / iOS 同一份查询口径；两端 DB schema 相同）。
//
//  口径（每一条都刻意复用既有单一事实源，不另起一套）：
//  - 曲目：`getAllTracks()`（全部曲目行）；相对路径走 `SyncManifestGenerator.relativePath`
//    ——与 `SyncLocalLibraryScanner`（manifest 侧唯一入口）**同一口径**，不自己拼字符串。
//  - 指纹：直接用已取到的 `Track.contentHash` 列（与 `SyncContentHashResolver`（M4-2a）
//    查的是同一列同一行；此处行已在手，不再为每首歌发一次 SQL）。
//  - 歌手展示名：`getArtistDisplayNames(forTrackStableIds:fallbackArtistIdsByStableId:)`
//    （批量、内部按 500 分块、带简繁归一，与 Mac 侧选择区列表同口径）。
//  - 歌单：`getAllPlaylists()` 按 **slug** 作标识 + `getPlaylistItems()` 成员；
//    「收藏」用保留标识 `@favorites`（`getFavoriteTracks()`），显示名取既有本地化键
//    `sync_run_favorites`。
//  - 歌单 `trackCount` = **能在曲库里解析到的成员数**（成员表里已失联的行不算），
//    与 Mac 侧选择区 `SyncUIPlaylistOption.trackCount` 同口径；同时它等于
//    「按该歌单筛 tracks」的条数（UI 显示与筛选结果一致）。
//
//  ⚠️ 协议硬要求：**实现方必须不抛**——所有入口一律 `try?` 收口，查询失败按「查不到」
//  返回（空清单 / 跳过该条），绝不用 `try!`、绝不 `throw`。单条失败只跳过该条。
//
//  为什么放 `Services/` 而不是 `Mac/`：与 `DatabaseSyncCollectionFacts` 同理——
//  `QQPlayer/Mac/**` 被 iOS target 排除，放那里任何单测都碰不到；本类型是纯 DB 读，
//  放共享 Core 才能被 QQPlayerTests 真跑覆盖。
//

import Foundation

/// 生产实现：从 DB 取「对端内容清单」所需事实。
struct DatabaseSyncPeerLibraryFacts {
    let database: DatabaseManager
    /// 曲库根（相对路径基准；与 `MacSyncLibraryHost` / `SyncLibraryPassiveHost` 装配同源）。
    let libraryRoot: URL
    /// 「收藏」伪歌单显示名（默认走既有本地化键；测试可注入固定串）。
    let favoritesName: String

    init(
        database: DatabaseManager = .shared,
        libraryRoot: URL,
        favoritesName: String? = nil
    ) {
        self.database = database
        self.libraryRoot = libraryRoot
        self.favoritesName = favoritesName ?? "sync_run_favorites".localized
    }

    /// 应答路径用的惰性 provider（供被动端装配注入）。
    ///
    /// 为什么是闭包而不是立即构建的值：应答发生在会话线程（NW 队列）上，且一次
    /// 「浏览对端内容」只发少量请求——求值推迟到真有请求时，未使用本能力的会话零 DB 查询。
    static func catalogProvider(
        database: DatabaseManager = .shared,
        libraryRoot: URL,
        favoritesName: String? = nil
    ) -> () -> SyncPeerLibraryCatalog {
        let facts = DatabaseSyncPeerLibraryFacts(
            database: database,
            libraryRoot: libraryRoot,
            favoritesName: favoritesName
        )
        return { facts.catalog() }
    }

    /// 本端内容清单全量事实（歌单 + 曲目 + 歌单成员关系）。
    func catalog() -> SyncPeerLibraryCatalog {
        let tracks = (try? database.getAllTracks()) ?? []
        let artistNames = artistDisplayNames(for: tracks)

        var trackItems: [SyncPeerTrackItem] = []
        /// stableId → 相对路径（歌单成员展开用；同一 stableId 取首个 = 最早入库行）
        var pathByStableId: [String: String] = [:]
        for track in tracks {
            guard let relativePath = relativePath(of: track) else { continue }
            trackItems.append(
                SyncPeerTrackItem(
                    relativePath: relativePath,
                    title: track.title.isEmpty ? nil : track.title,
                    artistName: artistNames[track.stableId],
                    sizeBytes: max(0, track.fileSize ?? 0),
                    contentHash: normalizedHash(track.contentHash)
                )
            )
            if pathByStableId[track.stableId] == nil {
                pathByStableId[track.stableId] = relativePath
            }
        }

        var playlists: [SyncPeerPlaylistItem] = []
        var memberPathsByPlaylist: [String: Set<String>] = [:]

        // 决策 9：收藏视为特殊歌单（保留标识 `@favorites`）。
        if let favorites = try? database.getFavoriteTracks() {
            let paths = Set(favorites.compactMap { pathByStableId[$0.stableId] })
            playlists.append(
                SyncPeerPlaylistItem(
                    id: SyncCollectionSelection.favoritesPlaylistID,
                    name: favoritesName,
                    trackCount: paths.count
                )
            )
            memberPathsByPlaylist[SyncCollectionSelection.favoritesPlaylistID] = paths
        }

        if let allPlaylists = try? database.getAllPlaylists() {
            for playlist in allPlaylists {
                let slug = playlist.slug.trimmingCharacters(in: .whitespacesAndNewlines)
                guard SyncCollectionSelection.isValidPlaylistID(slug),
                      let rowID = playlist.id,
                      let items = try? database.getPlaylistItems(playlistId: rowID)
                else {
                    continue // 单条不成只跳过该歌单，不炸整批
                }
                let paths = Set(items.compactMap { pathByStableId[$0.trackStableId] })
                playlists.append(
                    SyncPeerPlaylistItem(id: slug, name: playlist.title, trackCount: paths.count)
                )
                // 同 slug 撞名（历史数据）→ 并集：多算条目是安全侧（多列几首），漏算是危险侧
                memberPathsByPlaylist[slug, default: []].formUnion(paths)
            }
        }

        return SyncPeerLibraryCatalog(
            playlists: playlists,
            tracks: trackItems,
            trackPathsByPlaylist: memberPathsByPlaylist,
            truncated: trackItems.count > SyncPeerLibraryCatalog.maxEntries
        )
    }

    // MARK: - 内部

    /// 一条 track 行 → 曲库内相对路径（不在根内 / 路径非法 → nil = 跳过该条）。
    private func relativePath(of track: Track) -> String? {
        SyncManifestGenerator.relativePath(
            of: URL(fileURLWithPath: track.path),
            baseDirectory: libraryRoot
        )
    }

    /// 空指纹归一为 nil（线上「未指纹」是 nil，不是空串——与 manifest 同口径）。
    private func normalizedHash(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// 批量取歌手展示名（失败 → 空表，标题照常给；绝不抛）。
    private func artistDisplayNames(for tracks: [Track]) -> [String: String] {
        let fallback = Dictionary(
            tracks.compactMap { track in track.artistId.map { (track.stableId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return (try? database.getArtistDisplayNames(
            forTrackStableIds: tracks.map(\.stableId),
            fallbackArtistIdsByStableId: fallback
        )) ?? [:]
    }
}
