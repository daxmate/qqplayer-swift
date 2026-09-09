//
//  PlayHistoryRecorder.swift
//  QQPlayer
//
//  Play history instrumentation: one play session = a song that started
//  playing and was later switched away, stopped, or finished naturally.
//
//  - Pausing does NOT close the session; resuming keeps accumulating into the
//    same `play_history` record.
//  - Only settling (track switch / stop / natural end) closes the session and
//    stores the actually-listened duration via an UPDATE.
//  - Duration uses WALL CLOCK (pause/resume segment deltas), not playback
//    position deltas: forward seeks (30s -> 200s) inflate position deltas,
//    while wall clock always measures real listening time. The checkpoint is
//    advanced after every accumulate, so pause/resume cycles never double
//    count and paused intervals are excluded.
//  - Every DB write goes through DatabaseManager; records are tiny and
//    written synchronously on the main actor, matching the existing
//    codebase style.
//

import Foundation
@preconcurrency import GRDB

@MainActor
final class PlayHistoryRecorder {
    static let shared = PlayHistoryRecorder()

    /// Stable id of the track with an open session (nil = no active session).
    private(set) var activeSessionTrackStableId: String?
    /// Wall clock at the last duration checkpoint. Advances on every accumulate
    /// so repeated pause/resume cycles never double-count.
    private(set) var sessionStartWallTime: Date = .distantPast
    /// `play_history` row id of the open session; the settling UPDATE targets it.
    private(set) var activeRecordId: Int64?

    /// Upper bound for a single accumulated segment (seconds). Pure backstop
    /// against corrupt timestamps; a real segment is bounded by track length.
    private static let maxSegmentDurationSeconds: Double = 24 * 60 * 60

    private var database: DatabaseManager

    private init() {
        database = DatabaseManager.shared
    }

    /// Test seam: point the recorder at an injected (in-memory) database so
    /// session accounting is unit-testable without touching the app database.
    /// Production always uses the private init + shared singleton.
    init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Instrumentation entry points (called by PlayerEngine)

    /// Playback started (including resume from pause).
    ///
    /// Resume (same track) keeps the original record and just restarts the
    /// wall-clock checkpoint so the paused interval is not counted. Otherwise
    /// the previous session (if any) is settled first, then a fresh record is
    /// inserted with played_at = now.
    func playbackBegan(track: Track?, at playbackTime: Double) {
        guard let track, !track.stableId.isEmpty else { return }
        guard activeSessionTrackStableId != track.stableId else {
            // 同曲恢复：重置墙钟检查点（暂停间隔不计入时长）
            sessionStartWallTime = Date()
            return
        }

        // Defensive: a different track started while a session is still open
        // (should not happen - PlayerEngine settles before switching).
        if activeSessionTrackStableId != nil {
            settleSession(endingAt: playbackTime)
        }

        var insertedId: Int64?
        do {
            try database.write { db in
                // PlayHistoryEntry 只遵守 PersistableRecord：非 mutating insert 不会把自增
                // id 回填到 entry（此前 entry.id 恒 nil → activeRecordId 恒 nil → 时长 UPDATE
                // 全被 guard 挡住，播放时长从未写入。2026-08-30 墙钟测试暴露）。
                let entry = PlayHistoryEntry(
                    trackStableId: track.stableId,
                    playedAt: Int64(Date().timeIntervalSince1970),
                    playDurationMs: 0
                )
                try entry.insert(db)
                insertedId = db.lastInsertedRowID
                // S2 M4-1：新播放会话 → outbox upsert（初始态，时长为 0；会话 settle 时
                // 再记最终态）。与业务行同事务：原子提交，防丢变更。
                let snapshot = SyncPlayHistorySnapshot(
                    trackStableId: entry.trackStableId,
                    playedAt: entry.playedAt,
                    playDurationMs: 0
                )
                try SyncChangeLogStore.record(
                    db,
                    entity: .playHistory,
                    rowKey: snapshot.rowKey,
                    op: .upsert,
                    payloadJSON: try SyncSnapshotCodec.encode(snapshot)
                )
            }
        } catch {
            print("⚠️ PlayHistoryRecorder: 写入播放记录失败: \(error)")
        }

        activeRecordId = insertedId
        activeSessionTrackStableId = track.stableId
        sessionStartWallTime = Date()
    }

