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
    /// 曲库根（**必传**，2026-09-18 身份兜底包）：相对路径第一/第二身份的换算基准。
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

    /// 路径 → 身份（`track.path` 键形态 = 绝对路径）：先精确匹配，再退标准形态。
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
        if let row = try pathIdentityRow(db, atAbsolutePath: path) { return row }
        let standardized = DatabaseManager.standardizedPath(path)
        if standardized != path, let row = try pathIdentityRow(db, atAbsolutePath: standardized) { return row }
        return nil
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

    // MARK: 第二身份（曲库相对路径，2026-09-18 身份兜底包）

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
        if let ids = try distinctStableIdsRow(db, atAbsolutePath: path), !ids.isEmpty { return ids }
        let standardized = DatabaseManager.standardizedPath(path)
        if standardized != path, let ids = try distinctStableIdsRow(db, atAbsolutePath: standardized) {
            return ids
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

    /// 盘上绝对路径 → 曲库相对路径。换算一律走 `SyncManifestGenerator`（路径换算的
    /// 单一事实源）——本文件不得手写路径切片。
    static func relativePath(ofAbsoluteTrackPath path: String, libraryRoot: URL) -> String? {
        guard !path.isEmpty else { return nil }
        return SyncManifestGenerator.relativePath(
            of: URL(fileURLWithPath: path),
            baseDirectory: libraryRoot
        )
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

// MARK: - 行内歌曲引用提取

/// 从被同步实体行里提取"它引用的歌曲本地 stableId"；不引用歌曲的实体（歌单）返回 nil。
enum SyncTrackReference {
    /// 该实体是否引用歌曲（playlist 只是结构，不含歌曲键）。
    /// **派生自唯一声明处 `SyncEntityRegistry`**（每个实体的身份键要求登记在注册表里，
    /// 不再在这里手写判定表达式——INV-6 的风险点正是「新增实体忘表态 → 默认 true 被
    /// 判未定位」，现在漏登记会被 CI 的 `everyEntityCaseIsRegistered` 抓住）。
    static func referencesTrack(_ entity: SyncChangeEntity) -> Bool {
        SyncEntityRegistry.referencesTrack(entity)
    }

    /// 行内歌曲引用：优先取 row_key（跨端行键即承载引用），row_key 形态不符时回落
    /// 读 payload 快照。两者都取不到 = nil（该行没有可用歌曲键）。
    static func trackStableId(entity: SyncChangeEntity, rowKey: String, payloadJSON: String?) -> String? {
        switch entity {
        case .favorite, .playbackPosition:
            return rowKey.isEmpty ? nil : rowKey
        case .playHistory:
            // row_key = "\(trackStableId)|\(playedAt)"
            if let parsed = SyncChangeLogApplier.parseCompositeRowKey(rowKey) { return parsed.0 }
            return (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON))?.trackStableId
        case .playlistItem:
            // row_key = "\(playlistSlug)|\(trackStableId)"
            if let parsed = SyncChangeLogApplier.splitRowKey(rowKey) { return parsed.1 }
            return (try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON))?.trackStableId
        case .playlist:
            return nil
        }
    }
}

// MARK: - 本地化结果

/// 接收侧「未定位」的成因（面板/诊断用，单一事实源）。
enum SyncEntryUnresolvedReason: String, Equatable, Sendable {
    /// 该行引用歌曲，但线上 entry 没有可用身份键（contentHash nil/空）——无法定位
    /// 到本地歌曲（发送侧拿不到本地指纹，或对端是老 peer）。
    case missingIdentityKey = "missing_identity_key"
}

