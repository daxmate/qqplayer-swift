//
//  TrackContentHashTests.swift
//  QQPlayerTests
//
//  M3-1：track.content_hash 地基（跨端歌曲身份 = 文件内容 SHA-256）测试。
//  - 老库迁移：无 content_hash 列 → addTrackContentHashColumnIfNeeded 补列，连跑两次幂等
//  - 入库计算：upsertTrack 对存在的文件自动算 SHA-256 写入 content_hash；文件缺失 → nil
//  - 存量惰性回填：content_hash IS NULL 行，文件存在 → 补全；文件缺失 → 保持 NULL；
//    已有值不重算；连跑两遍不崩（幂等）
//
//  fixtures：临时目录写入字节文件（不解析音频，只验哈希接线；SHA-256 算法本身
//  已由 M2b SyncFileChecksum 相关测试覆盖，此处用同一实现算期望值）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct TrackContentHashTests {
    // MARK: - 辅助

    /// 写临时字节文件，返回 URL（调用方负责清理目录）。
    private func writeTempFile(named name: String, byte: UInt8 = 0xAB) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackContentHashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: byte, count: 2048).write(to: url)
        return url
    }

    /// 老版本建表 DDL：当前 CREATE TABLE track 去掉 content_hash 列的形态
    /// （含 genre/modification_date 等既有列，模拟 M3-1 之前的老库）。
    private static let legacyTrackDDL = """
    CREATE TABLE track (
        id INTEGER PRIMARY KEY,
        stable_id TEXT NOT NULL UNIQUE,
        album_id INTEGER REFERENCES album(id) ON DELETE SET NULL,
        artist_id INTEGER REFERENCES artist(id) ON DELETE SET NULL,
        title TEXT NOT NULL COLLATE NOCASE,
        genre TEXT,
        track_no INTEGER,
        disc_no INTEGER,
        duration_ms INTEGER,
        sample_rate INTEGER,
        bit_depth INTEGER,
        channels INTEGER,
        path TEXT NOT NULL,
        file_size INTEGER,
        modification_date INTEGER,
        replaygain_track_gain REAL,
        replaygain_album_gain REAL,
        replaygain_track_peak REAL,
        replaygain_album_peak REAL,
        has_embedded_art INTEGER DEFAULT 0
    )
    """

    // MARK: - 老库迁移（无 content_hash 列 → 补列，幂等）

    @Test("老库无 content_hash 列 → 补列成功且连跑两次幂等 → 往返")
    func legacySchemaMigrationAddsContentHashColumn() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: Self.legacyTrackDDL)
        }
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()  // IF NOT EXISTS：老 track 表保留，其余表/索引照建

        // 迁移：补 content_hash 列；连调两次验证幂等（列已存在 → 跳过不崩）
        try dbQueue.write { db in
            try DatabaseManager.addTrackContentHashColumnIfNeeded(db)
            let columnNames = try db.columns(in: "track").map(\.name)
            #expect(columnNames.contains("content_hash"))
            try DatabaseManager.addTrackContentHashColumnIfNeeded(db)
        }

        // 补列后 upsert 往返：content_hash 可读写
        let url = try writeTempFile(named: "legacy-track.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try manager.upsertTrack(Track(stableId: "legacy-hash-1", title: "Legacy Hash", path: url.path))
        let fetched: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "legacy-hash-1").fetchOne(db)
        }
        let track = try #require(fetched)
        let expectedHash = try SyncFileChecksum.sha256Hex(ofFile: url)
        #expect(track.contentHash == expectedHash)
    }

    // MARK: - 入库计算（upsertTrack 统一入口）

    @Test("upsertTrack：文件存在 → 自动算 content_hash 写入")
    func upsertComputesContentHashForExistingFile() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        let url = try writeTempFile(named: "exists.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try manager.upsertTrack(Track(stableId: "up-1", title: "Up 1", path: url.path))

        let fetched: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "up-1").fetchOne(db)
        }
        let track = try #require(fetched)
        let expectedHash = try SyncFileChecksum.sha256Hex(ofFile: url)
        #expect(track.contentHash == expectedHash)
        #expect(SyncFileChecksum.isValidSHA256Hex(try #require(track.contentHash)))
    }

    @Test("upsertTrack：文件缺失 → content_hash 保持 nil（不崩，待回填）")
    func upsertLeavesNilForMissingFile() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackContentHashTests-missing-\(UUID().uuidString).bin")

        try manager.upsertTrack(Track(stableId: "up-missing", title: "Up Missing", path: missing.path))

        let fetched: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "up-missing").fetchOne(db)
        }
        #expect(fetched?.contentHash == nil)
    }

    // MARK: - 存量惰性回填（content_hash IS NULL → 文件存在补全 / 缺失跳过）

    @Test("回填：文件存在补全、缺失保持 NULL、已有值不重算；连跑两遍幂等")
    func backfillFillsExistingSkipsMissingKeepsExistingHash() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        // 绕过 upsertTrack（它会即时算 hash），直接 SQL 插入 NULL hash 行模拟存量老库
        let presentURL = try writeTempFile(named: "present.bin", byte: 0x11)
        defer { try? FileManager.default.removeItem(at: presentURL.deletingLastPathComponent()) }
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackContentHashTests-gone-\(UUID().uuidString).bin")

        try dbQueue.write { db in
            // 存在文件的 NULL 行 → 应补全
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path) VALUES (?, ?, ?)",
                arguments: ["bf-present", "Present", presentURL.path]
            )
            // 文件缺失的 NULL 行 → 应跳过（保持 NULL）
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path) VALUES (?, ?, ?)",
                arguments: ["bf-missing", "Missing", missingPath]
            )
            // 已有 hash 的行 → 不重算（回填只扫 NULL）
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: ["bf-kept", "Kept", presentURL.path, "ab".padding(toLength: 64, withPad: "0", startingAt: 0)]
            )
        }

        // 第一次回填
        try manager.backfillMissingContentHashes()

        let present: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "bf-present").fetchOne(db)
        }
        let presentExpected = try SyncFileChecksum.sha256Hex(ofFile: presentURL)
        #expect(present?.contentHash == presentExpected)

        let missing: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "bf-missing").fetchOne(db)
        }
        #expect(missing?.contentHash == nil)

        let kept: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "bf-kept").fetchOne(db)
        }
        #expect(kept?.contentHash == "ab" + String(repeating: "0", count: 62))

        // 第二次回填：无 NULL 可补 → 不崩（幂等）
        try manager.backfillMissingContentHashes()
    }

    // MARK: - 回填 × iCloud dataless（云端未下载）

    /// 插入一行 content_hash 为 NULL 的存量曲目（绕过 upsertTrack 的即时哈希）。
    private func insertNullHashTrack(_ dbQueue: DatabaseQueue, stableId: String, path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path) VALUES (?, ?, ?)",
                arguments: [stableId, stableId, path]
            )
        }
    }

    @Test("回填：iCloud 云端未下载（isLocallyAvailable=false）→ 跳过、返回跳过数>0、content_hash 仍 NULL")
    func backfillSkipsDatalessCloudTracks() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        let url = try writeTempFile(named: "cloudonly.bin", byte: 0x22)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try insertNullHashTrack(dbQueue, stableId: "bf-cloud-skipped", path: url.path)

        let skipped = try manager.backfillMissingContentHashes(isLocallyAvailable: { _ in false })
        #expect(skipped == 1)

        let cloudOnly: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "bf-cloud-skipped").fetchOne(db)
        }
        #expect(cloudOnly?.contentHash == nil)
    }

    @Test("回填：云端文件下载完成后（isLocallyAvailable=true）→ 补齐、跳过数归零")
    func backfillFillsAfterCloudDownload() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        let url = try writeTempFile(named: "clouddownloaded.bin", byte: 0x33)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try insertNullHashTrack(dbQueue, stableId: "bf-cloud-filled", path: url.path)

        let skipped = try manager.backfillMissingContentHashes(isLocallyAvailable: { _ in true })
        #expect(skipped == 0)

        let filled: Track? = try dbQueue.read { db in
            try Track.filter(Column("stable_id") == "bf-cloud-filled").fetchOne(db)
        }
        let expected = try SyncFileChecksum.sha256Hex(ofFile: url)
        #expect(filled?.contentHash == expected)
    }

    // MARK: - 自愈回填（去一次性门）+ 挂起重放 + 身份缺失普查（2026-09-14）

    /// 独立 UserDefaults suite：避免污染真实门状态、也让「上一轮启动」可复现。
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "TrackContentHashTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// 插入一行带显式 content_hash 的曲目（"" 用于验证普查把空串计入缺失）。
    private func insertTrackWithHash(
        _ dbQueue: DatabaseQueue,
        stableId: String,
        path: String,
        contentHash: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: [stableId, stableId, path, contentHash]
            )
        }
    }

    private func contentHash(_ dbQueue: DatabaseQueue, stableId: String) throws -> String? {
        try dbQueue.read { db in
            try Track.filter(Column("stable_id") == stableId).fetchOne(db)?.contentHash
        }
    }

    @Test("自愈回填：连跑两遍幂等；filledHashes 只报告本次新填的指纹")
    func backfillIsIdempotentAndReportsOnlyNewlyFilledHashes() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        let url = try writeTempFile(named: "idem-present.bin", byte: 0x77)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expected = try SyncFileChecksum.sha256Hex(ofFile: url)
        let existing = String(repeating: "a", count: 64)

        try insertNullHashTrack(dbQueue, stableId: "idem-null", path: url.path)
        try insertTrackWithHash(dbQueue, stableId: "idem-hashed", path: url.path, contentHash: existing)

        let first = try manager.backfillMissingContentHashesDetailed()
        #expect(first.filledHashes == [expected])
        #expect(first.candidateCount == 1)
        #expect(first.skippedCloudOnly == 0)

        // 第二遍：无 NULL 行 → 零查询结果、零填充、不崩（幂等）
        let second = try manager.backfillMissingContentHashesDetailed()
        #expect(second.filledHashes.isEmpty)
        #expect(second.candidateCount == 0)

        // 已有指纹不被重算
        #expect(try contentHash(dbQueue, stableId: "idem-hashed") == existing)
        #expect(try contentHash(dbQueue, stableId: "idem-null") == expected)
    }

    @Test("自愈回填：文件缺失只推迟、不落永久门——下一轮启动仍重试，文件出现后自动补齐")
    func backfillRetriesMissingFilesOnNextLaunch() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let defaults = makeIsolatedDefaults()

        let presentURL = try writeTempFile(named: "heal-present.bin", byte: 0x88)
        defer { try? FileManager.default.removeItem(at: presentURL.deletingLastPathComponent()) }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackContentHashTests-heal-missing-\(UUID().uuidString).bin")

        try insertNullHashTrack(dbQueue, stableId: "heal-present", path: presentURL.path)
        try insertNullHashTrack(dbQueue, stableId: "heal-missing", path: missingURL.path)

        // 第一轮启动：存在的文件补齐，缺失的保持 NULL
        let first = try manager.backfillTrackContentHashesIfNeeded(defaults: defaults)
        #expect(first.filledHashes == [try SyncFileChecksum.sha256Hex(ofFile: presentURL)])
        #expect(try contentHash(dbQueue, stableId: "heal-missing") == nil)
        // 只留运行标记（诊断），不得留下任何「已完成」语义的门
        #expect(ContentHashBackfillMarker.lastRunDate(defaults: defaults) != nil)
        #expect(!defaults.bool(forKey: ContentHashBackfillMarker.retiredCompletionKey))

        // 第二轮启动：仍会重试（旧一次性门在这一步就永久跳过了）
        let second = try manager.backfillTrackContentHashesIfNeeded(defaults: defaults)
        #expect(second.candidateCount == 1)
        #expect(second.filledHashes.isEmpty)

        // 文件后来出现了 → 第三轮自愈补齐
        try Data(repeating: 0x99, count: 1024).write(to: missingURL)
        defer { try? FileManager.default.removeItem(at: missingURL) }
        let third = try manager.backfillTrackContentHashesIfNeeded(defaults: defaults)
        #expect(third.filledHashes == [try SyncFileChecksum.sha256Hex(ofFile: missingURL)])
        #expect(try contentHash(dbQueue, stableId: "heal-missing") == third.filledHashes.first)
    }

    @Test("自愈回填：云端未下载 → 跳过且不置永久门；下载完成后下一轮补齐")
    func backfillSkipsDatalessWithoutPermanentGate() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let defaults = makeIsolatedDefaults()

        let url = try writeTempFile(named: "heal-dataless.bin", byte: 0xAA)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try insertNullHashTrack(dbQueue, stableId: "heal-dataless", path: url.path)

        // 第一轮：云端未下载（不读内容）→ 跳过
        let first = try manager.backfillTrackContentHashesIfNeeded(
            defaults: defaults, isLocallyAvailable: { _ in false }
        )
        #expect(first.filledHashes.isEmpty)
        #expect(first.skippedCloudOnly == 1)
        #expect(try contentHash(dbQueue, stableId: "heal-dataless") == nil)
        #expect(!defaults.bool(forKey: ContentHashBackfillMarker.retiredCompletionKey))

        // 第二轮（文件已实体化）：仍会重试并补齐
        let second = try manager.backfillTrackContentHashesIfNeeded(
            defaults: defaults, isLocallyAvailable: { _ in true }
        )
        #expect(second.filledHashes == [try SyncFileChecksum.sha256Hex(ofFile: url)])
        #expect(second.skippedCloudOnly == 0)
        #expect(try contentHash(dbQueue, stableId: "heal-dataless") == second.filledHashes.first)
    }

    @Test("身份缺失普查：NULL/空指纹 + 三类悬空引用计数正确，且只读不改任何行")
    func identityCensusCountsMissingIdentity() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()

        let url = try writeTempFile(named: "census-present.bin", byte: 0xBB)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackContentHashTests-census-missing-\(UUID().uuidString).bin").path

        // 健康行：指纹完整 + 三类引用均指向它（不应计入任何悬空数）
        try insertTrackWithHash(dbQueue, stableId: "cen-ok", path: url.path, contentHash: String(repeating: "b", count: 64))
        // 缺失身份：NULL 指纹行 + 空串指纹行
        try insertNullHashTrack(dbQueue, stableId: "cen-null", path: missingPath)
        try insertTrackWithHash(dbQueue, stableId: "cen-empty", path: missingPath, contentHash: "")

        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at) VALUES (?, ?)", arguments: ["cen-ok", 10])
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at) VALUES (?, ?)", arguments: ["ghost-history", 20])
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at) VALUES (?, ?)", arguments: ["ghost-history", 30])
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES (?)", arguments: ["cen-ok"])
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES (?)", arguments: ["ghost-favorite"])
            try db.execute(
                sql: "INSERT INTO playlist (id, slug, title, created_at, updated_at) VALUES (1, 'census-p', 'Census P', 0, 0)"
            )
            try db.execute(
                sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 0, 'cen-ok')"
            )
            try db.execute(
                sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 1, 'ghost-item')"
            )
        }

        let census = try manager.identityCensus()
        #expect(census.nullHash == 2)
        #expect(census.danglingHistory == 2)
        #expect(census.danglingFavorite == 1)
        #expect(census.danglingItem == 1)
        #expect(
            census.summaryLine
                == "🔎 Identity census: nullHash=2 danglingHistory=2 danglingFavorite=1 danglingItem=1"
        )

        // 只读：普查后行数与悬空行原样保留（孤儿行不由本入口清理）。
        // 注：throwing 闭包内不能写 `#expect(try …)`——宏展开报 "errors thrown from
        // here are not handled"（报错指向 @__swiftmacro_* 展开文件）。先取值再断言。
        let remaining = try dbQueue.read { db in
            (
                tracks: try Track.fetchCount(db),
                history: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_history") ?? -1,
                favorites: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite") ?? -1,
                items: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item") ?? -1
            )
        }
        #expect(remaining.tracks == 3)
        #expect(remaining.history == 3)
        #expect(remaining.favorites == 2)
        #expect(remaining.items == 2)
    }

    @Test("自愈回填补齐指纹后 → 重放该指纹的挂起变更（对端收藏落到本地 stableId）")
    func backfillReplaysPendingChanges() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let defaults = makeIsolatedDefaults()

        let url = try writeTempFile(named: "replay-local.bin", byte: 0xCC)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expectedHash = try SyncFileChecksum.sha256Hex(ofFile: url)
        try insertNullHashTrack(dbQueue, stableId: "replay-local", path: url.path)

        // 对端播放数据先到、本地还没有该指纹 → 挂起
        let pendingStore = SyncChangeLogPendingStore(database: manager)
        try pendingStore.suspend(
            SyncChangeLogRow(
                entity: .favorite,
                rowKey: "peer-track",
                op: .upsert,
                updatedAtMs: 1000,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "peer-track"))
            ),
            contentHash: expectedHash
        )
        #expect(try pendingStore.pendingCount() == 1)

        let outcome = try manager.backfillTrackContentHashesIfNeeded(
            defaults: defaults, isLocallyAvailable: { _ in true }
        )
        #expect(outcome.filledHashes == [expectedHash])

        // 指纹补齐 → 挂起变更本地化落库，挂起行被消费
        let favoriteIDs = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM favorite")
        }
        #expect(favoriteIDs == ["replay-local"])
        #expect(try pendingStore.pendingCount() == 0)
    }
}
