//
//  SyncChangeLogPendingStore.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2a）挂起变更 + 重放：远端播放数据变更引用的歌曲本地还没有
//  时**不丢**——原样挂起在 sync_pending_change 表（行键 = 挂起键），等该歌曲入库
//  （Track 保存且带 content_hash / 或落在曲库相对路径上）后由 SyncChangeLogReplay
//  重新本地化 → LWW 对账 → 应用，成功后清理挂起行。
//
//  挂起键有两个命名空间（**构造/解析只在 `SyncPendingKey` 一处**）：
//  - 内容指纹（键 = content_hash 本身；**今天形态，历史库里的行原样可读**）
//  - 曲库相对路径（键 = `rel:{相对路径}`；第二身份，对端那行拿不到指纹时用）
//  表结构不变（`row_key` 是 TEXT，天然容纳）。
//
//  ⚠️ v2 语义修订（2026-09-10，docs/lan-sync-design.md §6.2 / §12b-7）：**不再有删除
//  传播**——挂起机制只服务"歌正在传输中、播放数据先到"的竞态兜底（只延迟应用、不删
//  数据）；delete 变更在 Peer 层就被拦掉，不会再进挂起表。SyncChangeLogReplay 对
//  历史遗留库里的 delete 挂起行做防御性跳过并清理（见其实现）。
//
//  语义：
//  - 挂起键 = (entity, content_hash, remote_row_key)：同一远端事实重复拉取时幂等
//    upsert，只在远端 updated_at 不更旧时覆盖（与 outbox 的"同键取最新"一致）。
//  - remote_row_key 保留远端原始行键：重放时 delete 要用它定位（favorite 的行键 =
//    远端 stableId 本身不带 payload），复合键（播放历史/歌单项）也要靠它拿
//    playedAt / playlistSlug 段。
//  - 重放幂等：应用后删除挂起行；重复调用无挂起行可处理 = 空操作。歌到位时若本端
//    同键有更新的变更（localWins），本端胜出、挂起行同样清理（本端事实会向对端收敛）。
//
//  新表在 DatabaseManager.createTables 建（幂等 IF NOT EXISTS，旧库启动自动补表，
//  同 sync_outbox/sync_cursor 模式）。
//

import Foundation
@preconcurrency import GRDB

/// sync_pending_change 一行：某个**挂起键**下挂起的一条远端变更。
struct SyncPendingChangeRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var id: Int64?
    /// 挂起键（命名空间见 `SyncPendingKey`，构造/解析只在那里）：
    /// 内容指纹（**今天形态**）或 `rel:{曲库相对路径}`（第二身份）。
    var rowKey: String
    /// 远端原始 row_key（重放时定位 delete / 重建复合键）。
    var remoteRowKey: String
    var entity: String
    var op: String
    var updatedAtMs: Int64
    var payloadJSON: String?

    static let databaseTableName = "sync_pending_change"

    enum CodingKeys: String, CodingKey {
        case id, entity, op
        case rowKey = "row_key"
        case remoteRowKey = "remote_row_key"
        case updatedAtMs = "updated_at"
        case payloadJSON = "payload_json"
    }

    var entityValue: SyncChangeEntity? { SyncChangeEntity(rawValue: entity) }
    var opValue: SyncChangeOp? { SyncChangeOp(rawValue: op) }
}

// MARK: - 挂起存储

final class SyncChangeLogPendingStore: @unchecked Sendable {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    /// 挂起一条远端行（幂等：同 (entity, 挂起键, remote_row_key) upsert）。
    /// `pendingKey` 由身份入口给出（`SyncPendingKey` 命名空间），本层不自拼字符串。
    func suspend(_ row: SyncChangeLogRow, pendingKey: String) throws {
        try database.write { db in
            try Self.suspend(db, row: row, pendingKey: pendingKey)
        }
    }

    /// 事务内版本（接收侧一批行共用一个写事务时用）。
    static func suspend(_ db: Database, row: SyncChangeLogRow, pendingKey: String) throws {
        guard !pendingKey.isEmpty else { return }
        try db.execute(
            sql: """
            INSERT INTO sync_pending_change (entity, row_key, remote_row_key, op, updated_at, payload_json)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity, row_key, remote_row_key) DO UPDATE SET
                op = excluded.op,
                updated_at = excluded.updated_at,
                payload_json = excluded.payload_json
            WHERE excluded.updated_at >= sync_pending_change.updated_at
            """,
            arguments: [row.entity, pendingKey, row.rowKey, row.op, row.updatedAtMs, row.payloadJSON]
        )
    }

