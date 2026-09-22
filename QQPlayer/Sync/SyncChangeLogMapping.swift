//
//  SyncChangeLogMapping.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2a）跨端歌曲引用映射收口：本地 stable_id ↔ content_hash
//  双向解析 + 线上 entry 的本地化改写。
//
//  ⚠️ v2 语义修订（2026-09-10，docs/lan-sync-design.md §6.2 / §12b-7）：**不再有删除
//  传播**——delete 变更在 SyncChangeLogPeer 层就被拦掉（发送侧过滤 / 接收侧忽略），
//  不会走到本文件的映射变换；本文件只对 upsert 行做映射。若被传入 delete 行，仍按
//  原样变换（纯 op 无关变换），但这不是任何生产路径。
//
//  语义（docs/lan-sync-design.md §6.2："跨端同步载荷引用 content_hash，同步层
//  做双向映射"）：
//  - 发送侧（SyncChangeLogPeer.handlePull）：outbox 行 → wire entry 时按行内歌曲
//    引用（row_key / payload 的 track_stable_id）查 track 表取 content_hash 填入
//    wire entry.contentHash；该行不引用歌曲（歌单）/ 引用歌不在本端 / 指纹为空
//    → contentHash = nil。wire 的 row_key 与 payload 仍是**发送端本地 stableId**
//    （v1 线上格式与 M4-1 一致，老 peer 可平滑互通），接收端靠 contentHash 本地化。
//  - 接收侧：contentHash → 本地 stableId（查 track by content_hash）。命中则把
//    row_key 与 payload 内的歌曲引用改写成本地 stableId 再进 LWW 对账——LWW 键 =
//    (entity, row_key)，同一个收藏/播放历史在两端 stableId 不同，不先本地化就
//    对不上键（各记一条、永不收敛）。本地还没有这首歌 → 挂起（见
//    SyncChangeLogPendingStore.swift），歌到位后重放，不丢数据。
//  - 透传：contentHash 为 nil 但该行**不引用歌曲**（歌单）/ 未知实体 → 无需跨端
//    身份键，按 M4-1 原样透传应用。
//  - 未定位（`.unresolved`，2026-09-14 身份缺口包）：**引用歌曲**却没有可用身份键
//    （contentHash nil/空）→ 无法定位到本地歌曲：既不落库也不挂起（挂起键 =
//    content_hash，这里没有），由调用方计数 + 面板披露。此前这类行被当「老 peer」
//    透传应用，写出 `track_stable_id` 是**对端** stableId 的孤儿业务行——最近播放 /
//    常听排行是 `JOIN track ON t.stable_id = h.track_stable_id`，永远匹配不上，
//    界面毫无变化而面板显示「应用 N 条」（2026-09-14 maintainer 实锤）。
//  - 发送侧欠账披露：`wireEntriesDetailed`（本文件）在填 contentHash 的同时记下
//    「缺身份键」明细，区分「本地没有该 track 行」与「有行但指纹为空」两种成因，
//    供会话层面板披露（见 SyncChangeLogPeer 的回调 / SyncDataSyncReport）。
//
//  T15b（2026-09-14）：本文件末尾新增 `SyncChangeLogDanglingRepair`（本端 outbox
//  **出站悬空引用**的对账修复）。为什么放本文件：它的两个关键判定都直接复用本文件的单一
//  事实源（`SyncContentHashResolver.trackIdentity` 判悬空、`SyncChangeLogMapper.rewrite`
//  改写引用），且新开文件需改 pbxproj 目标成员名单（本包禁止）——修复入口与它所镜像的
//  「接收侧本地化」放在一起，行为对照最直观。
//
//  T15b-2（2026-09-14 真机事故：收藏「从来没同步过」）：`run()` = 两步——
//  ① `repairDanglingRows`（修/清悬空引用，见上）；② `reconcileLocalTruth`（把业务表里
//  **现有**的收藏 / 歌单成员 / 播放历史补进 outbox：outbox 没有对应 upsert 就补一条）。
//  没有第二步时，favorite / playlist_item 的废止 outbox 行被清掉后**不会重新产生**——
//  业务行还在（用户看得见）、同步层永远看不到它，且零报错。判定口径与发送侧同一事实源
//  （悬空不补、缺指纹照补并计数）。
//
//  本文件只做只读查询 + 纯变换，无写副作用；挂起/重放见
//  SyncChangeLogPendingStore.swift。
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · Sync/SyncChangeLogMapper.swift             — 收发两侧映射变换（行内引用提取 / wire 打包 / 接收侧本地化）
//    · Services/SyncChangeLogDanglingRepair.swift — T15b 出站悬空引用对账修复
//

