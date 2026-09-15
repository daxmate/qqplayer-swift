//
//  SyncRelativePathIdentityTests.swift
//  QQPlayerTests
//
//  跨端身份兜底（2026-09-18）：**曲库相对路径当第二身份**。
//
//  背景：跨端身份键原先只有 `content_hash`。发送侧某行拿不到指纹（指纹未回填 / 本地无
//  track 行）时 wire entry 的 contentHash = nil → 接收侧判「未定位」（不落库、不挂起、
//  只计数）→ 用户的收藏 / 播放历史**永远过不了端**。相对路径是两端统一的跨端键
//  （Mac 推送文件时就是按相对路径落到 iOS 曲库），因此作为第二身份兜底。
//
//  形状（用户 2026-09-15 拍板）：判定**全部**发生在唯一身份入口
//  `SyncIdentityResolving.localizeRemoteTrack` 内部；`SyncChangeLogApplier` 里不得出现
//  任何身份兜底分支（本文件的形状用例与 `SyncWiringContractTests` 的静态契约一起锁）。
//
//  覆盖：解析顺序（内容指纹优先 / 相对路径兜底 / 歧义不落库 / 挂起命名空间）+
//  wire 加性字段双向兼容 + 挂起重放（rel: 命名空间）+ 新增结果类别账目。
//
//  fixture：DatabaseManager(dbWriter:) 内存库（不落盘：track 行直接写 SQL，
//  曲库根只当「路径 → 绝对路径」的换算基准，不需要真文件）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct SyncRelativePathIdentityTests {
    // MARK: - Fixture

    /// 曲库根（身份入口的必传输入）。不需要真目录：命中判定只查 DB 里的 `track.path`。
    private static let libraryRoot = URL(fileURLWithPath: "/library", isDirectory: true)

    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()
        return (manager, queue)
    }

    private static func insertTrack(
        _ db: Database,
        stableId: String,
        contentHash: String?,
        relativePath: String
    ) throws {
        try db.execute(
            sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
            arguments: [
                stableId,
                "T-\(stableId)",
                libraryRoot.appendingPathComponent(relativePath).path,
                contentHash,
            ]
        )
    }

    private static func resolver(_ manager: DatabaseManager) -> SyncContentHashResolver {
        SyncContentHashResolver(database: manager, libraryRoot: libraryRoot)
    }

    private static func mapper(_ manager: DatabaseManager) -> SyncChangeLogMapper {
        SyncChangeLogMapper(database: manager, libraryRoot: libraryRoot)
    }

    /// 一条收藏 wire entry（默认：远端 stableId + 两把键都无）。
    private static func favoriteEntry(
        contentHash: String? = nil,
        relativePath: String? = nil,
        rowKey: String = "remote-track",
        payloadJSON: String? = nil
    ) throws -> SyncChangeLogWireEntry {
        let payload: String?
        if let payloadJSON {
            payload = payloadJSON
        } else {
            payload = try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: rowKey))
        }
        return SyncChangeLogWireEntry(
            id: 7,
            entity: SyncChangeEntity.favorite.rawValue,
            rowKey: rowKey,
            op: SyncChangeOp.upsert.rawValue,
            updatedAtMs: 1000,
            contentHash: contentHash,
            relativePath: relativePath,
            payloadJSON: payload
        )
    }

    private static func favoriteIDs(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id")
        }
    }

    // MARK: - 1. 内容指纹优先（今天语义逐字不变）

    @Test("解析顺序：content_hash 命中 → resolved(.contentHash)，改写与今天逐字一致")
    func contentHashWinsAndRewrites() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-A", contentHash: "hash-A", relativePath: "Album/a.flac")
        }
        // 两个键都给（发送侧不会这么发，但入口必须按口径忽略相对路径）
        let entry = try Self.favoriteEntry(contentHash: "hash-A", relativePath: "Album/a.flac")
        let outcome = try Self.mapper(manager).localize(entry)
        guard case .mapped(let row) = outcome else {
            Issue.record("content_hash 命中应落库映射，实际 \(outcome)")
            return
        }
        #expect(row.rowKey == "local-A", "row_key 改写成本地 stableId")
        let payload = try SyncSnapshotCodec.decode(SyncFavoriteSnapshot.self, from: row.payloadJSON)
        #expect(payload.trackStableId == "local-A", "payload 歌曲引用同步改写")
        #expect(try Self.favoriteIDs(queue) == [], "本地化只变换行，不落库（落库由 applier 负责）")
    }

    @Test("解析顺序：content_hash 存在但本地无此歌 → 挂起（**绝不**改用相对路径）")
    func contentHashMissDoesNotFallBackToRelativePath() throws {
        let (manager, queue) = try Self.makeManager()
        // 本地确实有「同一相对路径」的歌，但内容指纹对不上 → 不能拿相对路径顶上
        // （内容身份优先：指纹不同 = 不是同一首歌，靠路径猜会把收藏挂到错歌）
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-other", contentHash: "hash-other", relativePath: "Album/a.flac")
        }
        let entry = try Self.favoriteEntry(contentHash: "hash-missing", relativePath: "Album/a.flac")
        let outcome = try Self.mapper(manager).localize(entry)
        guard case .suspended(let pendingKey, _) = outcome else {
            Issue.record("content_hash 本地无此歌应挂起，实际 \(outcome)")
            return
        }
        #expect(pendingKey == "hash-missing", "挂起键 = 指纹（今天形态）")
        #expect(pendingKey.hasPrefix("rel:") == false, "有 content_hash 时不得走相对路径命名空间")
    }

    @Test("发送侧：指纹空但相对路径算得出 → 填 relativePath 且**不算**缺身份键")
    func wireEntriesFillRelativePathWhenFingerprintMissing() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-A", contentHash: nil, relativePath: "Album/a.flac")
        }
        let rows = [SyncChangeLogRow(entity: .favorite, rowKey: "local-A", op: .upsert, updatedAtMs: 1)]
        let batch = try Self.mapper(manager).wireEntriesDetailed(rows)
        #expect(batch.missingIdentity.isEmpty, "有第二身份就不算缺键（对端靠相对路径能落库）")
        #expect(batch.entries.count == 1)
        #expect(batch.entries[0].contentHash == nil)
        #expect(batch.entries[0].relativePath == "Album/a.flac")
    }

    @Test("发送侧：指纹可用时**不带**相对路径（省字节、防误用）")
    func wireEntriesOmitRelativePathWhenFingerprintPresent() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-A", contentHash: "hash-A", relativePath: "Album/a.flac")
        }
        let rows = [SyncChangeLogRow(entity: .favorite, rowKey: "local-A", op: .upsert, updatedAtMs: 1)]
        let batch = try Self.mapper(manager).wireEntriesDetailed(rows)
        #expect(batch.entries[0].contentHash == "hash-A")
        #expect(batch.entries[0].relativePath == nil)
    }

    @Test("发送侧：两把键都拿不到才算缺键（成因区分 无 track 行 / 有行但都算不出）")
    func wireEntriesReportMissingIdentityOnlyWhenBothKeysMissing() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            // 有行，但 path 在曲库根之外（相对路径算不出）且指纹为空
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: ["outside", "T", "/elsewhere/x.flac", nil]
            )
        }
        let rows = [
            SyncChangeLogRow(entity: .favorite, rowKey: "ghost", op: .upsert, updatedAtMs: 1),
            SyncChangeLogRow(entity: .favorite, rowKey: "outside", op: .upsert, updatedAtMs: 2),
        ]
        let batch = try Self.mapper(manager).wireEntriesDetailed(rows)
        #expect(batch.missingIdentity.count == 2)
        #expect(batch.missingIdentity.map(\.reason) == [.unknownTrack, .emptyContentHash])
        #expect(batch.entries.allSatisfy { $0.contentHash == nil && $0.relativePath == nil })
    }

    // MARK: - 2. 相对路径兜底

    @Test("相对路径唯一命中 → resolved(.relativePath) 且 row_key / payload 改写正确")
    func relativePathResolvesAndRewrites() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-A", contentHash: nil, relativePath: "Album/a.flac")
        }
        let entry = try Self.favoriteEntry(relativePath: "Album/a.flac", rowKey: "remote-A")
        let outcome = try Self.mapper(manager).localize(entry)
        guard case .mapped(let row) = outcome else {
            Issue.record("相对路径唯一命中应落库映射，实际 \(outcome)")
            return
        }
        #expect(row.rowKey == "local-A", "相对路径命中也必须改写 row_key（否则 LWW 键对不上）")
        let payload = try SyncSnapshotCodec.decode(SyncFavoriteSnapshot.self, from: row.payloadJSON)
        #expect(payload.trackStableId == "local-A")
    }

    @Test("相对路径多候选 → ambiguous，且**业务表没有新行**（真查表）")
    func ambiguousRelativePathWritesNothing() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            // 同一个 path 两行（不同 stable_id）：历史重导入残留
            try Self.insertTrack(db, stableId: "local-1", contentHash: nil, relativePath: "Album/a.flac")
            try Self.insertTrack(db, stableId: "local-2", contentHash: nil, relativePath: "Album/a.flac")
        }
        let entry = try Self.favoriteEntry(relativePath: "Album/a.flac")
        let outcome = try Self.mapper(manager).localize(entry)
        guard case .ambiguous(let key, let candidateCount, let remoteRow) = outcome else {
            Issue.record("多候选应判歧义，实际 \(outcome)")
            return
        }
        #expect(key == .relativePath)
        #expect(candidateCount == 2)
        #expect(remoteRow.rowKey == "remote-track", "歧义分支保留远端行（诊断用），不改写")

        // 不落库：localize 根本没给出 `.mapped` 行 ⇒ 应用层拿不到它（没有第二条路）
        #expect(try Self.favoriteIDs(queue) == [], "歧义不得写任何业务行")
        // 也不挂起
        #expect(try SyncChangeLogPendingStore(database: manager).pendingCount() == 0, "歧义不挂起")
    }

    @Test("相对路径 0 命中 → 挂起，挂起键 = rel:{相对路径}")
    func relativePathMissSuspendsWithNamespaceKey() throws {
        let (manager, _) = try Self.makeManager()
        let entry = try Self.favoriteEntry(relativePath: "Album/not-yet.flac")
        let outcome = try Self.mapper(manager).localize(entry)
        guard case .suspended(let pendingKey, _) = outcome else {
            Issue.record("本地无此歌应挂起，实际 \(outcome)")
            return
        }
        #expect(pendingKey == "rel:Album/not-yet.flac", "挂起键带 rel: 命名空间前缀")
        let identity = try #require(SyncPendingKey.identity(fromPendingKey: pendingKey))
        #expect(identity.relativePath == "Album/not-yet.flac")
        #expect(identity.contentHash == nil)
    }

    @Test("两把键都无 → unresolved（不落库、不挂起）")
    func neitherKeyIsUnresolved() throws {
        let (manager, _) = try Self.makeManager()
        let entry = try Self.favoriteEntry()
        let outcome = try Self.mapper(manager).localize(entry)
        guard case .unresolved(let reason, _) = outcome else {
            Issue.record("两把键都无应判未定位，实际 \(outcome)")
            return
        }
        #expect(reason == .missingIdentityKey)
    }

    @Test("相对路径非法（绝对路径 / `..` / 空串）→ 视为无此键")
    func illegalRelativePathIsTreatedAsNoKey() throws {
        let (manager, _) = try Self.makeManager()
        let mapper = Self.mapper(manager)
        for illegal in ["/etc/passwd", "../escape.flac", "a/../../b.flac", "", "   "] {
            let outcome = try mapper.localize(try Self.favoriteEntry(relativePath: illegal))
            guard case .unresolved = outcome else {
                Issue.record("非法相对路径 `\(illegal)` 应视为无此键，实际 \(outcome)")
                continue
            }
        }
    }

    @Test("相对路径命中也走标准形态回落（与 trackIdentity(atAbsolutePath:) 同一口径）")
    func relativePathUsesStandardizedFallback() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            // 盘上（DB）路径是干净形态；根非规范（带 `/./`）⇒ 拼出来的绝对路径带冗余段 →
            // 走标准形态回落才能命中（曲库根本身可能来自用户设置里的非规范路径）。
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: ["local-std", "T", "/library/Album/a.flac", nil]
            )
        }
        let nonCanonicalRoot = URL(fileURLWithPath: "/library/./", isDirectory: true)
        let resolver = SyncContentHashResolver(database: manager, libraryRoot: nonCanonicalRoot)
        #expect(
            nonCanonicalRoot.appendingPathComponent("Album/a.flac").path != "/library/Album/a.flac",
            "前提不成立：非规范根拼出来的路径必须是冗余形态（否则这条用例没覆盖回落）"
        )
        let outcome = try resolver.localizeRemoteTrack(
            SyncRemoteTrackIdentity(relativePath: "Album/a.flac")
        )
        guard case .resolved(let stableId, let key) = outcome else {
            Issue.record("标准形态回落应命中，实际 \(outcome)")
            return
        }
        #expect(stableId == "local-std")
        #expect(key == .relativePath)
    }

    // MARK: - 3. wire 加性字段（双向兼容）

    @Test("wire 兼容：老载荷（无 relativePath 字段）解码成功且行为 = 今天")
    func decodesLegacyPayloadWithoutRelativePath() throws {
        let legacy = """
        {"id":7,"entity":"favorite","rowKey":"remote-track","op":"upsert","updatedAtMs":1000,\
        "contentHash":"hash-A","payloadJSON":null}
        """
        let entry = try JSONDecoder().decode(SyncChangeLogWireEntry.self, from: Data(legacy.utf8))
        #expect(entry.relativePath == nil, "缺键解码为 nil = 今天行为")
        #expect(entry.contentHash == "hash-A")

        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-A", contentHash: "hash-A", relativePath: "Album/a.flac")
        }
        guard case .mapped(let row) = try Self.mapper(manager).localize(entry) else {
            Issue.record("老载荷仍应走 content_hash 映射")
            return
        }
        #expect(row.rowKey == "local-A")
    }

    @Test("wire 兼容：新载荷带 relativePath 可编解码；老 peer 收到只忽略未知字段（加性）")
    func encodesRelativePathAdditively() throws {
        let entry = try Self.favoriteEntry(relativePath: "Album/a.flac")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SyncChangeLogWireEntry.self, from: data)
        #expect(decoded == entry)

        // 老 peer 的解码器（不认识 relativePath）：丢掉未知键后仍能解出同一份其余字段
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var legacy = json
        legacy.removeValue(forKey: "relativePath")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyEntry = try JSONDecoder().decode(SyncChangeLogWireEntry.self, from: legacyData)
        #expect(legacyEntry.relativePath == nil)
        #expect(legacyEntry.entity == entry.entity)
        #expect(legacyEntry.rowKey == entry.rowKey)
        #expect(legacyEntry.updatedAtMs == entry.updatedAtMs)
        #expect(legacyEntry.payloadJSON == entry.payloadJSON)
    }

    // MARK: - 4. 挂起命名空间 + 重放

    @Test("重放：rel: 挂起行在歌到位后重放成功并清行；老库 content_hash 挂起行行为不变")
    func replayByRelativePathKeyAppliesAndClears() throws {
        let (manager, queue) = try Self.makeManager()
        let pendingStore = SyncChangeLogPendingStore(database: manager)
        // 对端那行带第二身份（指纹缺失）→ 收到时本地还没歌 → 挂起
        let entry = try Self.favoriteEntry(relativePath: "Album/a.flac", rowKey: "remote-A")
        guard case .suspended(let pendingKey, let remoteRow) = try Self.mapper(manager).localize(entry) else {
            Issue.record("本地无歌应先挂起")
            return
        }
        try pendingStore.suspend(remoteRow, pendingKey: pendingKey)
        #expect(try pendingStore.pendingCount() == 1)

        // 歌到位（入库路径触发重放；这里直接调重放入口，等价于入库钩子）
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-A", contentHash: "hash-A", relativePath: "Album/a.flac")
        }
        let applied = try SyncChangeLogReplay.replayAfterTrackSave(
            contentHash: "hash-A",
            absolutePath: Self.libraryRoot.appendingPathComponent("Album/a.flac").path,
            database: manager,
            libraryRoot: Self.libraryRoot
        )
        #expect(applied == 1, "重放应真的落库一行")
        #expect(try Self.favoriteIDs(queue) == ["local-A"], "重放落到本地 stableId")
        #expect(try pendingStore.pendingCount() == 0, "重放后挂起行清理")

        // 幂等：再重放一次 = 空操作
        let again = try SyncChangeLogReplay.replay(
            pendingKey: SyncPendingKey.relativePath("Album/a.flac"),
            database: manager,
            libraryRoot: Self.libraryRoot
        )
        #expect(again == 0)
        #expect(try Self.favoriteIDs(queue) == ["local-A"])
    }

    @Test("重放：歧义时不写业务行（也不清挂起行——远端事实不丢）")
    func replayAmbiguousWritesNoBusinessRow() throws {
        let (manager, queue) = try Self.makeManager()
        let pendingStore = SyncChangeLogPendingStore(database: manager)
        let entry = try Self.favoriteEntry(relativePath: "Album/dup.flac")
        guard case .suspended(let pendingKey, let remoteRow) = try Self.mapper(manager).localize(entry) else {
            Issue.record("本地无歌应先挂起")
            return
        }
        try pendingStore.suspend(remoteRow, pendingKey: pendingKey)

        // 歌到位，但同路径两行（歧义）
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-1", contentHash: nil, relativePath: "Album/dup.flac")
            try Self.insertTrack(db, stableId: "local-2", contentHash: nil, relativePath: "Album/dup.flac")
        }
        let applied = try SyncChangeLogReplay.replay(
            pendingKey: pendingKey,
            database: manager,
            libraryRoot: Self.libraryRoot
        )
        #expect(applied == 0, "歧义不落库")
        #expect(try Self.favoriteIDs(queue) == [], "歧义不得写业务行")
        #expect(try pendingStore.pendingCount() == 1, "挂起行保留（等上层修复，不吞远端事实）")
    }

    @Test("挂起键命名空间：rel: 前缀不与指纹撞名（指纹字形不含冒号）")
    func pendingKeyNamespacesDoNotCollide() throws {
        let hash = "9f2c1ab4deadbeef"
        #expect(SyncPendingKey.contentHash(hash) == hash)
        #expect(SyncPendingKey.relativePath("Album/a.flac") == "rel:Album/a.flac")
        #expect(SyncPendingKey.identity(fromPendingKey: hash)?.contentHash == hash)
        #expect(SyncPendingKey.identity(fromPendingKey: "rel:Album/a.flac")?.relativePath == "Album/a.flac")
        // 非法：空键 / 前缀后为空 / 前缀后非法路径
        #expect(SyncPendingKey.identity(fromPendingKey: "") == nil)
        #expect(SyncPendingKey.identity(fromPendingKey: "rel:") == nil)
        #expect(SyncPendingKey.identity(fromPendingKey: "rel:../x.flac") == nil)
    }

    // MARK: - 5. 结果账目（新类别）

    @Test("账目：ambiguousIdentity 的 accumulate / overwrite / 读访问器一致")
    func ambiguousIdentityOutcomeIsTallied() throws {
        var tally = SyncOutcomeTally()
        #expect(tally.count(for: .ambiguousIdentity) == 0)
        #expect(tally.ambiguousIdentityEntries == 0)
        tally.accumulate(.ambiguousIdentity, count: 3)
        #expect(tally.count(for: .ambiguousIdentity) == 3)
        #expect(tally.ambiguousIdentityEntries == 3)
        tally.accumulate(.ambiguousIdentity)
        #expect(tally.ambiguousIdentityEntries == 4)
        tally.overwrite(.ambiguousIdentity, with: 1)
        #expect(tally.ambiguousIdentityEntries == 1, "overwrite = 覆盖写（补差额）")
        // 与其它槽位互不串位
        tally.accumulate(.unresolved, count: 5)
        #expect(tally.unresolvedEntries == 5)
        #expect(tally.ambiguousIdentityEntries == 1)
    }

    @Test("账目：身份歧义不进「已应用」（INV-20：已应用 = 真落库行数）")
    func ambiguousIdentityIsNotApplied() throws {
        var tally = SyncOutcomeTally()
        tally.accumulate(.ambiguousIdentity, count: 2)
        #expect(tally.appliedEntries == 0)
    }
}
