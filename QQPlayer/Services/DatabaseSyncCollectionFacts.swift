//
//  DatabaseSyncCollectionFacts.swift
//  QQPlayer
//
//  M6（T2，2026-09-11）同步集合**曲库事实的生产实现**（契约 C2，平台无关，可单测）。
//
//  背景：`SyncCollectionFactsProviding`（QQPlayer/Sync/SyncCollectionSelection.swift）
//  是选择集展开器取数的唯一注入点；此前全仓只有测试/harness 的内存实现
//  （QQPlayerTests `MemoryFacts`、scripts/sync-harness `HarnessSupport.swift`），
//  **App 内零实现** → M6 缺口 2。本文件补上生产实现。
//
//  口径（每一条都刻意复用既有单一事实源，不另起一套）：
//  - 歌单标识 → 曲目：`DatabaseManager.getAllPlaylists()` 按 **slug** 匹配
//    （slug 即 M4-1 changeLog playlist 行的 rowKey 形态，跨端可解释；
//    「收藏」用保留标识 `SyncCollectionSelection.favoritesPlaylistID` = `@favorites`，
//    走 `getFavoriteTracks()`）。
//  - 相对路径：`SyncManifestGenerator.relativePath(of:baseDirectory:)` —— 与
//    `SyncLocalLibraryScanner`（manifest 侧唯一入口）**同一口径**，不自己拼字符串。
//  - 内容指纹：M4-2a `SyncContentHashResolver`（stable_id → content_hash），
//    不新写 SQL；未指纹 = nil（展开器计入 `not_fingerprinted` 跳过）。
//  - 歌词：与 `MacSyncLibraryHost` / `SyncLocalLibraryDescriptor.live` 同一套路
//    （`AlignedLyricsStore.shared` 同根 + `@lyrics/{歌曲 content_hash}.json` 命名空间
//    + `SyncLyricsContentMapping.live(database:)` 映射）。
//
//  ⚠️ 协议硬要求（`SyncCollectionFactsProviding` 注释）：**实现方必须不抛**——
//  本文件所有入口一律 `try?` 收口，查询失败按「查不到」返回（nil / false），
//  绝不用 `try!`、绝不 `throw`。单条失败只跳过该条，不炸整批。
//
//  为什么放在 `Services/`（而不是 `Mac/`）：M6 契约 A3 —— `QQPlayer/Mac/**` 全部被
//  iOS target 排除，放那里任何单测都碰不到；本类型是**纯 DB 读、平台无关**，
//  放共享 Core 才能被 QQPlayerTests 真跑覆盖（先例：MacShortcutLogic /
//  DesktopWindowModeState）。
//

import Foundation

/// 生产实现：从 DB 取选择集展开所需的曲库事实。
struct DatabaseSyncCollectionFacts: SyncCollectionFactsProviding {
    let database: DatabaseManager
    /// 曲库根（相对路径基准；与 `MacSyncLibraryHost` / 生产装配同源）。
    let libraryRoot: URL
    let lyricsStore: AlignedLyricsStore
    let lyricsMapping: SyncLyricsContentMapping

    /// 缺省曲库根：macOS = `~/Music/QQPlayer`（与 `MacSyncLibraryHost` 同源）；
    /// iOS = 沙盒 Documents（M3-2 起 iOS 唯一音乐位置）。
    /// 本类型是共享 Core（iOS 单测 target 也要编它），所以默认值必须分平台——
    /// `FileManager.homeDirectoryForCurrentUser` 在 iOS 上是 unavailable API。
    static var defaultLibraryRoot: URL {
        #if os(macOS)
            MusicFolderResolver.macDefaultFolderURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        #else
            MusicFolderResolver.iosDocumentsDirectoryURL()
        #endif
    }