    /// 某挂起键的全部挂起行（升序 = 挂起顺序）。
    func rows(forPendingKey pendingKey: String) throws -> [SyncPendingChangeRow] {
        try database.read { db in
            try Self.rows(db, forPendingKey: pendingKey)
        }
    }

    static func rows(_ db: Database, forPendingKey pendingKey: String) throws -> [SyncPendingChangeRow] {
        try SyncPendingChangeRow
            .filter(Column("row_key") == pendingKey)
            .order(Column("id"))
            .fetchAll(db)
    }

    /// 挂起行总数（测试/诊断）。
    func pendingCount() throws -> Int {
        try database.read { db in
            try Self.pendingCount(db)
        }
    }

    static func pendingCount(_ db: Database) throws -> Int {
        try SyncPendingChangeRow.fetchCount(db)
    }

    /// 删除已重放的挂起行（按行 id）。
    func delete(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in
            try Self.delete(db, ids: ids)
        }
    }

    static func delete(_ db: Database, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try SyncPendingChangeRow.filter(ids.contains(Column("id"))).deleteAll(db)
    }
}

// MARK: - 重放

/// 挂起重放：歌曲入库（Track 保存且带 content_hash）后把该 content_hash 的挂起变更
/// 本地化 → LWW 对账 → 应用远程胜出行 → 清理已处理挂起行。
///
/// 与 change_log_push 应用路径共用同一套映射 + 对账语义（SyncChangeLogMapper /
/// SyncLWWReconcile / SyncChangeLogApplier），因此重放结果与"该变更晚一步到达"等价。
///
/// v2（§12b-7）：只重放 upsert 挂起行；delete 挂起行（历史遗留）直接丢弃并清理，
/// 保证没有任何路径会让 delete 类变更被延后应用。
enum SyncChangeLogReplay {
    /// 重放某**挂起键**的挂起变更（两个命名空间同一入口：指纹 / `rel:{相对路径}`）。
    ///
    /// 挂起键 → 身份键组一律走 `SyncPendingKey.identity(fromPendingKey:)`（命名空间的
    /// 唯一解析处），再调身份入口判定 → 本文件不自己拼/解键。
    /// - Parameters:
    ///   - pendingKey: 挂起表行键（`SyncPendingKey` 命名空间）。
    ///   - libraryRoot: 曲库根（`rel:` 命名空间重放必需；身份入口的必传输入）。
    /// - Returns: 实际应用的业务行数（0 = 无挂起变更 / 本端胜出 / 仍挂起 / 歧义）。
    @discardableResult
    static func replay(pendingKey: String, database: DatabaseManager, libraryRoot: URL) throws -> Int {
        guard !pendingKey.isEmpty else { return 0 }
        let pendingStore = SyncChangeLogPendingStore(database: database)
        let pending = try pendingStore.rows(forPendingKey: pendingKey)
        guard !pending.isEmpty else { return 0 }

        let mapper = SyncChangeLogMapper(database: database, libraryRoot: libraryRoot)
        let logStore = SyncChangeLogStore(database: database)

        // 0) 防御（v2 §12b-7）：历史遗留库可能存有 delete 挂起行（旧语义下 delete 也会
        //    挂起）。删除不跨端传播 → 直接丢弃并清理，绝不本地化、绝不应用（也就不会
        //    删掉本地业务行）。
        let obsoleteDeleteIDs = pending.compactMap { item -> Int64? in
            SyncChangeLogDeletionPolicy.shouldIgnore(op: item.op) ? item.id : nil
        }
        if !obsoleteDeleteIDs.isEmpty {
            try pendingStore.delete(ids: obsoleteDeleteIDs)
            AppLog.info(.sync, "ℹ️ SyncChangeLogReplay: 丢弃 \(obsoleteDeleteIDs.count) 条历史 delete 挂起行（删除不跨端传播）")
        }
        let applicable = pending.filter { !SyncChangeLogDeletionPolicy.shouldIgnore(op: $0.op) }
        guard !applicable.isEmpty else { return 0 }

        // 0b) 挂起键 → 身份键组（非法键 = 回不到身份，保留挂起行并跳过：不可解释的键
        //     宁可不动，也不当成指纹硬查）。
        guard let identity = SyncPendingKey.identity(fromPendingKey: pendingKey) else {
            AppLog.warn(.sync, "⚠️ SyncChangeLogReplay: 挂起键不可解释，保留不动（key 前缀 \(String(pendingKey.prefix(16)))…）")
            return 0
        }

        // 1) 重新本地化（歌曲已入库，此时应能映射到本地 stableId）
        var localizable: [(pendingID: Int64, row: SyncChangeLogRow)] = []
        var ambiguousCount = 0
        for item in applicable {
            guard let id = item.id else { continue }
            let entry = SyncChangeLogWireEntry(
                id: 0,
                entity: item.entity,
                rowKey: item.remoteRowKey,
                op: item.op,
                updatedAtMs: item.updatedAtMs,
                contentHash: identity.contentHash,
                relativePath: identity.relativePath,
                payloadJSON: item.payloadJSON
            )
            switch try mapper.localize(entry) {
            case .mapped(let row), .passThrough(let row):
                localizable.append((id, row))
            case .suspended:
                continue // 仍映射不到（异常情形）：保留挂起行，下次再试
            case let .ambiguous(key, candidateCount, _):
                // 歧义：**不落库**（写脏行比不写更糟），也不删挂起行（不丢远端事实）——
                // 只计数 + 一行日志，等上层修复后重试。
                ambiguousCount += 1
                AppLog.warn(
                    .sync,
                    "⚠️ SyncChangeLogReplay: 身份歧义（\(key.rawValue) 命中 \(candidateCount) 首本地曲目）"
                        + "，不落库：entity=\(item.entity) rowKey=\(item.remoteRowKey)"
                )
            case .unresolved:
                continue // 键不可用（不可能：挂起键非空；到达即视为仍不可用）
            }
        }
        guard !localizable.isEmpty else { return 0 }
        _ = ambiguousCount

        // 2) 与本地 outbox 同键最新行对账（同 change_log_push）
        var localRows: [SyncChangeLogRow] = []
        for item in localizable {
            guard let entity = item.row.entityValue else { continue }
            if let local = try logStore.latestRow(entity: entity, rowKey: item.row.rowKey) {
                localRows.append(local)
            }
        }
        let merge = SyncLWWReconcile.merge(localRows: localRows, remoteRows: localizable.map(\.row))

        // 3) 应用远端胜出行（0 条 = 本端胜出，无需动作）
        let applier = SyncChangeLogApplier(database: database)
        let applied = try applier.apply(merge.applyRemote)

        // 4) 已处理的挂起行清理（无论本端/远端胜出：该远端事实已被消费）
        try pendingStore.delete(ids: localizable.map(\.pendingID))
        return applied
    }