/// 接收侧一条线上 entry 的本地化结果。
enum SyncEntryLocalization: Equatable {
    /// 命中身份键（内容指纹或曲库相对路径）：row_key 与 payload 歌曲引用已改写为
    /// **本地 stableId**。
    case mapped(SyncChangeLogRow)
    /// 无需映射：该行不引用歌曲（歌单）/ 未知实体 → M4-1 原样透传应用。
    case passThrough(SyncChangeLogRow)
    /// 本地还没有这首歌（两把键都定位不到本地 stableId）→ 挂起，歌到后重放。
    /// `pendingKey` = 挂起表行键（命名空间见 `SyncPendingKey`；内容指纹 / `rel:{路径}`）。
    case suspended(pendingKey: String, remoteRow: SyncChangeLogRow)
    /// 第二身份（相对路径）命中**多行**（歧义）→ **不落库、不挂起**，只计数披露：
    /// 两首本地曲目同路径，选哪首都是猜；挂起也没意义（歌已在，再等也不会变唯一）。
    case ambiguous(key: SyncRemoteKey, candidateCount: Int, remoteRow: SyncChangeLogRow)
    /// 两把键都拿不到 → **不落库、不挂起**，只计数：落库会写出 JOIN track 永不匹配的
    /// 孤儿业务行（界面毫无变化却显示「应用 N 条」），挂起又无键可挂。
    case unresolved(reason: SyncEntryUnresolvedReason, remoteRow: SyncChangeLogRow)

    /// 本地化后的行（挂起/歧义/未定位分支 = 未改写的远端行，供挂起存储 / 诊断使用）。
    var row: SyncChangeLogRow {
        switch self {
        case .mapped(let row), .passThrough(let row), .suspended(_, let row),
             .ambiguous(_, _, let row), .unresolved(_, let row):
            return row
        }
    }
}

// MARK: - 发送侧身份缺口诊断

/// 发送侧一行「缺身份键」的诊断（只用于计数 / 日志，不上线）。
///
/// ⚠️ 口径（2026-09-18 身份兜底包）：**缺身份键 = 两把键都拿不到**。
/// 「有 track 行、指纹为空但相对路径算得出」**不再算缺键**——那时 wire entry 会带上
/// `relativePath`，对端靠第二身份照样能落库。
struct SyncWireMissingIdentity: Equatable, Sendable {
    /// 缺键成因（必须可区分，面板与修复手段都不同）。
    enum Reason: String, Equatable, Sendable {
        /// ① 行引用的 stableId 在本地 `track` 表里**没有行**（两把键都无从谈起）。
        case unknownTrack = "unknown_track"
        /// ② 有行，但指纹为空**且**相对路径也算不出（`track.path` 不在曲库根内 / 为空）。
        /// 修复手段 = 等指纹回填（或把文件放回曲库根），故与 ① 分开报。
        case emptyContentHash = "empty_content_hash"
    }

    var entity: String
    var rowKey: String
    var trackStableId: String
    var reason: Reason
}

/// 发送侧取数结果：wire 条目 + 缺身份键明细（`wireEntries` 签名不变，这是带诊断的入口）。
struct SyncWireEntryBatch: Equatable, Sendable {
    var entries: [SyncChangeLogWireEntry] = []
    var missingIdentity: [SyncWireMissingIdentity] = []
}

// MARK: - 收发两侧的映射变换

/// changeLog 帧的跨端映射变换（发送侧填身份键 / 接收侧本地化）。
struct SyncChangeLogMapper {
    let database: DatabaseManager
    /// 曲库根（**必传**）：相对路径第二身份的换算基准（传给唯一身份入口）。
    let libraryRoot: URL

    init(database: DatabaseManager, libraryRoot: URL) {
        self.database = database
        self.libraryRoot = libraryRoot
    }

    private var resolver: SyncContentHashResolver {
        SyncContentHashResolver(database: database, libraryRoot: libraryRoot)
    }

    // MARK: 发送侧

    /// outbox 行批 → wire entry 批（逐行按歌曲引用查 track 取 content_hash）。
    /// 一个读事务内完成，避免逐行开关事务。
    ///
    /// ⚠️ 签名保持（两端调用点都在用）；需要「哪些行缺身份键」时用
    /// `wireEntriesDetailed`（本方法就是它的 `.entries`，同一事实源）。
    func wireEntries(_ rows: [SyncChangeLogRow]) throws -> [SyncChangeLogWireEntry] {
        try wireEntriesDetailed(rows).entries
    }