    init(
        database: DatabaseManager = .shared,
        libraryRoot: URL = DatabaseSyncCollectionFacts.defaultLibraryRoot,
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping? = nil
    ) {
        self.database = database
        self.libraryRoot = libraryRoot
        self.lyricsStore = lyricsStore
        // 默认与 SyncLocalLibraryDescriptor.live 同实现（M4-2a 映射），
        // 不另起一套 stableId ↔ content_hash 查询。
        self.lyricsMapping = lyricsMapping ?? .live(database: database)
    }

    // MARK: - SyncCollectionFactsProviding

    /// 歌单标识 → 歌单内曲目事实。
    /// - `@favorites` → 收藏曲目（`getFavoriteTracks()`，保持收藏顺序）
    /// - 其余 → `getAllPlaylists()` 里 **slug** 命中的歌单，再取成员曲目
    /// - nil = 歌单不存在 / 标识非法 / 查询失败（调用方按「未知歌单」记账并跳过）
    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? {
        let identifier = playlistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SyncCollectionSelection.isValidPlaylistID(identifier) else { return nil }

        if identifier == SyncCollectionSelection.favoritesPlaylistID {
            guard let favorites = try? database.getFavoriteTracks() else { return nil }
            return favorites.map(fact(forTrack:))
        }

        guard let playlists = try? database.getAllPlaylists(),
              let playlist = playlists.first(where: { $0.slug == identifier }),
              let playlistRowID = playlist.id,
              let items = try? database.getPlaylistItems(playlistId: playlistRowID)
        else {
            return nil
        }
        // 成员查不到曲目行（未入库 / 已删）→ 跳过该条（展开器另按未解析记账）。
        return items.compactMap { item in
            guard let track = (try? database.getTrack(byStableId: item.trackStableId)) ?? nil else {
                return nil
            }
            return fact(forTrack: track)
        }
    }

    /// 显式相对路径 → 曲目事实（未入库 / 非法路径 → nil）。
    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else {
            return nil
        }
        // track.path 存绝对路径；按曲库根相对化后的绝对路径精确查（curated 路径与
        // track.path 同源 = `SyncLocalLibraryScanner` 采集口径）。
        let absolutePath = libraryRoot.appendingPathComponent(normalized).path
        guard let track = (try? database.getTrack(byPath: absolutePath)) ?? nil else { return nil }
        return fact(forTrack: track)
    }

    /// 本端是否已有该 wire 歌词（`@lyrics/{歌曲 content_hash}.json`）。
    /// 与 manifest 侧 `SyncAlignedLyricsManifest.entries` 同口径：
    /// wire 路径 → 歌曲 content_hash → 本地 stableId → 歌词库存在性。
    func hasLyrics(atWirePath wirePath: String) -> Bool {
        guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
              let stableId = lyricsMapping.stableIdForContentHash(songHash),
              AlignedLyricsStore.isValidStableId(stableId)
        else {
            return false
        }
        return lyricsStore.contains(forStableId: stableId)
    }

    // MARK: - 内部

    /// 一条 track 行 → 曲目事实（相对路径口径 + M4-2a 指纹）。
    private func fact(forTrack track: Track) -> SyncCollectionTrackFact {
        SyncCollectionTrackFact(
            stableId: track.stableId,
            relativePath: SyncManifestGenerator.relativePath(
                of: URL(fileURLWithPath: track.path),
                baseDirectory: libraryRoot
            ),
            contentHash: contentHash(forTrackStableId: track.stableId)
        )
    }

    /// M4-2a 单一事实源：stable_id → content_hash（无此歌 / 未指纹 = nil）。
    private func contentHash(forTrackStableId stableId: String) -> String? {
        guard !stableId.isEmpty else { return nil }
        let resolver = SyncContentHashResolver(database: database)
        return (try? resolver.contentHash(forTrackStableId: stableId)) ?? nil
    }
}

// MARK: - 歌单成员表（T7b，2026-09-11）