    /// 歌曲入库后重放（`DatabaseManager.upsertTrack` 的触发点调它）：
    /// 把这首新到位的歌能解释的**两个命名空间**的挂起键都算出来逐个重放——
    /// ① 内容指纹（该歌的 `content_hash`）；② 曲库相对路径（`track.path` 换算到曲库根）。
    ///
    /// 为什么要两个：对端那行可能带的是指纹、也可能是第二身份（指纹缺失时）；只重放其一会
    /// 让另一半挂起行永远等人。相对路径算不出（歌不在曲库根内）= 本端也没有该键，跳过。
    /// - Returns: 实际应用的行数（各命名空间之和）。
    @discardableResult
    static func replayAfterTrackSave(
        contentHash: String?,
        absolutePath: String,
        database: DatabaseManager,
        libraryRoot: URL
    ) throws -> Int {
        var applied = 0
        if let contentHash, !contentHash.isEmpty {
            applied += try replay(
                pendingKey: SyncPendingKey.contentHash(contentHash),
                database: database,
                libraryRoot: libraryRoot
            )
        }
        if let relativePath = SyncContentHashResolver.relativePath(
            ofAbsoluteTrackPath: absolutePath,
            libraryRoot: libraryRoot
        ) {
            applied += try replay(
                pendingKey: SyncPendingKey.relativePath(relativePath),
                database: database,
                libraryRoot: libraryRoot
            )
        }
        return applied
    }
}