    /// 带诊断的发送侧取数：wire 条目 + **缺身份键明细**（区分「本地没有该 track 行」
    /// 与「有行但指纹空且相对路径算不出」）。原实现静默填 nil、零计数，调用方（handlePull /
    /// sendIncrement）完全看不见缺口——这正是「同步成功但界面毫无变化」的发送侧成因。
    ///
    /// 取键一律走唯一身份入口 `remoteTrackIdentity`（不在此另写 track SQL）：
    /// - 入口返 nil（无 track 行） → 缺键（`.unknownTrack`）
    /// - 指纹可用 → 只填 `contentHash`（与今天逐字一致）
    /// - 指纹空但相对路径可用 → 只填 `relativePath`（**不算缺键**）
    /// - 两把键都无 → 缺键（`.emptyContentHash`）
    func wireEntriesDetailed(_ rows: [SyncChangeLogRow]) throws -> SyncWireEntryBatch {
        try database.read { db in
            var batch = SyncWireEntryBatch()
            batch.entries.reserveCapacity(rows.count)
            for row in rows {
                var identity: SyncRemoteTrackIdentity?
                if let entity = row.entityValue,
                   let trackStableId = SyncTrackReference.trackStableId(
                       entity: entity,
                       rowKey: row.rowKey,
                       payloadJSON: row.payloadJSON
                   ) {
                    identity = try SyncContentHashResolver.remoteTrackIdentity(
                        db,
                        forTrackStableId: trackStableId,
                        libraryRoot: libraryRoot
                    )
                    if let identity, identity.isEmpty {
                        batch.missingIdentity.append(SyncWireMissingIdentity(
                            entity: row.entity,
                            rowKey: row.rowKey,
                            trackStableId: trackStableId,
                            reason: .emptyContentHash
                        ))
                    } else if identity == nil {
                        batch.missingIdentity.append(SyncWireMissingIdentity(
                            entity: row.entity,
                            rowKey: row.rowKey,
                            trackStableId: trackStableId,
                            reason: .unknownTrack
                        ))
                    }
                }
                batch.entries.append(Self.wireEntry(
                    row,
                    contentHash: identity?.contentHash,
                    relativePath: identity?.relativePath
                ))
            }
            return batch
        }
    }

    /// 纯变换（无 IO；发送侧与测试共用）。
    /// `relativePath` 只在**第一身份缺失**时传入（调用方已按此收口；入口也不会同时给两把）。
    static func wireEntry(
        _ row: SyncChangeLogRow,
        contentHash: String?,
        relativePath: String? = nil
    ) -> SyncChangeLogWireEntry {
        SyncChangeLogWireEntry(
            id: row.id ?? 0,
            entity: row.entity,
            rowKey: row.rowKey,
            op: row.op,
            updatedAtMs: row.updatedAtMs,
            contentHash: contentHash,
            relativePath: contentHash == nil ? relativePath : nil,
            payloadJSON: row.payloadJSON
        )
    }

    // MARK: 接收侧

    /// 线上 entry → 本地化结果（见 SyncEntryLocalization）。
    ///
    /// 判定**全部**发生在唯一身份入口内部（`SyncIdentityResolving.localizeRemoteTrack`），
    /// 这里只把 (contentHash, relativePath) 打包交给入口、把 verdict 映射成落库动作。
    func localize(_ entry: SyncChangeLogWireEntry) throws -> SyncEntryLocalization {
        let remoteRow = Self.remoteRow(entry)
        guard let entity = SyncChangeEntity(rawValue: entry.entity) else {
            return .passThrough(remoteRow) // 未知实体：交对账/应用层按未知忽略
        }
        // 不引用歌曲（歌单）→ 没有跨端身份键也无所谓，原样透传
        guard SyncTrackReference.referencesTrack(entity) else {
            return .passThrough(remoteRow)
        }
        let identity = SyncRemoteTrackIdentity(
            contentHash: entry.contentHash,
            relativePath: entry.relativePath
        )
        switch try resolver.localizeRemoteTrack(identity) {
        case let .resolved(stableId, _):
            // 两把键命中都走同一改写（相对路径命中也必须改写 row_key/payload）。
            return .mapped(Self.rewrite(remoteRow, entity: entity, localStableId: stableId))
        case let .suspended(pendingKey):
            return .suspended(pendingKey: pendingKey, remoteRow: remoteRow)
        case let .ambiguous(key, candidateCount):
            return .ambiguous(key: key, candidateCount: candidateCount, remoteRow: remoteRow)
        case .unresolved:
            return .unresolved(reason: .missingIdentityKey, remoteRow: remoteRow)
        }
    }

