//
//  DatabaseManager+ReplayGain.swift
//  QQPlayer
//
//  ReplayGain 后台补算的数据库侧读写：
//   - 找出「无 ReplayGain 数据」的曲目 / 专辑；
//   - 写回分析结果（来源标记 + 时间戳，避免每次启动重算）；
//   - 记录失败状态（不许无限重试）。
//
//  重新扫描曲库时按 stableId 保留已分析结果，见 LibraryIndexer.saveParsedFile。
//

import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - 补列迁移

    /// 老库 track 表补 ReplayGain 分析元数据列（幂等）。
    ///
    /// 独立成 internal：生产迁移（migrateDatabaseIfNeeded）与单测共用同一实现。
    static func addTrackReplayGainAnalysisColumnsIfNeeded(_ db: Database) throws {
        let columns = try db.columns(in: "track").map(\.name)
        let additions: [(String, String)] = [
            ("replaygain_source", "TEXT"),
            ("replaygain_analysis_state", "TEXT"),
            ("replaygain_analyzed_at", "INTEGER"),
            ("replaygain_album_analysis_at", "INTEGER"),
        ]
        for (name, type) in additions where !columns.contains(name) {
            try db.execute(sql: "ALTER TABLE track ADD COLUMN \(name) \(type)")
            AppLog.info(.db, "✅ Database: Added \(name) column to track table")
        }
    }

    // MARK: - 查询待补算曲目

    /// 取一批缺 ReplayGain 数据、且未被标记失败的曲目（按 id 稳定排序，便于续跑）。
    func tracksNeedingReplayGainAnalysis(limit: Int) throws -> [Track] {
        try read { db in
            try Track
                .filter(Column("replaygain_track_gain") == nil)
                .filter(sql: "replaygain_analysis_state IS NULL OR replaygain_analysis_state <> ?",
                        arguments: [ReplayGainAnalysisState.failed.rawValue])
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 待补算总数（进度显示用）。
    func replayGainAnalysisProgress() throws -> (analyzed: Int, total: Int) {
        try read { db in
            let total = try Track.fetchCount(db)
            let analyzed = try Track
                .filter(Column("replaygain_track_gain") != nil)
                .fetchCount(db)
            return (analyzed, total)
        }
    }

    // MARK: - 写回分析结果

    func recordReplayGainAnalysis(
        stableId: String,
        gains: ReplayGainMath.Gains,
        source: ReplayGainAnalysisSource
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE track SET
                    replaygain_track_gain = COALESCE(?, replaygain_track_gain),
                    replaygain_track_peak = COALESCE(?, replaygain_track_peak),
                    replaygain_album_gain = COALESCE(?, replaygain_album_gain),
                    replaygain_album_peak = COALESCE(?, replaygain_album_peak),
                    replaygain_source = COALESCE(replaygain_source, ?),
                    replaygain_analysis_state = ?,
                    replaygain_analyzed_at = ?
                WHERE stable_id = ?
                """,
                arguments: [
                    gains.trackGain,
                    gains.trackPeak,
                    gains.albumGain,
                    gains.albumPeak,
                    source.rawValue,
                    ReplayGainAnalysisState.done.rawValue,
                    Int(Date().timeIntervalSince1970),
                    stableId,
                ]
            )
        }
    }

    func markReplayGainAnalysisFailed(stableId: String) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE track SET replaygain_analysis_state = ?, replaygain_analyzed_at = ?
                WHERE stable_id = ?
                """,
                arguments: [
                    ReplayGainAnalysisState.failed.rawValue,
                    Int(Date().timeIntervalSince1970),
                    stableId,
                ]
            )
        }
    }

    // MARK: - 专辑补算

    /// 取一批「全部曲目已有 track gain、但还没算过 album gain」的专辑 id。
    func albumIdsNeedingReplayGainAnalysis(limit: Int) throws -> [Int64] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT album_id FROM track
                WHERE album_id IS NOT NULL
                GROUP BY album_id
                HAVING SUM(CASE WHEN replaygain_track_gain IS NULL THEN 1 ELSE 0 END) = 0
                   AND SUM(CASE WHEN replaygain_album_gain IS NULL THEN 1 ELSE 0 END) > 0
                   AND SUM(CASE WHEN replaygain_album_analysis_at IS NULL THEN 1 ELSE 0 END) > 0
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { $0["album_id"] as Int64? }
        }
    }

    func tracksForAlbumReplayGain(albumId: Int64) throws -> [Track] {
        try read { db in
            try Track
                .filter(Column("album_id") == albumId)
                .order(Column("disc_no"), Column("track_no"), Column("id"))
                .fetchAll(db)
        }
    }

    /// 专辑分析结果写回整张专辑的曲目；`gains` 为 nil 表示分析失败（只记时间戳，避免反复重试）。
    func recordAlbumReplayGainAnalysis(albumId: Int64, gains: ReplayGainMath.Gains?) throws {
        try write { db in
            let now = Int(Date().timeIntervalSince1970)
            if let gains {
                try db.execute(
                    sql: """
                    UPDATE track SET
                        replaygain_album_gain = COALESCE(?, replaygain_album_gain),
                        replaygain_album_peak = COALESCE(?, replaygain_album_peak),
                        replaygain_album_analysis_at = ?
                    WHERE album_id = ?
                    """,
                    arguments: [gains.albumGain, gains.albumPeak, now, albumId]
                )
            } else {
                try db.execute(
                    sql: "UPDATE track SET replaygain_album_analysis_at = ? WHERE album_id = ?",
                    arguments: [now, albumId]
                )
            }
        }
    }
}
