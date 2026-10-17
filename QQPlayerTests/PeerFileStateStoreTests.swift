//
//  PeerFileStateStoreTests.swift
//  QQPlayerTests
//
//  批 2：覆盖确认台账存储层（`sync_peer_file_state` + `PeerFileStateStore`）单测。
//
//  规格：`docs/lan-sync-design.md` §6.1（台账表 + 状态机）；契约 `docs/sync-contract.md`
//  §2 G；不变量 `docs/sync-invariants.md` §H INV-33。
//
//  ⚠️ 本套件**本地跑不了**（需要真 GRDB + xcodebuild；`scripts/run-local-sync-tests.sh` 的
//  swiftc 命令行按 blacklist 排除 `PeerFileStateStore.swift`）⇒ 只在 CI 真跑。
//
//  fixture 走 `DatabaseManager(dbWriter:)` 测试缝 + `createTables()`（内存库跑真实生产
//  建表路径），与 `SyncChangeLogStoreTests` 同口径。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct PeerFileStateStoreTests {
    // MARK: - Fixture

    private static let table = "sync_peer_file_state"

    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    private static func row(
        peer: String = "peer-1",
        path: String,
        hash: String,
        state: PeerFileStateRow.State,
        localHashAtDecision: String? = nil
    ) -> PeerFileStateRow {
        PeerFileStateRow(
            peerId: peer,
            relativePath: path,
            contentHash: hash,
            state: state,
            localHashAtDecision: localHashAtDecision
        )
    }

    // MARK: - 建表（DDL）

    @Test("建表：`sync_peer_file_state` 存在、列契约与主键符合 §6.1（幂等：连跑两次不炸）")
    func createTablesCreatesLedgerTable() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try manager.createTables() // 幂等：旧库下次启动自动补表语义
        try dbQueue.read { db in
            #expect(try db.tableExists(Self.table))
            let columns = try db.columns(in: Self.table).map(\.name)
            #expect(columns == [
                "peer_id", "relative_path", "content_hash",
                "local_hash_at_decision", "state", "updated_at_ms",
            ])
            // 主键 (peer_id, relative_path)：直接查 pragma（不依赖 ORM 辅助 API 的版本差异）
            let primaryKey = try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
                arguments: [Self.table]
            )
            #expect(primaryKey == ["peer_id", "relative_path"])
        }
    }

    // MARK: - upsert / load

    @Test("upsert → load：四种状态都往返一致（含 local_hash_at_decision = nil）")
    func upsertThenLoadRoundTrips() throws {
        let (manager, _) = try Self.makeManager()
        let store = PeerFileStateStore(database: manager)
        let rows = [
            Self.row(path: "A.flac", hash: "H1", state: .agreed),
            Self.row(path: "B.flac", hash: "H2", state: .pending),
            Self.row(path: "C.flac", hash: "P3", state: .approved, localHashAtDecision: "H3"),
            Self.row(path: "D.flac", hash: "P4", state: .kept, localHashAtDecision: "H4"),
        ]
        for row in rows { try store.upsert(row) }
        // load 按 relative_path 升序（判定输入顺序稳定）
        #expect(try store.load(peerId: "peer-1") == rows)
    }

    @Test("upsert 幂等：同 (peer_id, relative_path) 再写 → 只更新，不产生第二行")
    func upsertIsIdempotentOnPrimaryKey() throws {
        let (manager, dbQueue) = try Self.makeManager()
        let store = PeerFileStateStore(database: manager)
        try store.upsert(Self.row(path: "A.flac", hash: "P1", state: .pending))
        try store.upsert(Self.row(path: "A.flac", hash: "P1", state: .kept, localHashAtDecision: "H1"))
        try store.upsert(Self.row(path: "A.flac", hash: "P2", state: .approved, localHashAtDecision: "H2"))

        let loaded = try store.load(peerId: "peer-1")
        #expect(loaded.count == 1)
        #expect(loaded.first?.state == .approved)
        #expect(loaded.first?.contentHash == "P2")
        #expect(loaded.first?.localHashAtDecision == "H2")
        let total = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(Self.table)") }
        #expect(total == 1)
    }

    @Test("peer 隔离：load(peerId:) 只返回该 peer 的行；updated_at_ms 由存储层写入且非空")
    func loadIsScopedByPeerAndStampsUpdatedAt() throws {
        let (manager, dbQueue) = try Self.makeManager()
        let store = PeerFileStateStore(database: manager)
        try store.upsert(Self.row(peer: "peer-1", path: "A.flac", hash: "H1", state: .agreed))
        try store.upsert(Self.row(peer: "peer-2", path: "B.flac", hash: "H2", state: .kept, localHashAtDecision: "H2"))

        #expect(try store.load(peerId: "peer-1").map(\.relativePath) == ["A.flac"])
        #expect(try store.load(peerId: "peer-2").map(\.relativePath) == ["B.flac"])
        #expect(try store.load(peerId: "peer-unknown").isEmpty)

        let stamped = try dbQueue.read {
            try Int64.fetchOne($0, sql: "SELECT updated_at_ms FROM \(Self.table) WHERE relative_path = ?", arguments: ["A.flac"])
        }
        #expect(stamped != nil)
        #expect((stamped ?? 0) > 0)
    }

    @Test("脏数据防护：`state` 非法值（绕过存储层直接落库）→ load 丢弃该行，不喂给判定器")
    func loadDropsRowsWithUnknownState() throws {
        let (manager, dbQueue) = try Self.makeManager()
        let store = PeerFileStateStore(database: manager)
        try store.upsert(Self.row(path: "Good.flac", hash: "H1", state: .agreed))
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Self.table)
                    (peer_id, relative_path, content_hash, local_hash_at_decision, state, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["peer-1", "Bad.flac", "H9", nil, "bogus", 1]
            )
        }
        #expect(try store.load(peerId: "peer-1").map(\.relativePath) == ["Good.flac"])
    }

    @Test("deleteAll(peerId:)：只清该 peer 的行，返回删除行数")
    func deleteAllIsScopedByPeer() throws {
        let (manager, _) = try Self.makeManager()
        let store = PeerFileStateStore(database: manager)
        try store.upsert(Self.row(peer: "peer-1", path: "A.flac", hash: "H1", state: .agreed))
        try store.upsert(Self.row(peer: "peer-1", path: "B.flac", hash: "H2", state: .kept))
        try store.upsert(Self.row(peer: "peer-2", path: "C.flac", hash: "H3", state: .agreed))

        #expect(try store.deleteAll(peerId: "peer-1") == 2)
        #expect(try store.load(peerId: "peer-1").isEmpty)
        #expect(try store.load(peerId: "peer-2").count == 1)
        #expect(try store.deleteAll(peerId: "peer-1") == 0)
    }

    @Test("与判定器串起来：kept 行（对端 + 本端都未变）→ 静默跳过，不推不弹窗")
    func keptLedgerRowFeedsJudgeAsSkipped() throws {
        let (manager, _) = try Self.makeManager()
        let store = PeerFileStateStore(database: manager)
        try store.upsert(Self.row(path: "A.flac", hash: "P1", state: .kept, localHashAtDecision: "H1"))

        let decision = SyncFileOverwriteJudge.judge(
            toPush: ["A.flac"],
            local: [ManifestEntry(relativePath: "A.flac", size: 10, mtimeMs: 1_000, contentHash: "H1")],
            remote: [ManifestEntry(relativePath: "A.flac", size: 10, mtimeMs: 2_000, contentHash: "P1")],
            ledger: try store.load(peerId: "peer-1"),
            nowMs: 1_700_000_000_000
        )
        #expect(decision.skipped == ["A.flac"])
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.isEmpty)
    }
}
