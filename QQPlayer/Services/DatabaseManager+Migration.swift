//
//  DatabaseManager+Migration.swift
//  QQPlayer
//
//  启动迁移：路径去重 + filename→path stableId 两步全表迁移（含 sync_outbox 重写），
//  完成门见 LegacyTrackMigrationGate。
//
//  2026-09-19 从 DatabaseManager.swift 原样搬出（纯搬家）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    /// 供本文件（setup 流程）调用（跨文件需 internal）。
    func migrateDatabaseIfNeeded() throws {
        var stableIdRemapping: [String: String] = [:]

        // The two full-table scans below (path dedup + stable-id migration)
        // are idempotent, but re-running them on every launch added visible
        // startup latency on 2000+ track libraries. Run them once and record
        // completion; upsertTrack's runtime dedup keeps new duplicates in
        // check afterwards (audit: two full-table scans per launch).
        //
        // D1：完成门只在**两个迁移块都成功**时置位（见 LegacyTrackMigrationGate）。
        // 此前任一块失败也上锁 → 半迁移状态永久固化。
        let needsLegacyMigration = !LegacyTrackMigrationGate.isCompleted()
        var pathDedupSucceeded = false
        var stableIdMigrationSucceeded = false

        try write { db in
            // Migration: Add folder sync columns to playlist table
            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN folder_path TEXT")
                print("✅ Database: Added folder_path column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: folder_path column already exists or migration failed: \(error)")
            }

            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN is_folder_synced BOOLEAN DEFAULT 0")
                print("✅ Database: Added is_folder_synced column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: is_folder_synced column already exists or migration failed: \(error)")
            }

            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN last_folder_sync INTEGER")
                print("✅ Database: Added last_folder_sync column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: last_folder_sync column already exists or migration failed: \(error)")
            }

            // Additive and nullable for compatibility with every existing
            // library. NULL means "not fingerprinted yet" and causes a
            // one-time metadata refresh; no existing rows or relationships
            // are rewritten by this migration.
            if try !db.columns(in: "track").contains(where: { $0.name == "modification_date" }) {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN modification_date INTEGER")
                print("✅ Database: Added modification_date column to track table")
            } else {
                print("ℹ️ Database migration: modification_date column already exists")
            }

            // E1-S3: genre column (web 版歌曲对象已含 genre；老库补列，新库
            // createTables 已含)。幂等：列已存在即跳过。独立成 internal 方法：
            // 生产迁移与 GenreParsingTests 老库补列测试共用同一实现。
            try Self.addTrackGenreColumnIfNeeded(db)

            // M3-1: content_hash column (跨端同步对账键；入库时算一次，存量惰性
            // 回填见 backfillTrackContentHashesIfNeeded)。新库 createTables 已含，
            // 老库此处补列。幂等：列已存在即跳过。独立成 internal 方法：生产迁移
            // 与 TrackContentHashTests 老库补列测试共用同一实现。
            try Self.addTrackContentHashColumnIfNeeded(db)

            // Migration: Add custom_cover_image_path column to playlist table
            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN custom_cover_image_path TEXT")
                print("✅ Database: Added custom_cover_image_path column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: custom_cover_image_path column already exists or migration failed: \(error)")
            }

            // Migration: Create deleted_folder_playlist table to prevent recreation of deleted folder playlists
            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS deleted_folder_playlist (
                        folder_path TEXT PRIMARY KEY,
                        deleted_at INTEGER NOT NULL
                    )
                """)
                print("✅ Database: Created deleted_folder_playlist table")
            } catch {
                print("ℹ️ Database migration: deleted_folder_playlist table already exists or migration failed: \(error)")
            }

            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS track_artist (
                        track_stable_id TEXT NOT NULL,
                        artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (track_stable_id, artist_id)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_artist ON track_artist(artist_id)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_track ON track_artist(track_stable_id)")
                try db.execute(sql: """
                    INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position)
                    SELECT stable_id, artist_id, 0
                    FROM track
                    WHERE artist_id IS NOT NULL
                """)
                print("✅ Database: Created/backfilled track_artist table")
            } catch {
                print("⚠️ Database migration: track_artist table setup failed: \(error)")
            }

            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS album_artist_link (
                        album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
                        artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (album_id, artist_id)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_artist ON album_artist_link(artist_id)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_album ON album_artist_link(album_id)")
                try db.execute(sql: """
                    INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                    SELECT id, artist_id, 0
                    FROM album
                    WHERE artist_id IS NOT NULL
                """)
                print("✅ Database: Created/backfilled album_artist_link table")
            } catch {
                print("⚠️ Database migration: album_artist_link table setup failed: \(error)")
            }

            if needsLegacyMigration {
                // Migration: remove true duplicates that point at the exact same file path.
                // Do not deduplicate by filename; different album folders may legally contain same-named files.
                do {
                    let allTracks = try Track.fetchAll(db)
                    let groupedByPath = Dictionary(grouping: allTracks, by: { track in
                        URL(fileURLWithPath: track.path).standardizedFileURL.path
                    })

                    for (path, duplicates) in groupedByPath where duplicates.count > 1 {
                        let sorted = duplicates.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
                        let keep = sorted.first!

                        for duplicate in sorted.dropFirst() {
                            // D3/D6：四表引用迁移走唯一入口（含 OR IGNORE + 清残留），
                            // 与 upsertTrack / moveTrack / migrateTrackStableIdAndPath 同源。
                            // 同 path 的重复行指向同一物理文件，其 play_history 是真实播放
                            // 记录 → 迁移到保留行的 stable ID（P0-3）。
                            try TrackIdentityMigration.migrateDatabaseReferences(
                                db,
                                from: duplicate.stableId,
                                to: keep.stableId
                            )
                            try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                        }

                        print("✅ Database: Removed \(duplicates.count - 1) duplicate track row(s) for path: \(path)")
                    }
                    pathDedupSucceeded = true
                } catch {
                    print("⚠️ Database migration: Path duplicate cleanup failed: \(error)")
                }

                // Migration: filename-based stable IDs collapse same-named songs in different albums.
                // Use normalized full paths so files in different folders remain distinct even with identical filenames.
                do {
                    let tracks = try Track.fetchAll(db)
                    var updatedCount = 0

                    for track in tracks {
                        let newStableId = Self.generatePathStableId(forPath: track.path)

                        guard track.stableId != newStableId else {
                            continue
                        }

                        try db.execute(
                            sql: "UPDATE track SET stable_id = ? WHERE id = ?",
                            arguments: [newStableId, track.id]
                        )

                        // D3/D6：四表引用迁移走唯一入口（此前 playlist_item 是裸
                        // UPDATE → 主键冲突会中断循环、让该行之后的所有曲目停在
                        // 旧 id，而完成门已置位 = 永久不再重试）
                        try TrackIdentityMigration.migrateDatabaseReferences(
                            db,
                            from: track.stableId,
                            to: newStableId
                        )

                        stableIdRemapping[track.stableId] = newStableId
                        updatedCount += 1
                    }

                    if updatedCount > 0 {
                        print("✅ Database: Migrated \(updatedCount) stable IDs from filename-based to path-based")
                    } else {
                        print("ℹ️ Database: Stable IDs already path-based")
                    }
                    stableIdMigrationSucceeded = true
                } catch {
                    print("⚠️ Database migration: Path-based stable ID migration failed: \(error)")
                }
                // D1：只有当前次两步都成功才上锁；失败 → 保持未置位，下次启动重试
                // （两步均幂等，重跑不会重复副作用）。
            }

            // Add UNIQUE constraint to stable_id to prevent duplicates
            do {
                try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_track_stable_id ON track(stable_id)")
                print("✅ Database: Created UNIQUE index on track.stable_id")
            } catch {
                print("⚠️ Database migration: Failed to create UNIQUE index on stable_id: \(error)")
            }

            // 2026-09-14（同步事故修复）：iOS 把既有 stableId 从「绝对路径派生」迁到
            // 「沙盒 Documents 相对路径派生」。本事务内完成 DB 侧（track + 业务四表 +
            // sync_outbox），文件侧引用的事务外迁移由调用方按 pendingStableIdFileRemapping
            // 消费。成功才置门（失败下次启动重试；迁移幂等）。
            #if os(iOS)
                do {
                    let key = Self.relativeStableIdMigrationKey
                    if !UserDefaults.standard.bool(forKey: key) {
                        self.pendingStableIdFileRemapping = try Self.migrateStableIdsToIdentityPaths(
                            db,
                            relativeRoot: Self.defaultStableIdRoot
                        )
                        UserDefaults.standard.set(true, forKey: key)
                    }
                } catch {
                    print("⚠️ Database migration: stableId 相对化迁移失败（下次启动重试）：\(error)")
                }
            #endif

            // M3-1: content_hash 索引（manifest 对账按内容指纹查同歌，设计 §7）。
            // 幂等：CREATE INDEX IF NOT EXISTS；列刚由上方 ALTER 补上，必存在。
            do {
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_content_hash ON track(content_hash)")
                print("✅ Database: Created index on track.content_hash")
            } catch {
                print("⚠️ Database migration: Failed to create index on content_hash: \(error)")
            }
        }

        // D3：文件侧引用（书签键 / 三个歌词目录 / 封面映射）走 stableId 变更唯一入口。
        // 这里替代了原先只迁书签键的 private migrateExternalFileBookmarkKeys——后者
        // 与旧库迁移路径下的歌词/封面映射丢失同源（审计 🟡-1）。
        if !stableIdRemapping.isEmpty {
            TrackIdentityMigration.migrateFileReferences(remapping: stableIdRemapping)
        }

        // Only mark completion after the write transaction committed AND both
        // migration blocks succeeded (D1), so a failed/partial migration is
        // retried on the next launch.
        if LegacyTrackMigrationGate.shouldMarkCompleted(
            pathDedupSucceeded: pathDedupSucceeded,
            stableIdMigrationSucceeded: stableIdMigrationSucceeded
        ) {
            LegacyTrackMigrationGate.markCompleted()
        }
    }
}