    /// wire entry → 远端 outbox 行（保留远端 id：merge 排序键 (updated_at, id) 需要它）。
    static func remoteRow(_ entry: SyncChangeLogWireEntry) -> SyncChangeLogRow {
        SyncChangeLogRow(
            id: entry.id > 0 ? entry.id : nil,
            entity: SyncChangeEntity(rawValue: entry.entity) ?? .favorite,
            rowKey: entry.rowKey,
            op: SyncChangeOp(rawValue: entry.op) ?? .upsert,
            updatedAtMs: entry.updatedAtMs,
            payloadJSON: entry.payloadJSON
        )
    }

    // MARK: 本地化改写（row_key + payload 歌曲引用 → 本地 stableId）

    /// 把远端行的歌曲引用改写成本地 stableId。playlist 不改（无歌曲键）。
    /// 复合 row_key 的构造段（playedAt / playlistSlug）优先取 row_key，取不到时回落
    /// payload 快照；两者都取不到则只改写 payload 能改的部分（row_key 保持远端值，
    /// 应用层会因解析不出本地键而幂等跳过）。
    static func rewrite(
        _ row: SyncChangeLogRow,
        entity: SyncChangeEntity,
        localStableId: String
    ) -> SyncChangeLogRow {
        var rewritten = row
        switch entity {
        case .favorite:
            rewritten.rowKey = localStableId
            rewritten.payloadJSON = rewriteFavoritePayload(row.payloadJSON, localStableId)
        case .playHistory:
            let playedAt = SyncChangeLogApplier.parseCompositeRowKey(row.rowKey)?.1
                ?? (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: row.payloadJSON))?.playedAt
            guard let playedAt else { break }
            rewritten.rowKey = "\(localStableId)|\(playedAt)"
            rewritten.payloadJSON = rewritePlayHistoryPayload(row.payloadJSON, localStableId)
        case .playlistItem:
            let slug = SyncChangeLogApplier.splitRowKey(row.rowKey)?.0
                ?? (try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: row.payloadJSON))?.playlistSlug
            guard let slug else { break }
            rewritten.rowKey = "\(slug)|\(localStableId)"
            rewritten.payloadJSON = rewritePlaylistItemPayload(row.payloadJSON, localStableId)
        case .playbackPosition:
            rewritten.rowKey = localStableId
            rewritten.payloadJSON = rewritePlaybackPositionPayload(row.payloadJSON, localStableId)
        case .playlist:
            break
        }
        return rewritten
    }

    /// 以下 rewrite* 均：payload 存在且能解码 → 改歌曲引用后重编码；payload 为 nil
    /// （delete 行）或解码失败 → 原值返回（应用层已有对应错误处理，不在此吞掉语义）。
    private static func rewriteFavoritePayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncFavoriteSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlayHistoryPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlaylistItemPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlaybackPositionPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlaybackPositionSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }
}

// MARK: - T15b 出站悬空引用对账修复

