//
//  ReplayGainMigrationTests.swift
//  QQPlayerTests
//
//  老库 track 表补 ReplayGain 分析元数据列：幂等（连跑两次）+ 列存在后可读写。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct ReplayGainMigrationTests {
    /// 旧版 track 表（含 ReplayGain 数值列，但**没有**分析元数据列）。
    private static let legacyTrackDDL = """
    CREATE TABLE track (
        id INTEGER PRIMARY KEY,
        stable_id TEXT NOT NULL UNIQUE,
        album_id INTEGER,
        artist_id INTEGER,
        title TEXT NOT NULL,
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
        content_hash TEXT,
        replaygain_track_gain REAL,
        replaygain_album_gain REAL,
        replaygain_track_peak REAL,
        replaygain_album_peak REAL,
        has_embedded_art INTEGER DEFAULT 0
    )
    """

    @Test("老库补列：连跑两次幂等，列齐全")
    func addsColumnsIdempotently() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: Self.legacyTrackDDL)
            try DatabaseManager.addTrackReplayGainAnalysisColumnsIfNeeded(db)
            try DatabaseManager.addTrackReplayGainAnalysisColumnsIfNeeded(db)

            let columns = try db.columns(in: "track").map(\.name)
            #expect(columns.contains("replaygain_source"))
            #expect(columns.contains("replaygain_analysis_state"))
            #expect(columns.contains("replaygain_analyzed_at"))
            #expect(columns.contains("replaygain_album_analysis_at"))
        }
    }

    @Test("补列后写入 / 读回分析元数据")
    func writeAndReadAnalysisMetadata() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: Self.legacyTrackDDL)
            try DatabaseManager.addTrackReplayGainAnalysisColumnsIfNeeded(db)
            try db.execute(
                sql: """
                INSERT INTO track (stable_id, title, path, replaygain_track_gain,
                                   replaygain_analysis_state, replaygain_source, replaygain_analyzed_at)
                VALUES ('s1', 'T', '/tmp/a.flac', -6.5, 'done', 'analyzed', 1700000000)
                """
            )
            let row = try Row.fetchOne(db, sql: "SELECT * FROM track WHERE stable_id = 's1'")
            #expect(row?["replaygain_analysis_state"] as String? == "done")
            #expect(row?["replaygain_source"] as String? == "analyzed")
            #expect(row?["replaygain_analyzed_at"] as Int? == 1_700_000_000)
        }
    }
}