import Foundation
@preconcurrency import GRDB

// MARK: - 双向解析

/// 本地 stable_id ↔ content_hash 双向解析（只读查询）。
///
/// **本类型是全仓「歌曲身份解析」的唯一生产实现**（`SyncIdentityResolving`，见
/// `SyncAlignedLyrics.swift`）——全仓只有本文件允许出现 `track` 身份 SQL
/// （`stable_id ↔ content_hash` 两条查询）。新增消费点请依赖入口，别再写第二套。
struct SyncContentHashResolver {
    let database: DatabaseManager
    /// 曲库根（**必传**，2026-09-15 身份兜底包）：相对路径第一/第二身份的换算基准。
    /// 为什么做成必传而不是可选：可选 = 忘了传就编译得过、相对路径身份静默失效
    /// （「没有曲库根就构造不出解析器」应是编译期硬约束）；注入根也是测试隔离的手段。
    let libraryRoot: URL

    /// 本地 stableId → content_hash（无此歌 / 指纹未回填 = nil）。
    func contentHash(forTrackStableId stableId: String) throws -> String? {
        try database.read { db in
            try Self.contentHash(db, forTrackStableId: stableId)
        }
    }

    /// 事务内版本（发送侧一批行共用一个读事务时用）。
    static func contentHash(_ db: Database, forTrackStableId stableId: String) throws -> String? {
        guard !stableId.isEmpty else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT content_hash FROM track WHERE stable_id = ? LIMIT 1",
            arguments: [stableId]
        )
    }

    /// content_hash → 本地 stableId（无此歌 = nil）。
    /// 同 hash 多行（理论上不该有，重复路径审计后仍可能残留）取 id 最小 = 最早入库，
    /// 保证同一输入在两端都得到确定性结果。
    func trackStableId(forContentHash contentHash: String) throws -> String? {
        try database.read { db in
            try Self.trackStableId(db, forContentHash: contentHash)
        }
    }

    static func trackStableId(_ db: Database, forContentHash contentHash: String) throws -> String? {
        guard !contentHash.isEmpty else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT stable_id FROM track WHERE content_hash = ? ORDER BY id LIMIT 1",
            arguments: [contentHash]
        )
    }

    /// 路径 → 身份（入参 = 曲库内绝对路径，`track.path` 的**旧**键形态）：
    /// 按候选键依次精确匹配（存储形态优先，兼容旧行）。
    /// **不做** `getTrack(byPath:)` 的全表回落——同步线程（NW 队列）上不容忍 O(库) 扫描；
    /// 曲库清单里的路径与 `track.path` 同源（`SyncLocalLibraryScanner`），精确匹配即命中。
    func trackIdentity(atAbsolutePath path: String) throws -> (stableId: String, contentHash: String?)? {
        try database.read { db in
            try Self.trackIdentity(db, atAbsolutePath: path)
        }
    }

    /// 事务内版本（调用方已持有读事务时用）。
    static func trackIdentity(
        _ db: Database,
        atAbsolutePath path: String
    ) throws -> (stableId: String, contentHash: String?)? {
        for candidate in pathKeyCandidates(path) {
            if let row = try pathIdentityRow(db, atAbsolutePath: candidate) { return row }
        }
        return nil
    }

    /// 路径键候选（顺序即优先级）：**存储形态优先**，再原始入参、标准形态。
    ///
    /// 为什么要候选（2026-09-22 曲库文件夹化）：`track.path` 的存储形态已改成
    /// 「相对 Music 根的相对路径」，而同步侧的输入键一直是「曲库内绝对路径」
    /// （清单采集 / 相对路径换算而来）。同一首歌的两种拼法必须都命中，否则第一身份
    /// 与第二身份（相对路径兜底）都会静默失配。旧行（仍是绝对路径）也照常命中。
    private static func pathKeyCandidates(_ absolutePath: String) -> [String] {
        var candidates: [String] = []
        func append(_ value: String) {
            guard !value.isEmpty, !candidates.contains(value) else { return }
            candidates.append(value)
        }
        let stored = LibraryRoot.storedPath(forAbsolutePath: absolutePath)
        append(stored)
        append(DatabaseManager.standardizedStoredPath(stored))
        if stored != absolutePath {
            append(absolutePath)
            append(DatabaseManager.standardizedPath(absolutePath))
        }
        return candidates
    }

    /// 单条路径键查询（精确匹配；标准形态回落由调用方决定，见上）。
    private static func pathIdentityRow(
        _ db: Database,
        atAbsolutePath path: String
    ) throws -> (stableId: String, contentHash: String?)? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT stable_id, content_hash FROM track WHERE path = ? LIMIT 1",
            arguments: [path]
        )
        guard let row else { return nil }
        let stableId: String = row["stable_id"]
        let contentHash: String? = row["content_hash"]
        return (stableId: stableId, contentHash: contentHash)
    }

    // MARK: 第二身份（曲库相对路径，2026-09-15 身份兜底包）

    /// 远端身份键组 → 本端落点判定（解析顺序的唯一口径，详见协议注释）。
    func localizeRemoteTrack(_ identity: SyncRemoteTrackIdentity) throws -> SyncLocalTrackOutcome {
        // ① content_hash 存在 → **只用内容身份**（今天语义逐字不变；绝不再看相对路径）。
        if let contentHash = identity.contentHash, !contentHash.isEmpty {
            if let stableId = try trackStableId(forContentHash: contentHash) {
                return .resolved(stableId: stableId, key: .contentHash)
            }
            return .suspended(pendingKey: SyncPendingKey.contentHash(contentHash))
        }
        // ② 第一身份缺失 → 相对路径兜底（非法路径 = 视为无此键）。
        guard let raw = identity.relativePath, !raw.isEmpty,
              let normalized = SyncManifestGenerator.normalizeRelativePath(raw) else {
            return .unresolved
        }
        let absolutePath = libraryRoot.appendingPathComponent(normalized).path
        let candidates = try distinctStableIds(atAbsolutePath: absolutePath)
        switch candidates.count {
        case 0:
            return .suspended(pendingKey: SyncPendingKey.relativePath(normalized))
        case 1:
            return .resolved(stableId: candidates[0], key: .relativePath)
        default:
            // 多首本地曲目同路径（历史重导入残留）：选哪首都是猜 → 不落库、不挂起，只计数。
            return .ambiguous(key: .relativePath, candidateCount: candidates.count)
        }
    }

    /// 按绝对路径取**去重后**的本地 stableId（最多 2 条——只需要判「唯一 or 歧义」）。
    /// 同步线程（NW 队列）约束：不许全表扫描，所以仍走 `track.path` 上的精确匹配 +
    /// 标准形态回落（与 `trackIdentity(atAbsolutePath:)` 同一形态，不新开口径）。
    func distinctStableIds(atAbsolutePath path: String) throws -> [String] {
        try database.read { db in
            try Self.distinctStableIds(db, atAbsolutePath: path)
        }
    }

    static func distinctStableIds(_ db: Database, atAbsolutePath path: String) throws -> [String] {
        for candidate in pathKeyCandidates(path) {
            if let ids = try distinctStableIdsRow(db, atAbsolutePath: candidate), !ids.isEmpty {
                return ids
            }
        }
        return []
    }

    private static func distinctStableIdsRow(_ db: Database, atAbsolutePath path: String) throws -> [String]? {
        try String.fetchAll(
            db,
            sql: "SELECT DISTINCT stable_id FROM track WHERE path = ? ORDER BY stable_id LIMIT 2",
            arguments: [path]
        )
    }

    /// 本地 stableId → 身份键组（发送侧取数；详见协议注释）。
    /// `nil` = 本地 `track` 表没该行；非 nil 但 `isEmpty` = 有行但两把键都拿不到。
    func remoteTrackIdentity(forTrackStableId stableId: String) throws -> SyncRemoteTrackIdentity? {
        try database.read { db in
            try Self.remoteTrackIdentity(db, forTrackStableId: stableId, libraryRoot: libraryRoot)
        }
    }

    /// 事务内版本（发送侧一批行共用一个读事务时用）。
    static func remoteTrackIdentity(
        _ db: Database,
        forTrackStableId stableId: String,
        libraryRoot: URL
    ) throws -> SyncRemoteTrackIdentity? {
        guard !stableId.isEmpty else { return nil }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT path, content_hash FROM track WHERE stable_id = ? LIMIT 1",
            arguments: [stableId]
        ) else {
            return nil
        }
        let path: String = row["path"]
        let storedHash: String? = row["content_hash"]
        let contentHash = (storedHash?.isEmpty == false) ? storedHash : nil
        // 第一身份可用 → **不带**第二身份（省字节、防误用；与 wire 填键口径一致）。
        if contentHash != nil { return SyncRemoteTrackIdentity(contentHash: contentHash) }
        return SyncRemoteTrackIdentity(
            contentHash: nil,
            relativePath: relativePath(ofAbsoluteTrackPath: path, libraryRoot: libraryRoot)
        )
    }

    /// 盘上存储路径（`track.path`）→ 曲库相对路径。换算一律走 `SyncManifestGenerator`
    /// （路径换算的单一事实源）——本文件不得手写路径切片。
    static func relativePath(ofAbsoluteTrackPath path: String, libraryRoot: URL) -> String? {
        SyncManifestGenerator.relativePath(ofStoredTrackPath: path, libraryRoot: libraryRoot)
    }

    // MARK: 发送侧诊断用的三态查询

    /// 本地 stableId 的身份键三态：区分「没有 track 行」与「有行但指纹为空」。
    /// 两者都让 wire entry 的 contentHash 变 nil，但成因与修复手段不同
    /// （缺行 = 该键本地没这首歌；空指纹 = 等指纹回填），面板要分开报。
    enum TrackIdentity: Equatable {
        /// 本地 track 表没有该 stableId 的行。
        case noTrackRow
        /// 有行，但 content_hash 为空（指纹未回填）。
        case emptyContentHash
        /// 有行且指纹可用。
        case resolved(String)
    }

    static func trackIdentity(_ db: Database, forTrackStableId stableId: String) throws -> TrackIdentity {
        guard !stableId.isEmpty else { return .noTrackRow }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT content_hash FROM track WHERE stable_id = ? LIMIT 1",
            arguments: [stableId]
        ) else {
            return .noTrackRow
        }
        let hash: String? = row["content_hash"]
        guard let hash, !hash.isEmpty else { return .emptyContentHash }
        return .resolved(hash)
    }
}

// MARK: - 歌词同步映射的生产实现（M4-2b）

/// 身份入口的生产唯一实现（协议声明在 `SyncAlignedLyrics.swift`）。
/// 两条方法的 SQL 就在本类型里（下面），所以生产码不需要、也不允许第二处实现。
extension SyncContentHashResolver: SyncIdentityResolving {}

/// aligned 歌词随歌同步的 content_hash 映射：复用本文件上面的
/// `SyncContentHashResolver`（M4-2a），不新写 SQL。
extension SyncLyricsContentMapping {
    /// 生产实现：把唯一身份入口包成歌词链路的映射（查不到 / 指纹未回填 = nil，
    /// 与 M4-2a 同一语义）。
    /// `libraryRoot` = 曲库根（身份入口的必传输入，见 `SyncContentHashResolver`）。
    static func live(database: DatabaseManager, libraryRoot: URL) -> SyncLyricsContentMapping {
        SyncLyricsContentMapping(identity: SyncContentHashResolver(database: database, libraryRoot: libraryRoot))
    }
}