/// 本端 `sync_outbox` **出站悬空引用**的对账修复入口。
///
/// 事故：本端 outbox 里的行引用的 `stable_id` 在本端 `track` 表查无此歌——容器路径
/// 变化后旧 stableId 失效，业务表被 `TrackIdentityMigration` 迁移过、**outbox 没有**。
/// 每轮同步这些行都拿不到 `contentHash` → 对端全部判「未定位」跳过
/// （`SyncEntryLocalization.unresolved`），一次都落不了库：白跑一批 + 面板永远橙。
///
/// 三态处理（**只动 `sync_outbox`**，绝不删/改任何业务行）：
/// - `play_history`：按 **`played_at` 对账**（本地 `play_history` 表里找「同 `played_at`
///   且 `track_stable_id` 在 track 表存在」的行）→ 命中就把 row_key 与 payload 的歌曲
///   引用改写为**当前** stableId（复用 `SyncChangeLogMapper.rewrite`，与接收侧本地化
///   同一变换）。这条路径能救回历史播放。
/// - `favorite` / `playlist_item`（没有可靠对账键）与对不上账的 play_history →
///   **不可修复**，从 `sync_outbox` 清理（否则每轮同步白跑、面板永远橙）。
/// - 引用键解析不出的行 → 计数跳过（判断不了，宁可不碰）。
///
/// 幂等 + 可重入：整趟在**一个写事务**内完成（中途崩溃不留半成品）；跑第二遍零改动。
/// 为什么清理而不是留着重试：这些行的引用键永久失效（重拉重推都拿不到指纹），
/// 留着只消耗每轮批次数与面板噪音；业务表里的同名孤儿由用户决定，不在本入口范围。
struct SyncChangeLogDanglingRepair {
    /// 计数（修复 / 清理 / 跳过 / 补发）。
    struct Report: Equatable, Sendable {
        /// 悬空引用被**改写**为当前可用 stableId 的行数（play_history 按 played_at 命中）。
        var repaired = 0
        /// 悬空引用**无法修复**、已从 `sync_outbox` 清理的行数。
        var cleaned = 0
        /// 悬空引用但本次**未动**的行数（引用键解析不出 → 无法判断，宁可不碰）。
        var skipped = 0
        /// 本地真值**补发**进 outbox 的行数（业务表有、outbox 没有对应 upsert）。
        var emitted = 0
        /// 补发时本地拿不到身份键的行数（track 行在、`content_hash` 空 = 缺指纹）：
        /// 行照样补发（它是本地真值），对端会按「未定位」披露。
        var emittedWithoutIdentity = 0
        /// 本地业务行引用的歌在 `track` 表查无（本地悬空）→ **不补发**、只计数。
        var skippedLocalDangling = 0

        var didChange: Bool { repaired > 0 || cleaned > 0 || emitted > 0 }

        /// 一行诊断文案（Mac / iOS 两个调用点共用，避免两份文案漂移）。
        var logText: String {
            "（修复=\(repaired) 清理=\(cleaned) 跳过=\(skipped)"
                + " 补发=\(emitted) 缺指纹=\(emittedWithoutIdentity)"
                + " 本地悬空=\(skippedLocalDangling)）"
        }
    }

    /// 参与修复的实体：引用歌曲、且对端靠稳定身份键定位的那几类。
    /// （`playlist` 不引用歌曲；`playback_position` 的本地载体不是 DB 行，都不在范围。）
    /// **派生自唯一声明处 `SyncEntityRegistry`**（见 `repairsDanglingReferences`）。
    static var repairableEntities: [SyncChangeEntity] { SyncEntityRegistry.danglingRepairableEntities }

    let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    @discardableResult
    func run() throws -> Report {
        try database.write { db in try Self.run(db) }
    }

    /// 事务内版本（测试可直接在内存库事务里调用）：**先修悬空引用，再补发本地真值**。
    /// 两步顺序有讲究——先清/改掉废行，补发阶段再判「outbox 里有没有这一条」，
    /// 否则刚被清掉的键会被误判成「已存在」。两步都在同一写事务内，幂等可重入。
    @discardableResult
    static func run(_ db: Database) throws -> Report {
        var report = try repairDanglingRows(db)
        let reconcile = try reconcileLocalTruth(db)
        report.emitted = reconcile.emitted
        report.emittedWithoutIdentity = reconcile.emittedWithoutIdentity
        report.skippedLocalDangling = reconcile.skippedLocalDangling
        return report
    }

