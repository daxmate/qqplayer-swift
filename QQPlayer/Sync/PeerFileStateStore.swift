//
//  PeerFileStateStore.swift
//  QQPlayer
//
//  同步覆盖确认台账 `sync_peer_file_state` 的存储层（批 2）：每 peer 一查，`(peer_id,
//  relative_path)` 主键幂等 upsert。
//
//  规格：`docs/lan-sync-design.md` §6.1（判定表 + 台账状态机）；契约 `docs/sync-contract.md`
//  §2 G；不变量 `docs/sync-invariants.md` §H INV-33。
//
//  边界：
//  - **只读写本表**，不判断、不决策（判据在 `SyncFileOverwriteJudge`）；
//  - 行模型 `PeerFileStateRow` 的**唯一定义**在 `PeerFileStateRow.swift`（零 GRDB）——
//    本文件只做 SQL 与列映射，不重复声明字段；
//  - `updated_at_ms` 由本层写入（落库时刻），不进行模型 —— 判定 7 条不消费它。
//
//  ⚠️ 本文件需要**真 GRDB**（`db.execute` / `Row`），编不进 `scripts/run-local-sync-tests.sh`
//  的 swiftc 命令行 ⇒ 已登记进 `scripts/sync-harness/blacklist.txt`；存储层用例只在 CI 跑
//  （本地无法真跑，见任务包验收第 7 条）。

import Foundation
@preconcurrency import GRDB

/// 台账（`sync_peer_file_state`）存储层：生产用 `.shared`，测试注入内存库。
final class PeerFileStateStore: @unchecked Sendable {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    /// 某 peer 的全部台账行（按 `relative_path` 升序 = 判定输入顺序稳定）。
    func load(peerId: String) throws -> [PeerFileStateRow] {
        try database.read { db in
            try Self.load(db, peerId: peerId)
        }
    }

    /// 事务内版本（调用方一批读写共用一个事务时用）。
    static func load(_ db: Database, peerId: String) throws -> [PeerFileStateRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT peer_id, relative_path, content_hash, local_hash_at_decision, state
            FROM sync_peer_file_state
            WHERE peer_id = ?
            ORDER BY relative_path
            """,
            arguments: [peerId]
        )
        return rows.compactMap(Self.row(from:))
    }

    /// 幂等 upsert（冲突目标 = 主键 `(peer_id, relative_path)`；`updated_at_ms` 恒刷为当前时刻）。
    func upsert(_ row: PeerFileStateRow) throws {
        try database.write { db in
            try Self.upsert(db, row)
        }
    }

    /// 事务内版本。
    static func upsert(_ db: Database, _ row: PeerFileStateRow) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_peer_file_state
                (peer_id, relative_path, content_hash, local_hash_at_decision, state, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(peer_id, relative_path) DO UPDATE SET
                content_hash = excluded.content_hash,
                local_hash_at_decision = excluded.local_hash_at_decision,
                state = excluded.state,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                row.peerId,
                row.relativePath,
                row.contentHash,
                row.localHashAtDecision,
                row.state.rawValue,
                Self.nowMs(),
            ]
        )
    }

    /// 清掉某 peer 的全部台账行（解绑 / 重配对时清账），返回删除行数。
    @discardableResult
    func deleteAll(peerId: String) throws -> Int {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM sync_peer_file_state WHERE peer_id = ?",
                arguments: [peerId]
            )
            return db.changesCount
        }
    }

    // MARK: - 列映射

    /// 一行 → 模型（`state` 非法值 ⇒ 丢弃该行：不拿脏状态喂判定器）。
    private static func row(from row: Row) -> PeerFileStateRow? {
        guard let peerId = row["peer_id"] as String?,
              let relativePath = row["relative_path"] as String?,
              let contentHash = row["content_hash"] as String?,
              let stateRaw = row["state"] as String?,
              let state = PeerFileStateRow.State(rawValue: stateRaw)
        else { return nil }
        return PeerFileStateRow(
            peerId: peerId,
            relativePath: relativePath,
            contentHash: contentHash,
            state: state,
            localHashAtDecision: row["local_hash_at_decision"] as String?
        )
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
