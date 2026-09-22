//
//  DatabaseManager+Tracks.swift
//  QQPlayer
//
//  曲目写入真值：upsert / 重复判定与陈旧清理、身份迁移（stableId·路径）、按路径查曲目、
//  歌手关联写入、批量刮削目标查询。
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · DatabaseManager+TracksRead.swift        — 曲目读查询（id / 专辑 / 歌手 / 分页 / 计数 / 收藏列表）
//    · DatabaseManager+TracksMaintenance.swift — 收藏增删、删除 / 仅从曲库移除 / 移动
//
import Foundation
@preconcurrency import GRDB
extension DatabaseManager {
    // MARK: - Track operations

    func upsertTrack(_ track: Track) throws {
        defer { invalidateArtistDisplayNameCache() }
        var trackToSave = track
        // 曲名落库一律规范形（简体，与 UI 语言解耦）——入库字形的唯一收口点之一，
        // 与 upsertArtist / upsertAlbum 同一入口（DisplayScriptNormalizer.canonical）。
        // 只改库内形态：用户文件标签与同步载荷不受影响。
        trackToSave.title = DisplayScriptNormalizer.canonical(trackToSave.title)

        // M3-1: 入库时算一次 content_hash（跨端歌曲身份 = 文件内容 SHA-256）。
        // 已存在（非 nil）不重算；文件缺失/读失败保持 nil，由惰性回填
        // （backfillTrackContentHashesIfNeeded）或下次入库补。哈希在写事务外
        // （audit 纪律：文件 IO 不进写事务）。
        if trackToSave.contentHash == nil {
            trackToSave.contentHash = Self.contentHashIfFilePresent(atPath: trackToSave.path)
        }
        var savedTrack: Track?
        // stableId 变更（同路径不同 id 的去重合并）记录在案：文件侧引用迁移必须
        // 在事务外做（文件 IO 不进写事务），见 TrackIdentityMigration。
        var mergedDuplicateStableIds: [String] = []

        try write { db in
            // A metadata refresh builds a new Track value with the same
            // stable ID. Reuse the existing primary key so GRDB performs an
            // UPDATE, preserving favorites, playlists and every other
            // stable-ID relationship owned by previous app versions.
            if trackToSave.id == nil,
               let existing = try Track
               .filter(Column("stable_id") == trackToSave.stableId)
               .fetchOne(db) {
                trackToSave.id = existing.id
            }

            // Safety check: Remove any duplicates with the same path but different stable_id
            // This handles edge cases where migration didn't run or failed.
            // Compare on the standardized path, matching getTrack(byPath:)'s
            // normalized fallback so iCloud container UUID changes cannot
            // hide duplicates (audit: inconsistent path spelling).
            let normalizedPath = Self.standardizedPath(trackToSave.path)
            let duplicates = try Track.filter(Column("path") == normalizedPath && Column("stable_id") != trackToSave.stableId).fetchAll(db)
            if !duplicates.isEmpty {
                AppLog.warn(.db, "⚠️ Found \(duplicates.count) duplicate(s) for path: \(normalizedPath)")
                for duplicate in duplicates {
                    // 引用迁移走唯一入口（D6：此前 favorite/playlist_item 是裸
                    // UPDATE，主键冲突会抛错并回滚**整次入库事务**，文件静默不入库）。
                    try TrackIdentityMigration.migrateDatabaseReferences(
                        db,
                        from: duplicate.stableId,
                        to: trackToSave.stableId
                    )
                    // Delete the duplicate
                    try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    mergedDuplicateStableIds.append(duplicate.stableId)
                    if AppLog.isEnabled(.debug, .db) { AppLog.debug(.db, "🗑️ Removed duplicate track with old stable_id: \(duplicate.stableId)") }
                }
            }

            try trackToSave.save(db)
            savedTrack = trackToSave
        }

        // 文件侧引用（书签/三个歌词目录/封面映射）跟随新 stableId——事务外、幂等
        for duplicateStableId in mergedDuplicateStableIds {
            TrackIdentityMigration.migrateFileReferences(from: duplicateStableId, to: trackToSave.stableId)
        }

        // File-existence checks and the follow-up delete run OUTSIDE the
        // upsert write transaction: syscalls no longer pin the single GRDB
        // writer, which used to serialize all four concurrent indexers
        // (audit: file IO inside a write transaction).
        if let savedTrack {
            try cleanupStaleUnplayableDuplicates(matching: savedTrack)

            // 身份重放（2026-09-15 身份兜底包）：两个命名空间的挂起键都算出来——
            // ① 新到位的指纹（content_hash 命名空间）；② 该歌的曲库相对路径（rel: 命名空间，
            // 对端那行拿不到指纹时用的第二身份）。只重放其一会让另一半挂起行永远等人。
            // 放在写事务外（重放自走读写事务），失败不影响入库本身（下次入库/
            // 对账再试）；无挂起行时只是一次索引读，扫描入库不受影响。
            do {
                let replayed = try SyncChangeLogReplay.replayAfterTrackSave(
                    contentHash: savedTrack.contentHash,
                    absolutePath: savedTrack.path,
                    database: self,
                    libraryRoot: MusicFolderResolver.syncLibraryRoot
                )
                if replayed > 0 {
                    AppLog.info(.db, "🔁 Sync: 重放挂起变更 \(replayed) 条")
                }
            } catch {
                AppLog.warn(.db, "⚠️ Sync: 挂起变更重放失败（下次入库重试）：\(error)")
            }
        }
    }