    /// 第一步：出站**悬空引用**修复（只动 `sync_outbox`）。
    @discardableResult
    static func repairDanglingRows(_ db: Database) throws -> Report {
        var report = Report()
        let entityValues = repairableEntities.map(\.rawValue)
        let rows = try SyncChangeLogRow
            .filter(entityValues.contains(Column("entity")))
            .order(Column("id"))
            .fetchAll(db)
        for row in rows {
            guard let entity = row.entityValue, repairableEntities.contains(entity) else { continue }
            // 引用键解析不出（如 playlist_item 的 row_key 形态不符且 payload 缺失）→
            // 判断不了是否悬空，宁可不碰。
            guard let stableId = SyncTrackReference.trackStableId(
                entity: entity,
                rowKey: row.rowKey,
                payloadJSON: row.payloadJSON
            ), !stableId.isEmpty else {
                report.skipped += 1
                continue
            }
            // 引用在 track 表里有行（哪怕指纹为空 = 缺指纹，归 T13/T14）→ 不是悬空，不动。
            guard try isDangling(db, stableId: stableId) else { continue }

            if entity == .playHistory, let currentStableId = try currentPlayHistoryTrackStableId(db, row: row) {
                let rewritten = SyncChangeLogMapper.rewrite(row, entity: .playHistory, localStableId: currentStableId)
                guard rewritten != row else {
                    // 改写后逐字没变（理论不可达：旧键无 track 行、新键有）→ 当不可修复处理，
                    // 避免「计数说修了、实际没变」的假账。
                    try row.delete(db)
                    report.cleaned += 1
                    continue
                }
                try rewritten.update(db)
                report.repaired += 1
            } else {
                try row.delete(db)
                report.cleaned += 1
            }
        }
        return report
    }

    // MARK: - 判定

    /// 该 stableId 是否**悬空**（本端 track 表查无此歌）。
    /// 复用发送侧同一事实源：`.noTrackRow` = 悬空；`.emptyContentHash`（有行、指纹未回填）
    /// 只是「缺指纹」，不在本入口范围（T13/T14 口径）。
    private static func isDangling(_ db: Database, stableId: String) throws -> Bool {
        if case .noTrackRow = try SyncContentHashResolver.trackIdentity(db, forTrackStableId: stableId) {
            return true
        }
        return false
    }

