//
//  SyncChangeLogPendingStore.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2a）挂起变更 + 重放：远端播放数据变更引用的歌曲本地还没有
//  （content_hash 映射不到本地 stableId）时**不丢**——原样挂起在 sync_pending_change
//  表（行键 = content_hash），等该歌曲入库（Track 保存且带 content_hash）后由
//  SyncChangeLogReplay 重新本地化 → LWW 对账 → 应用，成功后清理挂起行。
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

/// sync_pending_change 一行：某个 content_hash 下挂起的一条远端变更。
struct SyncPendingChangeRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var id: Int64?
    /// 挂起键 = 远端 entry.contentHash（歌曲内容指纹）。
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

    /// 挂起一条远端行（幂等：同 (entity, content_hash, remote_row_key) upsert）。
    func suspend(_ row: SyncChangeLogRow, contentHash: String) throws {
        try database.write { db in
            try Self.suspend(db, row: row, contentHash: contentHash)
        }
    }

    /// 事务内版本（接收侧一批行共用一个写事务时用）。
    static func suspend(_ db: Database, row: SyncChangeLogRow, contentHash: String) throws {
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
            arguments: [row.entity, contentHash, row.rowKey, row.op, row.updatedAtMs, row.payloadJSON]
        )
    }

    /// 某 content_hash 的全部挂起行（升序 = 挂起顺序）。
    func rows(forContentHash contentHash: String) throws -> [SyncPendingChangeRow] {
        try database.read { db in
            try Self.rows(db, forContentHash: contentHash)
        }
    }

    static func rows(_ db: Database, forContentHash contentHash: String) throws -> [SyncPendingChangeRow] {
        try SyncPendingChangeRow
            .filter(Column("row_key") == contentHash)
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
    /// 重放某 content_hash 的挂起变更。
    /// - Returns: 实际应用的业务行数（0 = 无挂起变更 / 本端胜出）。
    @discardableResult
    static func replay(contentHash: String, database: DatabaseManager) throws -> Int {
        guard !contentHash.isEmpty else { return 0 }
        let pendingStore = SyncChangeLogPendingStore(database: database)
        let pending = try pendingStore.rows(forContentHash: contentHash)
        guard !pending.isEmpty else { return 0 }

        let mapper = SyncChangeLogMapper(database: database)
        let logStore = SyncChangeLogStore(database: database)

        // 0) 防御（v2 §12b-7）：历史遗留库可能存有 delete 挂起行（旧语义下 delete 也会
        //    挂起）。删除不跨端传播 → 直接丢弃并清理，绝不本地化、绝不应用（也就不会
        //    删掉本地业务行）。
        let obsoleteDeleteIDs = pending.compactMap { item -> Int64? in
            SyncChangeLogDeletionPolicy.shouldIgnore(op: item.op) ? item.id : nil
        }
        if !obsoleteDeleteIDs.isEmpty {
            try pendingStore.delete(ids: obsoleteDeleteIDs)
            print("ℹ️ SyncChangeLogReplay: 丢弃 \(obsoleteDeleteIDs.count) 条历史 delete 挂起行（删除不跨端传播）")
        }
        let applicable = pending.filter { !SyncChangeLogDeletionPolicy.shouldIgnore(op: $0.op) }
        guard !applicable.isEmpty else { return 0 }

        // 1) 重新本地化（歌曲已入库，此时应能映射到本地 stableId）
        var localizable: [(pendingID: Int64, row: SyncChangeLogRow)] = []
        for item in applicable {
            guard let id = item.id else { continue }
            let entry = SyncChangeLogWireEntry(
                id: 0,
                entity: item.entity,
                rowKey: item.remoteRowKey,
                op: item.op,
                updatedAtMs: item.updatedAtMs,
                contentHash: contentHash,
                payloadJSON: item.payloadJSON
            )
            switch try mapper.localize(entry) {
            case .mapped(let row), .passThrough(let row):
                localizable.append((id, row))
            case .suspended:
                continue // 仍映射不到（异常情形）：保留挂起行，下次再试
            }
        }
        guard !localizable.isEmpty else { return 0 }

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
}
