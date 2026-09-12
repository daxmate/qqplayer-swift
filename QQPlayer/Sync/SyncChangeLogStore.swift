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

/// 对账键引用（(entity, row_key)）；批量取本端最新行用（见 `latestRows(for:)`）。
struct SyncChangeLogRef: Hashable, Sendable {
    var entity: SyncChangeEntity
    var rowKey: String
}

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

    /// 一页增量 + **本批实际末行 id**（拉取应答的游标口径，S1 修复的载体）。
    ///
    /// 两件东西必须在**同一读事务**内取（见 `page(after:limit:)`）：分两次独立查询时，
    /// 两步之间并发落库的新行会被「末尾值」越过去——游标一旦推过去永不回头，
    /// 那些行永久不再同步。
    struct SyncChangeLogPage: Equatable, Sendable {
        /// 本批行（outbox id 升序；空 = 无增量）。
        var rows: [SyncChangeLogRow]
        /// 游标应推进到的位置 = **本批实际最后一行的 id**；空批 = 传入的 cursor（不推进）。
        var lastOutboxID: Int64
    }

    /// 取一页增量 + 该页末行 id：**同一读事务**内完成（无并发窗口）。
    ///
    /// `lastOutboxID` 只到本批实际发出去的最后一行：批外的新行留给下一轮，
    /// 绝不被越过；批内被删除策略过滤掉的行（delete）算在本批内，允许被越过
    /// （它们永不上线、也永不重发）。
    func page(after cursor: Int64, limit: Int = 500) throws -> SyncChangeLogPage {
        try database.read { db in
            try self.page(db, after: cursor, limit: limit)
        }
    }

    func page(_ db: Database, after cursor: Int64, limit: Int = 500) throws -> SyncChangeLogPage {
        let rows = try entries(db, after: cursor, limit: limit)
        // 空批 = 没有可确认的增量 → 游标保持不动（不推进到「当前 outbox 末尾」：
        // 并发落库的新行 id 可能已大于 cursor，推过去就等于把它们丢在身后）。
        return SyncChangeLogPage(rows: rows, lastOutboxID: rows.last?.id ?? cursor)
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

    /// 批量取本端这些 (entity, row_key) 的最新一行（对账代表本端事实）。
    ///
    /// S4（2026-09-12 审计）：`SyncChangeLogPeer.handlePush` 原先逐行调 `latestRow`
    /// = N+1 查询（每行一次）；这里按 entity 分组各发一条 `row_key IN (…)` 查询
    /// （远端批 ≤ 500 行、entity 只有 4 种 → ≤ 4 条查询）。
    ///
    /// 取值口径与 `latestRow(entity:rowKey:)` **逐字一致**（updated_at, id 降序首条）；
    /// 本端没有的键不出现在结果里（调用方据此跳过该远端行，语义同旧逐行查询）。
    func latestRows(for refs: [SyncChangeLogRef]) throws -> [SyncChangeLogRef: SyncChangeLogRow] {
        guard !refs.isEmpty else { return [:] }
        return try database.read { db in
            try self.latestRows(db, for: refs)
        }
    }

    func latestRows(
        _ db: Database,
        for refs: [SyncChangeLogRef]
    ) throws -> [SyncChangeLogRef: SyncChangeLogRow] {
        guard !refs.isEmpty else { return [:] }
        var result: [SyncChangeLogRef: SyncChangeLogRow] = [:]
        for (entity, group) in Dictionary(grouping: Set(refs), by: \.entity) {
            let rowKeys = group.map(\.rowKey)
            let rows = try SyncChangeLogRow
                .filter(Column("entity") == entity.rawValue && rowKeys.contains(Column("row_key")))
                .order(Column("updated_at").desc, Column("id").desc)
                .fetchAll(db)
            // 降序 → 每个键首次出现即最新行
            for row in rows where result[SyncChangeLogRef(entity: entity, rowKey: row.rowKey)] == nil {
                result[SyncChangeLogRef(entity: entity, rowKey: row.rowKey)] = row
            }
        }
        return result
    }

    // MARK: - 时间

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