    private func normalizedDuplicateTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private func hasReliableDuplicateMetadata(_ track: Track) -> Bool {
        guard let durationMs = track.durationMs, durationMs > 0,
              let fileSize = track.fileSize, fileSize > 0 else {
            return false
        }

        return !normalizedDuplicateTitle(track.title).isEmpty
    }

    /// Removes rows whose file no longer exists when a twin (same title,
    /// duration, size, artist) just got saved. Runs OUTSIDE the upsert write
    /// transaction in three phases so file-existence syscalls never pin the
    /// single GRDB writer (audit: file IO inside a write transaction):
    ///   1. read transaction: SQL-prefiltered candidate rows (no IO)
    ///   2. outside any transaction: file-existence + metadata checks
    ///   3. short write transaction: merge references + delete confirmed stales
    private func cleanupStaleUnplayableDuplicates(matching newTrack: Track) throws {
        guard hasReliableDuplicateMetadata(newTrack),
              FileManager.default.fileExists(atPath: newTrack.path) else {
            return
        }

        // Phase 1: Prefilter by the strict-duplicate criteria in SQL. Fetching
        // ALL tracks here made every import O(n^2) in rows AND file-exists
        // syscalls - the main cause of watchdog kills on 2000+ file imports.
        let candidates = try read { db in
            try Track
                .filter(Column("artist_id") == newTrack.artistId
                    && Column("duration_ms") == newTrack.durationMs
                    && Column("file_size") == newTrack.fileSize
                    && Column("stable_id") != newTrack.stableId)
                .fetchAll(db)
        }

        // Phase 2: file-existence + metadata checks, no database handle held.
        let staleCandidates = candidates.compactMap { stale -> (stableId: String, title: String)? in
            guard stale.stableId != newTrack.stableId,
                  !FileManager.default.fileExists(atPath: stale.path),
                  FileManager.default.fileExists(atPath: newTrack.path),
                  hasReliableDuplicateMetadata(stale),
                  hasReliableDuplicateMetadata(newTrack),
                  stale.artistId == newTrack.artistId,
                  stale.durationMs == newTrack.durationMs,
                  stale.fileSize == newTrack.fileSize else {
                return nil
            }

            let staleFilename = URL(fileURLWithPath: stale.path).lastPathComponent.lowercased()
            let keeperFilename = URL(fileURLWithPath: newTrack.path).lastPathComponent.lowercased()
            guard staleFilename == keeperFilename,
                  normalizedDuplicateTitle(stale.title) == normalizedDuplicateTitle(newTrack.title) else {
                return nil
            }
            return (stale.stableId, stale.title)
        }
        guard !staleCandidates.isEmpty else { return }

        // Phase 3: one short write transaction deletes only confirmed stales.
        var mergedStableIds: [String] = []
        try write { db in
            for stale in staleCandidates {
                try TrackIdentityMigration.migrateDatabaseReferences(db, from: stale.stableId, to: newTrack.stableId)
                try Track.filter(Column("stable_id") == stale.stableId).deleteAll(db)
                mergedStableIds.append(stale.stableId)
                if AppLog.isEnabled(.debug, .db) { AppLog.debug(.db, "🗑️ Removed strict stale duplicate: \(stale.title)") }
            }
        }
        // 文件侧引用（书签/歌词/封面映射）跟随新 stableId——事务外、幂等
        for staleStableId in mergedStableIds {
            TrackIdentityMigration.migrateFileReferences(from: staleStableId, to: newTrack.stableId)
        }
    }