    /// Playback paused. Accumulates the elapsed segment into the open record
    /// but keeps the session (track unchanged) so a later resume continues it.
    func playbackPaused(track: Track?, at playbackTime: Double) {
        guard let track else { return }
        guard activeSessionTrackStableId == track.stableId else { return }
        accumulateDuration(until: playbackTime)
    }

    /// Playback ended (track switched / stopped / finished). Accumulates the
    /// final segment and closes the session.
    ///
    /// Validates the track like playbackPaused does: an out-of-order or stale
    /// `ended` for a different (or already settled) track is dropped instead
    /// of settling the wrong session.
    func playbackEnded(track: Track?, at playbackTime: Double) {
        guard let track, !track.stableId.isEmpty else { return }
        guard activeSessionTrackStableId == track.stableId else { return }
        settleSession(endingAt: playbackTime)
    }

    // MARK: - Session accounting

    private func accumulateDuration(until playbackTime: Double) {
        guard activeSessionTrackStableId != nil,
              let recordId = activeRecordId else {
            return
        }
        // 墙钟分段：真实收听时长，前向 seek 不虚增、回退不虚减。
        // playbackTime 仅保留在签名里（PlayerEngine 调用契约），不参与计算。
        let elapsed = Date().timeIntervalSince(sessionStartWallTime)
        print("🔬 accumulate: recordId=\(String(describing: activeRecordId)) wall=\(sessionStartWallTime) elapsed=\(elapsed)")
        // Only positive, finite segments: out-of-order events or corrupt
        // values must not pollute the duration.
        guard elapsed > 0, elapsed <= Self.maxSegmentDurationSeconds else { return }
        let milliseconds = Int64(elapsed * 1000)
        guard milliseconds > 0 else { return }

        do {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE play_history SET play_duration_ms = play_duration_ms + ? WHERE id = ?",
                    arguments: [milliseconds, recordId]
                )
            }
        } catch {
            print("⚠️ PlayHistoryRecorder: 更新播放时长失败: \(error)")
        }

        // Advance the checkpoint so the next accumulate covers only the new
        // segment (pause at 30s, resume, pause at 60s -> 30s wall time, not 60s).
        sessionStartWallTime = Date()
    }

    private func settleSession(endingAt playbackTime: Double) {
        guard activeSessionTrackStableId != nil else { return }
        accumulateDuration(until: playbackTime)
        // S2 M4-1：会话落定 → outbox upsert 最终态（含累计时长）。用 recordId 回读
        // 行拿准确 play_duration_ms；失败只影响变更日志（已记的初始态仍可同步，
        // 时长以 LWW 大者胜收敛），不影响播放主流程。
        if let recordId = activeRecordId, let trackStableId = activeSessionTrackStableId {
            do {
                try database.write { db in
                    guard let row = try PlayHistoryEntry.filter(Column("id") == recordId).fetchOne(db) else {
                        return
                    }
                    let snapshot = SyncPlayHistorySnapshot(
                        trackStableId: trackStableId,
                        playedAt: row.playedAt,
                        playDurationMs: row.playDurationMs
                    )
                    try SyncChangeLogStore.record(
                        db,
                        entity: .playHistory,
                        rowKey: snapshot.rowKey,
                        op: .upsert,
                        payloadJSON: try SyncSnapshotCodec.encode(snapshot)
                    )
                }
            } catch {
                print("⚠️ PlayHistoryRecorder: 同步变更日志写入失败: \(error)")
            }
        }
        activeSessionTrackStableId = nil
        sessionStartWallTime = .distantPast
        activeRecordId = nil
    }
}
