//
//  SmartPlaylistSourceResolver.swift
//  QQPlayer
//
//  S2 同步页「内容来源 → 成员曲目」的**生产解析实现**（DB 注入、共享 Core、**绝不抛**）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  职责
//  ════════════════════════════════════════════════════════════════════════════
//  `SyncBrowseSourceRef` → 该来源的成员曲目（`Track` 行）/ 成员相对路径集合。
//  两个消费方共用**同一份口径**，这是本文件存在的理由：
//  - 本端（Mac）同步页单曲来源列表：`MacSyncLocalContentProvider`
//  - 对端内容清单（帧 15/16）：`DatabaseSyncPeerLibraryFacts` 的 `@smart:*` 条目
//
//  口径（逐条复用既有单一事实源，不另起一套）：
//  - 自动歌单：`SmartPlaylistStore` 的 `from db` 版本（`recentAddedTracks` /
//    `recentPlayedTracks` / `topPlayedTracks`），limit = `SmartPlaylistStore.limit`
//    = 与播放列表页同一条数上限（本文件和播放列表页永远给同一批歌）。
//  - 收藏 / 真实歌单：与 `DatabaseSyncPeerLibraryFacts` 同口径——收藏走
//    `getFavoriteTracks()`；真实歌单按 **slug** 匹配 `getAllPlaylists()` 再取
//    `getPlaylistItems()` 成员，成员 stableId 经 `getAllTracks()` 索引解析成曲目行。
//  - 相对路径：一律 `SyncManifestGenerator.relativePath(of:baseDirectory:)`
//    ——与 manifest / 对端清单**同一口径**（绝不自己拼字符串）。
//
//  ⚠️ 协议硬要求：**实现方必须不抛**（同 `SyncCollectionFactsProviding`）——
//  所有入口 `try?` 收口，查询失败按「查不到」返回（空数组），绝不用 `try!`。
//  未知 / 非法标识 = 空集（**绝不回落全库**）。
//
//  为什么放 `Services/`（而不是 `Mac/`）：`QQPlayer/Mac/**` 被 iOS target 排除，
//  放那里任何单测都碰不到；本类型是纯 DB 读、平台无关，放共享 Core 才能被
//  QQPlayerTests 真跑覆盖。iOS 端同样需要它（iOS 也是被动应答端）。
//

import Foundation

/// 来源引用 → 成员曲目（生产实现）。
struct SmartPlaylistSourceResolver {
    let database: DatabaseManager
    /// 曲库根（相对路径基准；与 `MacSyncLibraryHost` / `SyncLibraryPassiveHost` 装配同源）。
    let libraryRoot: URL

    /// 缺省曲库根：macOS = `~/Music/QQPlayer`；iOS = 沙盒 `Documents/Music`（2026-09-22
    /// 曲库文件夹化起，曲库根不再是容器 Documents）。本类型是共享 Core（iOS 单测 target
    /// 也要编它），所以默认值必须分平台——`FileManager.homeDirectoryForCurrentUser`
    /// 在 iOS 上是 unavailable API。
    static var defaultLibraryRoot: URL {
        #if os(macOS)
            MusicFolderResolver.macDefaultFolderURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        #else
            MusicFolderResolver.iosMusicLibraryDirectoryURL()
        #endif
    }

    init(database: DatabaseManager = .shared, libraryRoot: URL = SmartPlaylistSourceResolver.defaultLibraryRoot) {
        self.database = database
        self.libraryRoot = libraryRoot
    }

    // MARK: - 成员曲目

    /// 来源的成员曲目行（顺序 = 来源自身定义序：收藏顺序 / 歌单成员序 /
    /// 自动歌单的排序语义；**相对路径集合请用 `relativePaths(for:)`**，那个是排序去重后的）。
    /// 未知 / 非法标识 → 空数组（不抛）。
    func tracks(for ref: SyncBrowseSourceRef) -> [Track] {
        switch ref.kind {
        case .library:
            return (try? database.getAllTracks()) ?? []
        case .favorites:
            return (try? database.getFavoriteTracks()) ?? []
        case .smart:
            return smartTracks(ref.smartKind)
        case .playlist:
            return playlistTracks(slug: ref.id)
        }
    }

    /// 来源的成员相对路径（**保持来源自身顺序**：自动歌单的语义序（最近添加 = 最新在前）、
    /// 收藏与真实歌单的成员序；去重保序，拿不到相对路径的曲目跳过）。
    ///
    /// 展示序用它（本端单曲列表 / 对端清单的 `trackPathsByPlaylist`）；两侧同一份实现
    /// → 同一个来源在两端给出同样的顺序（2026-09-13 统一：此前对端按路径升序返回，
    /// 与上传方向不一致）。
    func orderedRelativePaths(for ref: SyncBrowseSourceRef) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for track in tracks(for: ref) {
            guard let path = relativePath(of: track), seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// 来源的成员相对路径（升序、去重；拿不到相对路径的曲目跳过）。
    ///
    /// 只用于**集合/确定性**用途（如比较、集合相等）；展示序请用
    /// `orderedRelativePaths(for:)`。
    func relativePaths(for ref: SyncBrowseSourceRef) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for track in tracks(for: ref) {
            guard let path = relativePath(of: track), seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths.sorted()
    }

    /// 来源成员相对路径集合（集合口径；展示序见 `orderedRelativePaths(for:)`）。
    func pathSet(for ref: SyncBrowseSourceRef) -> Set<String> {
        Set(orderedRelativePaths(for: ref))
    }

    // MARK: - 内部

    /// 自动歌单（与播放列表页同一数据层、同一条数上限）。
    private func smartTracks(_ kind: SyncBrowseSmartKind?) -> [Track] {
        guard let kind else { return [] }
        let limit = SmartPlaylistStore.limit
        let tracks = try? database.read { db -> [Track] in
            switch kind {
            case .recentAdded:
                return try SmartPlaylistStore.recentAddedTracks(from: db, limit: limit)
            case .recentPlayed:
                return try SmartPlaylistStore.recentPlayedTracks(from: db, limit: limit)
            case .topPlayed:
                return try SmartPlaylistStore.topPlayedTracks(from: db, limit: limit).map(\.track)
            }
        }
        return tracks ?? []
    }

    /// 真实歌单：按 **slug** 匹配 → 成员 stableId → 曲目行（同一 stableId 取首个，
    /// 与 `DatabaseSyncPeerLibraryFacts` 的成员索引同口径）。
    private func playlistTracks(slug: String) -> [Track] {
        guard let playlists = try? database.getAllPlaylists(),
              let playlist = playlists.first(where: { $0.slug == slug }),
              let playlistRowID = playlist.id,
              let items = try? database.getPlaylistItems(playlistId: playlistRowID)
        else {
            return []
        }
        let byStableId = trackIndex()
        return items.compactMap { byStableId[$0.trackStableId] }
    }

    /// stableId → 曲目行（一次全表读，避免「每个成员一条 SQL」把主线程拖住）。
    private func trackIndex() -> [String: Track] {
        let tracks = (try? database.getAllTracks()) ?? []
        return Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 一条曲目行 → 曲库内相对路径（不在根内 / 路径非法 → nil = 跳过该条）。
    private func relativePath(of track: Track) -> String? {
        SyncManifestGenerator.relativePath(ofStoredTrackPath: track.path, libraryRoot: libraryRoot)
    }
}
