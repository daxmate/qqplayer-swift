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
}
