//
//  SyncChangeLogStore.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）播放数据 LWW 同步的存储层：sync_outbox 追加 /
//  per-peer 游标 / 增量拉取。生产走 DatabaseManager 读写缝（shared / 注入内存
//  库测试），同 DeviceStore 惯例。纯存储无业务决策；对账合并见 SyncLWWReconcile.swift，
//  LWW 胜出后的本地应用见 SyncChangeLogApplier.swift。
//
//  事务纪律：业务写入点（favorite upsert/delete、PlayHistoryRecorder、歌单
//  增删改）在**同一 write 事务内**调 recordChange，outbox 与业务行原子提交——
//  绝不先改业务行后补 outbox（丢变更）或先记 outbox 后业务失败（假变更）。
//

import Foundation
@preconcurrency import GRDB

final class SyncChangeLogStore: @unchecked Sendable {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // MARK: - 追加变更（业务写点在同一事务内调用）

    /// 在调用方事务内追加一条 outbox 变更。updatedAtMs 缺省 = 当前毫秒。
    func record(
        _ db: Database,
        entity: SyncChangeEntity,
        rowKey: String,
        op: SyncChangeOp,
        payloadJSON: String?,
        updatedAtMs: Int64? = nil
    ) throws {
        let row = SyncChangeLogRow(
            entity: entity,
            rowKey: rowKey,
            op: op,
            updatedAtMs: updatedAtMs ?? Self.nowMs(),
            payloadJSON: payloadJSON
        )
        try row.insert(db)
    }

    /// 静态便捷入口：业务写点在各自 write 事务内直接调用（无需持 store 实例）。
    /// 语义与实例方法一致：**必须与业务行写入同一事务**，保证 outbox 与业务行原子提交。
    static func record(
        _ db: Database,
        entity: SyncChangeEntity,
        rowKey: String,
        op: SyncChangeOp,
        payloadJSON: String?,
        updatedAtMs: Int64? = nil
    ) throws {
        let row = SyncChangeLogRow(
            entity: entity,
            rowKey: rowKey,
            op: op,
            updatedAtMs: updatedAtMs ?? nowMs(),
            payloadJSON: payloadJSON
        )
        try row.insert(db)
    }

    /// 便捷重载：走 DatabaseManager.write（独立事务；仅用于非业务写点的事务外补记）。
    func record(
        entity: SyncChangeEntity,
        rowKey: String,
        op: SyncChangeOp,
        payloadJSON: String?,
        updatedAtMs: Int64? = nil
    ) throws {
        try database.write { db in
            try self.record(db, entity: entity, rowKey: rowKey, op: op, payloadJSON: payloadJSON, updatedAtMs: updatedAtMs)
        }
    }

    // MARK: - 游标

    /// 某 peer 已消费的本端 outbox 最大 id（无记录 = 0）。
    func cursor(forPeer peerID: String) throws -> Int64 {
        try database.read { db in
            try SyncPeerCursor
                .filter(Column("peer_id") == peerID)
                .fetchOne(db)?.lastOutboxID ?? 0
        }
    }

    /// 记录某 peer 已消费到的本端 outbox id（推送应答后推进；幂等 upsert）。
    func setCursor(forPeer peerID: String, lastOutboxID: Int64) throws {
        try database.write { db in
            try self.setCursor(db, forPeer: peerID, lastOutboxID: lastOutboxID)
        }
    }

    func setCursor(_ db: Database, forPeer peerID: String, lastOutboxID: Int64) throws {
        try SyncPeerCursor(peerID: peerID, lastOutboxID: lastOutboxID).upsert(db)
    }

    // MARK: - 增量拉取

    /// 取本端 outbox 中 id > cursor 的增量（升序，limit 分页上限）。
    func entries(after cursor: Int64, limit: Int = 500) throws -> [SyncChangeLogRow] {
        try database.read { db in
            try self.entries(db, after: cursor, limit: limit)
        }
    }

    func entries(_ db: Database, after cursor: Int64, limit: Int = 500) throws -> [SyncChangeLogRow] {
        try SyncChangeLogRow
            .filter(Column("id") > cursor)
            .order(Column("id"))
            .limit(limit)
            .fetchAll(db)
    }

    /// 本端 outbox 当前最大 id（无行 = 0）。推送方用它当 lastOutboxID。
    func maxOutboxID() throws -> Int64 {
        try database.read { db in
            try self.maxOutboxID(db)
        }
    }

    func maxOutboxID(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM sync_outbox") ?? 0
    }

    // MARK: - 全量查询（对账用：按 entity+row_key 取本端最新行）

    /// 按 (entity, row_key) 取本端最新一条 outbox（对账时代表本端该键的最新事实；
    /// updated_at 毫秒降序取首条）。
    func latestRow(entity: SyncChangeEntity, rowKey: String) throws -> SyncChangeLogRow? {
        try database.read { db in
            try self.latestRow(db, entity: entity, rowKey: rowKey)
        }
    }

    func latestRow(_ db: Database, entity: SyncChangeEntity, rowKey: String) throws -> SyncChangeLogRow? {
        try SyncChangeLogRow
            .filter(Column("entity") == entity.rawValue && Column("row_key") == rowKey)
            .order(Column("updated_at").desc, Column("id").desc)
            .fetchOne(db)
    }

    /// 取某个 (entity, row_key) 的全部 outbox 行（升序；对账组内比较用）。
    func rows(entity: SyncChangeEntity, rowKey: String) throws -> [SyncChangeLogRow] {
        try database.read { db in
            try self.rows(db, entity: entity, rowKey: rowKey)
        }
    }

    func rows(_ db: Database, entity: SyncChangeEntity, rowKey: String) throws -> [SyncChangeLogRow] {
        try SyncChangeLogRow
            .filter(Column("entity") == entity.rawValue && Column("row_key") == rowKey)
            .order(Column("id"))
            .fetchAll(db)
    }

    // MARK: - 时间

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