extension DatabaseSyncCollectionFacts {
    /// 歌单标识 → 成员曲目 stableId 集合（**纯 DB 读、绝不抛**）。
    ///
    /// 为什么需要：会话侧应答 manifest 时用 `SyncCollection.filter(entries, members:)`
    /// 按歌单收口（T7 的 `.playlists` 请求）。此前 `SyncCollectionMembers` 全仓只有
    /// 默认空值，没有任何生产填充点 → `.playlists` 的 `selectedStableIds` 恒为空集 →
    /// 应答端回**空清单** → 「按歌单上传/下载」静默空转。本工厂是该成员表的
    /// **生产唯一构建点**（口径与 `tracks(inPlaylist:)` 逐条对齐，不另起一套查询）。
    ///
    /// 口径：
    /// - 真实歌单：`getAllPlaylists()` → **slug** 作标识（= M4-1 changeLog playlist
    ///   行的 rowKey 形态，跨端可解释），成员 = `getPlaylistItems()` 的 `trackStableId`
    /// - 收藏：保留标识 `SyncCollectionSelection.favoritesPlaylistID`（`@favorites`）
    ///   → `getFavoriteTracks()`
    /// - 空歌单 / 空收藏：**显式留键 + 空集**（消费方「查不到 = 空集」语义不变，
    ///   留键只为让调用方/诊断能区分「已知歌单但没歌」与「不知道这个歌单」）
    /// - 单条不成：slug 非法 / 无行 id / 成员查询抛错 → 只跳过该歌单，不炸整批
    /// - 全库查询失败（`getAllPlaylists` / `getFavoriteTracks` 抛错）→ 返回空成员表，
    ///   降级为「按歌单过滤不出内容」而不是崩（与 `SyncCollectionFactsProviding`
    ///   「实现方必须不抛」同口径）
    /// - 同 slug 撞名（历史数据）→ 并集：多算条目是安全侧（多传），漏算是危险侧
    static func buildMembers(database: DatabaseManager = .shared) -> SyncCollectionMembers {
        var stableIdsByPlaylist: [String: Set<String>] = [:]

        // 决策 9：收藏视为特殊歌单，走同一套展开规则。
        if let favorites = try? database.getFavoriteTracks() {
            stableIdsByPlaylist[SyncCollectionSelection.favoritesPlaylistID] =
                SyncCollectionMembers.includedStableIds(favorites.map(\.stableId))
        }

        if let playlists = try? database.getAllPlaylists() {
            for playlist in playlists {
                let slug = playlist.slug.trimmingCharacters(in: .whitespacesAndNewlines)
                guard SyncCollectionSelection.isValidPlaylistID(slug),
                      let playlistRowID = playlist.id,
                      let items = try? database.getPlaylistItems(playlistId: playlistRowID)
                else {
                    continue
                }
                stableIdsByPlaylist[slug, default: []].formUnion(
                    SyncCollectionMembers.includedStableIds(items.map(\.trackStableId))
                )
            }
        }

        return SyncCollectionMembers(stableIdsByPlaylist: stableIdsByPlaylist)
    }

    /// 应答路径用的**惰性**成员表 provider（供 descriptor 注入）。
    ///
    /// 为什么是闭包而不是立即构建的值：manifest 应答发生在会话线程（NW 队列）上，
    /// 且每次同步只请求一次 —— 求值必须推迟到真的需要（`.playlists` 集合）时，
    /// 让 `.all` / `.tracks` 请求零 DB 查询（见 `SyncLocalLibraryProvider.members(for:)`）。
    static func liveMembersProvider(
        database: DatabaseManager = .shared
    ) -> () -> SyncCollectionMembers {
        { buildMembers(database: database) }
    }
}

extension SyncCollectionMembers {
    /// 成员 stableId 归一：丢空串（空 stableId 不可能是成员，且会让 `selectedStableIds`
    /// 多出一个永不命中的键），保证集合内容确定。
    static func includedStableIds(_ raw: [String]) -> Set<String> {
        Set(raw.filter { !$0.isEmpty })
    }
}