    func migrateTrackStableIdAndPath(oldStableId: String, newStableId: String, newPath: String) throws {
        // 只有 stableId **真变了**才需要搬文件侧引用（书签 / 歌词目录 / 封面映射）。
        var didChangeStableId = false
        try write { db in
            guard var oldTrack = try Track.filter(Column("stable_id") == oldStableId).fetchOne(db) else {
                return
            }

            // 不变量：`oldStableId == newStableId` = **同一条记录**（同一 stableId 只能有一行）。
            // iOS 常态：stableId 派生自 Documents **相对**路径，重装换数据容器 UUID 不改它
            // ⇒ 走的是本分支。此处**只回写 path，绝不删行**：下面的「合并到已存在新行」分支
            // 在等号情形下取到的就是本行本身，先 update 再 deleteAll 会把这唯一一行删掉
            // ——2026-09-22 那条「重装后曲库 221 行被清空」的根因（配 221 条
            // 「Merged stale track ID X into existing resolved ID X」日志）。
            // 引用（收藏 / 歌单 / 艺术家 / 历史）无需迁移：stable_id 没变，键就不变。
            if oldStableId == newStableId {
                let previousPath = oldTrack.path
                oldTrack.path = newPath
                try oldTrack.update(db)
                AppLog.warn(.db, "🔁 Re-synced path for unchanged stable ID \(oldStableId)（old == new，只更新 path、不删行）: \(previousPath) -> \(newPath)")
                return
            }

            if var existingNewTrack = try Track.filter(Column("stable_id") == newStableId).fetchOne(db) {
                existingNewTrack.path = newPath
                try existingNewTrack.update(db)
                try TrackIdentityMigration.migrateDatabaseReferences(db, from: oldStableId, to: newStableId)
                let removedOldRows = try Track.filter(Column("stable_id") == oldStableId).deleteAll(db)
                didChangeStableId = true
                AppLog.info(.db, "🔁 Merged stale track ID \(oldStableId) into existing resolved ID \(newStableId)"
                    + "（path: \(newPath)，删除旧行 \(removedOldRows) 条）")
                return
            }

            oldTrack.stableId = newStableId
            oldTrack.path = newPath
            try oldTrack.update(db)
            try TrackIdentityMigration.migrateDatabaseReferences(db, from: oldStableId, to: newStableId)
            didChangeStableId = true
            AppLog.info(.db, "🔁 Migrated track ID for moved file: \(oldStableId) -> \(newStableId)")
        }
        // D3：stableId 变更 = 六处引用一起搬（含此前完全没人迁的歌词与封面映射）
        if didChangeStableId {
            TrackIdentityMigration.migrateFileReferences(from: oldStableId, to: newStableId)
        }
    }

    /// 文件移动（路径变更）后的身份迁移——**唯一入口**（审计 D5）。
    ///
    /// `stable_id == SHA256(标准化 path)` 是不变量：凡路径变更，stableId 必须由新路径
    /// 重算并走同一迁移入口（否则行内身份与实际路径错位，改名迁移/去重/内容指纹对账
    /// 全基于旧 id 追踪）。调用方只管说「这行搬到哪个新路径了」。
    ///
    /// - Returns: 新 stableId；旧 id 不在库中时返回 nil（无事发生，幂等）。
    @discardableResult
    func migrateTrackForMovedFile(oldStableId: String, newPath: String) throws -> String? {
        let newStableId = Self.generatePathStableId(forPath: newPath)
        guard try getTrack(byStableId: oldStableId) != nil else { return nil }
        try migrateTrackStableIdAndPath(oldStableId: oldStableId, newStableId: newStableId, newPath: newPath)
        return newStableId
    }

    func getTrack(byPath path: String) throws -> Track? {
        let standardizedPath = Self.standardizedPath(path)
        return try read { db in
            if let exact = try Track.filter(Column("path") == path).fetchOne(db) {
                return exact
            }

            if standardizedPath != path,
               let standardized = try Track.filter(Column("path") == standardizedPath).fetchOne(db) {
                return standardized
            }

            // Preserve compatibility for older rows whose stored URL spelling
            // differs from Foundation's standardized path representation.
            let tracks = try Track.fetchAll(db)
            return tracks.first { Self.standardizedPath($0.path) == standardizedPath }
        }
    }

    func setTrackArtists(trackStableId: String, artistIds: [Int64]) throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [trackStableId])

            for (position, artistId) in artistIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [trackStableId, artistId, position]
                )
            }
        }
    }

    // MARK: - 批量刮削目标查询（E1 标签刮削 library 模式）

    /// 查「year 缺失 或 genre 缺失」的曲目（web 批量 library 模式：只处理
    /// year 为空或 genre 为空 的歌曲）。year 存 album 表，genre 存 track 表——
    /// 故 LEFT JOIN album 判定 album.year IS NULL OR track.genre IS NULL。
    /// 查询失败抛 GRDB 错误（调用方 runBatch 原样上抛）。
    func getTracksMissingYearOrGenre() throws -> [Track] {
        return try read { db in
            try Track.fetchAll(db, sql: """
                SELECT track.* FROM track
                LEFT JOIN album ON album.id = track.album_id
                WHERE album.year IS NULL OR track.genre IS NULL
                ORDER BY track.title
            """)
        }
    }

}