    /// 按 `played_at` 对账：本地 `play_history` 表里「同 played_at 且 track_stable_id 在
    /// track 表存在」的首行（id 升序 → 同一输入确定性）→ 当前 stableId；对不上 = nil。
    ///
    /// 为什么 played_at 能当对账键：播放历史是**事件**，容器路径变化后 stableId 会重新
    /// 派生（TrackIdentityMigration），但事件的发生时间不变 → 用它把旧引用接回当前曲目。
    private static func currentPlayHistoryTrackStableId(_ db: Database, row: SyncChangeLogRow) throws -> String? {
        var playedAt = SyncChangeLogApplier.parseCompositeRowKey(row.rowKey)?.1
        if playedAt == nil {
            playedAt = (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: row.payloadJSON))?.playedAt
        }
        guard let playedAt else { return nil }
        let candidates = try String.fetchAll(
            db,
            sql: "SELECT track_stable_id FROM play_history WHERE played_at = ? ORDER BY id",
            arguments: [playedAt]
        )
        for candidate in candidates where !candidate.isEmpty {
            if try !isDangling(db, stableId: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 第二步：本地真值 → outbox 对账补发（T15b-2，2026-09-14）

    /// 参与补发的实体：本地载体是 DB 行的那几类。
    /// （`playlist` 结构行**不引用歌曲**，补发时不做身份判定；`playback_position`
    /// 本地载体不是 DB 行，不在范围。）
    /// **派生自唯一声明处 `SyncEntityRegistry`**（见 `reconcilesLocalTruth`）。
    static var reconcilableEntities: [SyncChangeEntity] { SyncEntityRegistry.reconcilableEntities }

    /// 把本端业务表里**现有**的真值，补进 `sync_outbox`（缺对应 upsert 行时才补）。
    ///
    /// 为什么需要它（2026-09-14 真机事故）：收藏 / 歌单成员 / 播放历史的 outbox 行可能
    /// **根本不存在**——① 在 outbox 机制建立之前产生的业务行；② 引用失效后被
    /// `repairDanglingRows` 清理掉的行（favorite / playlist_item 没有可靠对账键，只能清）。
    /// 两种情况下业务行都还在（用户看得见），同步层却永远看不到它 ⇒ 收藏「从来没同步过」
    /// 且零报错（面板不报、日志不报）。补发把本地现状重新变成一条可发送的变更。
    ///
    /// 判定口径（与发送侧同一事实源、与写入侧同一行键形态）：
    /// - 已有同实体同键的 `upsert` 行 → 不动。**delete 行不算**：v2 删除不上线、只做
    ///   批次抑制，所以「有 delete」不等于「这个事实已经进过 outbox」。
    /// - 引用歌在 `track` 表查无（本地悬空）→ **不补发**、计数 `skippedLocalDangling`
    ///   （补了也拿不到身份键，只会给对端添「未定位」噪音）。
    /// - 引用歌在表里但 `content_hash` 空（缺指纹）→ 照发，计数 `emittedWithoutIdentity`
    ///   （对端面板按「未定位」披露，不静默）。
    /// - `playlist` 是**结构行、不引用歌曲**：没有 track 身份键可判，跳过身份判定直
    ///   接补发，补发计数只计 `emitted`（不碰 `emittedWithoutIdentity` /
    ///   `skippedLocalDangling`）；folder-synced 歌单由本地扫描派生，与写入侧同一
    ///   口径不补。
    static func reconcileLocalTruth(_ db: Database) throws -> Report {
        var report = Report()
        var existing: [String: Set<String>] = [:]
        for entity in reconcilableEntities {
            let keys = try String.fetchAll(
                db,
                sql: "SELECT row_key FROM sync_outbox WHERE entity = ? AND op = ?",
                arguments: [entity.rawValue, SyncChangeOp.upsert.rawValue]
            )
            existing[entity.rawValue] = Set(keys)
        }
        var seen = Set<String>()

        /// 各实体的统一收口：去重 → 「已有 upsert 就跳过」→ 身份判定 → 补发 + 计数。
        /// 收在一处，避免每个分支各写一份判定而漂移。
        /// `requiresTrackIdentity = false`：不引用歌曲的结构实体（`playlist`）——没有
        /// 身份键可判，跳过身份判定，补发计数只计 `emitted`。
        func emit(
            entity: SyncChangeEntity,
            stableId: String,
            payloadJSON: String,
            requiresTrackIdentity: Bool = true
        ) throws {
            guard let key = Self.rowKey(entity: entity, stableId: stableId, payloadJSON: payloadJSON),
                  !key.isEmpty else { return }
            let dedupe = "\(entity.rawValue)|\(key)"
            guard seen.insert(dedupe).inserted else { return }
            guard existing[entity.rawValue]?.contains(key) != true else { return }
            var missingIdentity = false
            if requiresTrackIdentity {
                let identity = try SyncContentHashResolver.trackIdentity(db, forTrackStableId: stableId)
                if case .noTrackRow = identity {
                    report.skippedLocalDangling += 1
                    return
                }
                if case .emptyContentHash = identity { missingIdentity = true }
            }
            try SyncChangeLogStore.record(
                db,
                entity: entity,
                rowKey: key,
                op: .upsert,
                payloadJSON: payloadJSON
            )
            report.emitted += 1
            if missingIdentity { report.emittedWithoutIdentity += 1 }
        }

        // 歌单结构（row_key = slug）。**不引用歌曲** → 不做身份判定（见 emit 的
        // `requiresTrackIdentity`），载荷与写入侧 `createPlaylist` 逐字同形。
        // folder-synced 歌单内容由本地扫描派生（folder_path 是设备本地路径），
        // 不入跨端同步——与写入侧同一口径。
        let playlists = try Playlist
            .filter(Column("is_folder_synced") == false)
            .order(Column("slug"))
            .fetchAll(db)
        for playlist in playlists where !playlist.slug.isEmpty {
            let snapshot = SyncPlaylistSnapshot(
                slug: playlist.slug,
                title: playlist.title,
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt,
                lastPlayedAt: playlist.lastPlayedAt,
                folderPath: playlist.folderPath,
                isFolderSynced: playlist.isFolderSynced,
                lastFolderSync: playlist.lastFolderSync,
                customCoverImagePath: playlist.customCoverImagePath
            )
            try emit(
                entity: .playlist,
                stableId: playlist.slug,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot),
                requiresTrackIdentity: false
            )
        }

        // 收藏（row_key = track_stable_id）
        let favoriteIds = try String.fetchAll(
            db,
            sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id"
        )
        for stableId in favoriteIds where !stableId.isEmpty {
            let snapshot = SyncFavoriteSnapshot(trackStableId: stableId)
            try emit(
                entity: .favorite,
                stableId: stableId,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
        }

        // 歌单成员（row_key = slug|track_stable_id）。folder-synced 歌单内容由本地扫描
        // 派生（folder_path 是设备本地路径），不入跨端同步——与写入侧同一口径。
        let items = try Row.fetchAll(db, sql: """
        SELECT p.slug AS slug, pi.position AS position, pi.track_stable_id AS stable_id
        FROM playlist_item pi
        JOIN playlist p ON p.id = pi.playlist_id
        WHERE p.is_folder_synced = 0
        ORDER BY p.slug, pi.position
        """)
        for item in items {
            let slug: String = item["slug"]
            let stableId: String = item["stable_id"]
            let position: Int = item["position"]
            guard !slug.isEmpty, !stableId.isEmpty else { continue }
            let snapshot = SyncPlaylistItemSnapshot(
                playlistSlug: slug,
                position: position,
                trackStableId: stableId
            )
            try emit(
                entity: .playlistItem,
                stableId: stableId,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
        }

        // 播放历史（row_key = stableId|played_at）
        let history = try Row.fetchAll(db, sql: """
        SELECT track_stable_id AS stable_id, played_at AS played_at, play_duration_ms AS duration
        FROM play_history ORDER BY id
        """)
        for entry in history {
            let stableId: String = entry["stable_id"]
            guard !stableId.isEmpty else { continue }
            let playedAt: Int64 = entry["played_at"]
            let duration: Int64 = (entry["duration"] as Int64?) ?? 0
            let snapshot = SyncPlayHistorySnapshot(
                trackStableId: stableId,
                playedAt: playedAt,
                playDurationMs: duration
            )
            try emit(
                entity: .playHistory,
                stableId: stableId,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
        }
        return report
    }

    /// 补发行键：与写入侧 `SyncChangeLogStore.record` 的形态逐字对齐
    /// （favorite = stableId；play_history = stableId|playedAt；playlist = slug；
    /// playlist_item = slug|stableId）。从 payload 快照派生，避免每个分支各拼一次字符串。
    private static func rowKey(entity: SyncChangeEntity, stableId: String, payloadJSON: String) -> String? {
        switch entity {
        case .favorite:
            return SyncFavoriteSnapshot(trackStableId: stableId).rowKey
        case .playHistory:
            guard let snapshot = try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON) else {
                return nil
            }
            return snapshot.rowKey
        case .playlistItem:
            guard let snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON) else {
                return nil
            }
            return snapshot.rowKey
        case .playlist:
            guard let snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistSnapshot.self, from: payloadJSON) else {
                return nil
            }
            return snapshot.rowKey
        case .playbackPosition:
            return nil
        }
    }
}
