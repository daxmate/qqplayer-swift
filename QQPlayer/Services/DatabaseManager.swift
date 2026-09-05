//
//  DatabaseManager.swift
//  QQPlayer
//
//  Database manager for the music library using GRDB
//
//  核心：连接/重试/迁移/schema/通用读写 + EQ CRUD + 挂起协调
//  （DatabaseSuspensionCoordinator）。拆分见
//  DatabaseManager+Tracks/Library/Playlists.swift。
//

import Combine
import CryptoKit
import Foundation
@preconcurrency import GRDB
#if os(iOS)
    import UIKit
#endif

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var dbWriter: DatabaseWriter!
    // A corrupted database fails deterministically, so repeating the same
    // open is pointless - one retry is enough to ride out transient failures
    // (file lock, iCloud download in progress) while capping startup latency
    // at ~0.5s. Persistent failures go to attemptDatabaseRecovery().
    private let maxRetries = 2
    private let retryDelay: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds

    static func generatePathStableId(forPath path: String) -> String {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: normalizedPath.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private init() {
        setupDatabaseWithRetry()
    }

    /// Test seam: point the manager at an injected (in-memory) writer so
    /// deleteTrack / upsert / migration paths are unit-testable without
    /// touching the app-group database. Production always uses the private init.
    init(dbWriter: DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    private func setupDatabaseWithRetry() {
        var lastError: Error?

        for attempt in 1 ... maxRetries {
            do {
                try setupDatabase()
                print("✅ Database initialized successfully on attempt \(attempt)")
                return
            } catch {
                lastError = error
                print("⚠️ Database setup failed on attempt \(attempt)/\(maxRetries): \(error)")

                if attempt < maxRetries {
                    // Wait before retrying
                    Thread.sleep(forTimeInterval: Double(retryDelay) / 1_000_000_000.0)
                }
            }
        }

        // If all retries failed, try to recover
        if let error = lastError {
            print("❌ Database setup failed after \(maxRetries) attempts. Attempting recovery...")
            attemptDatabaseRecovery(error: error)
        }
    }

    private func setupDatabase() throws {
        let databaseURL = try getDatabaseURL()

        // Use DatabasePool instead of DatabaseQueue to support concurrent reads
        // This is essential for CarPlay and other multi-threaded scenarios
        var configuration = Configuration()
        // The database lives in the app group container: holding a SQLite file
        // lock there while iOS suspends the process kills the app with
        // 0xdead10cc. DatabaseSuspensionCoordinator posts
        // Database.suspendNotification when the app is about to be suspended.
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            // Enable foreign key constraints
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbWriter = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try createTables()
        try migrateDatabaseIfNeeded()

        // Split combined multi-artist rows ("A; B") left by the old parser
        // (issue #16), then heal libraries where deleted tracks left empty
        // artists/albums behind (issue #74). Both are idempotent and cheap,
        // and run every launch.
        do {
            try migrateSplitCombinedArtistNames()
        } catch {
            print("⚠️ Combined artist split migration failed (non-fatal): \(error)")
        }
        // After artists are split, merge albums that the old per-track-artist
        // keying broke apart (issue #81)
        do {
            try migrateMergeSplitAlbums()
        } catch {
            print("⚠️ Split album merge migration failed (non-fatal): \(error)")
        }
        do {
            try cleanupOrphanedLibraryEntries()
        } catch {
            print("⚠️ Orphaned library cleanup failed (non-fatal): \(error)")
        }
    }

    private func attemptDatabaseRecovery(error: Error) {
        print("🔧 Attempting database recovery...")

        do {
            let databaseURL = try getDatabaseURL()
            let backupURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("qqplayer_backup_\(Int(Date().timeIntervalSince1970)).db")

            // Try to backup the corrupted database
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                try? FileManager.default.moveItem(at: databaseURL, to: backupURL)
                print("📦 Backed up corrupted database to: \(backupURL.path)")
            }

            // Try to create a fresh database
            try setupDatabase()
            print("✅ Database recovery successful - created fresh database")
        } catch {
            // The database file is corrupted beyond repair. Fall back to an
            // in-memory database so the app keeps running (degraded, empty
            // library) instead of force-exiting at launch. Migrations are
            // intentionally skipped: an in-memory database has no old data.
            print("❌ Database recovery failed: \(error)")
            print("⚠️ Database corrupted, running with in-memory fallback")
            setupInMemoryFallback()
        }
    }

    /// Creates a fresh in-memory database as a degraded-but-usable fallback
    /// when the on-disk database is corrupted beyond repair. Never crashes:
    /// if even the in-memory schema cannot be created, the app continues with
    /// whatever writer we can build rather than calling fatalError.
    private func setupInMemoryFallback() {
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }

            // Create in-memory database (fresh schema via createTables(); the
            // additive ALTER TABLE migrations inside it are idempotent and
            // safe on a brand-new schema).
            dbWriter = try DatabaseQueue(configuration: configuration)
            try createTables()
            print("✅ In-memory database created successfully (degraded mode: library starts empty)")
        } catch {
            // Absolute last resort - keep the app alive instead of crashing.
            print("❌ Failed to create in-memory fallback database: \(error)")
            print("⚠️ Continuing without a usable database (degraded mode)")
            if dbWriter == nil {
                dbWriter = try? DatabaseQueue()
            }
        }
    }

    private func getDatabaseURL() throws -> URL {
        #if os(macOS)
            // macOS 无 iOS 的 App Group 容器（目录不存在，GRDB 打开必失败，
            // 导致 in-memory fallback，扫描全部白跑）。用 Application Support
            // 独立目录，与桌面版（~/Library/Application Support/qqplayer/）区分。
            // 路径决策上收：DatabasePathResolver.macDatabaseURL（有单测锁定）。
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first!
            let url = DatabasePathResolver.macDatabaseURL(appSupportRoot: appSupport)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return url
        #else
            // Try to use app group container first for sharing with Siri extension
            // 决策上收：DatabasePathResolver.iosDatabaseURL（有单测锁定）。
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios")
            let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                         in: .userDomainMask).first!
            return DatabasePathResolver.iosDatabaseURL(
                appGroupContainer: containerURL,
                documentsDirectory: documentsPath)
        #endif
    }

    /// Creates the full production schema. Internal so tests can build an
    /// in-memory database via the `init(dbWriter:)` seam.
    func createTables() throws {
        try dbWriter.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS artist (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL COLLATE NOCASE
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS album (
                    id INTEGER PRIMARY KEY,
                    artist_id INTEGER REFERENCES artist(id) ON DELETE CASCADE,
                    title TEXT NOT NULL COLLATE NOCASE,
                    year INTEGER,
                    album_artist TEXT COLLATE NOCASE
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track (
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
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track_artist (
                    track_stable_id TEXT NOT NULL,
                    artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (track_stable_id, artist_id)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS album_artist_link (
                    album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
                    artist_id INTEGER NOT NULL REFERENCES artist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (album_id, artist_id)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS favorite (
                    track_stable_id TEXT PRIMARY KEY
                )
            """)

            // Play history (automatic playlists data source: recent/top played).
            // 与 migrateDatabaseIfNeeded 中的定义保持一致；测试内存库依赖此建表
            // （PlayHistoryRecorder 写路径，2026-08-30 批次 D 测试暴露缺失）。
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS play_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    track_stable_id TEXT NOT NULL,
                    played_at INTEGER NOT NULL,
                    play_duration_ms INTEGER DEFAULT 0
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_play_history_track ON play_history(track_stable_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_play_history_played_at ON play_history(played_at)")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist (
                    id INTEGER PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_played_at INTEGER DEFAULT 0,
                    folder_path TEXT,
                    is_folder_synced BOOLEAN DEFAULT 0,
                    last_folder_sync INTEGER
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist_item (
                    playlist_id INTEGER REFERENCES playlist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    track_stable_id TEXT NOT NULL,
                    PRIMARY KEY (playlist_id, position)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS deleted_folder_playlist (
                    folder_path TEXT PRIMARY KEY,
                    deleted_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_album ON track(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist ON track(artist_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_artist ON track_artist(artist_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist_track ON track_artist(track_stable_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_artist ON album_artist_link(artist_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_artist_link_album ON album_artist_link(album_id)")
            // Per-import lookups: path duplicate check and stale-duplicate prefilter
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_path ON track(path)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_dup_check ON track(artist_id, duration_ms, file_size)")

            // EQ Tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_preset (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    is_built_in INTEGER DEFAULT 0,
                    is_active INTEGER DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_band (
                    id INTEGER PRIMARY KEY,
                    preset_id INTEGER NOT NULL REFERENCES eq_preset(id) ON DELETE CASCADE,
                    frequency REAL NOT NULL,
                    gain REAL NOT NULL DEFAULT 0.0,
                    bandwidth REAL NOT NULL DEFAULT 0.5,
                    band_index INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_settings (
                    id INTEGER PRIMARY KEY,
                    is_enabled INTEGER DEFAULT 0,
                    active_preset_id INTEGER REFERENCES eq_preset(id) ON DELETE SET NULL,
                    global_gain REAL DEFAULT 0.0,
                    updated_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_eq_band_preset ON eq_band(preset_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_eq_band_index ON eq_band(band_index)")

            // Play history (automatic playlists data source: recent/top played)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS play_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    track_stable_id TEXT NOT NULL,
                    played_at INTEGER NOT NULL,
                    play_duration_ms INTEGER DEFAULT 0
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_play_history_track ON play_history(track_stable_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_play_history_played_at ON play_history(played_at)")

            // Migration: Add last_played_at column if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE playlist ADD COLUMN last_played_at INTEGER DEFAULT 0
                """)
                print("✅ Database: Added last_played_at column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: last_played_at column already exists or migration failed: \(error)")
            }

            // Migration: Add preset_type column to eq_preset if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE eq_preset ADD COLUMN preset_type TEXT DEFAULT 'imported'
                """)
                print("✅ Database: Added preset_type column to eq_preset table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: preset_type column already exists or migration failed: \(error)")
            }
        }
    }

    /// 老库 track 表补 genre 列（E1-S3）。幂等：列已存在直接跳过。
    /// 独立成 internal：生产迁移（migrateDatabaseIfNeeded）与测试
    /// （GenreParsingTests 老 schema → 补列 → 往返）共用同一实现，避免两处漂移。
    static func addTrackGenreColumnIfNeeded(_ db: Database) throws {
        if try !db.columns(in: "track").contains(where: { $0.name == "genre" }) {
            try db.execute(sql: "ALTER TABLE track ADD COLUMN genre TEXT")
            print("✅ Database: Added genre column to track table")
        } else {
            print("ℹ️ Database migration: genre column already exists")
        }
    }

    private func migrateDatabaseIfNeeded() throws {
        var stableIdRemapping: [String: String] = [:]

        // The two full-table scans below (path dedup + stable-id migration)
        // are idempotent, but re-running them on every launch added visible
        // startup latency on 2000+ track libraries. Run them once and record
        // completion; upsertTrack's runtime dedup keeps new duplicates in
        // check afterwards (audit: two full-table scans per launch).
        let legacyMigrationKey = "database.legacyTrackMigrationsCompleted.v2"
        let needsLegacyMigration = !UserDefaults.standard.bool(forKey: legacyMigrationKey)
        var didRunLegacyMigration = false

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
                            try db.execute(
                                sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                                arguments: [keep.stableId, duplicate.stableId]
                            )
                            try db.execute(
                                sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                                arguments: [keep.stableId, duplicate.stableId]
                            )
                            try db.execute(
                                sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                                arguments: [keep.stableId, duplicate.stableId]
                            )
                            try db.execute(sql: "DELETE FROM favorite WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                            try db.execute(sql: "DELETE FROM playlist_item WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                            // Duplicate rows are the SAME physical file, so their play
                            // history records real plays of the kept song - migrate it
                            // to the kept stable ID instead of dropping it (P0-3)
                            try db.execute(
                                sql: "UPDATE play_history SET track_stable_id = ? WHERE track_stable_id = ?",
                                arguments: [keep.stableId, duplicate.stableId]
                            )
                            try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                        }

                        print("✅ Database: Removed \(duplicates.count - 1) duplicate track row(s) for path: \(path)")
                    }
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

                        try db.execute(
                            sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [newStableId, track.stableId]
                        )

                        try db.execute(
                            sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [newStableId, track.stableId]
                        )

                        try db.execute(
                            sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [newStableId, track.stableId]
                        )
                        try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [track.stableId])

                        // Play history follows the song to its new path-based ID
                        // instead of being orphaned (P0-3)
                        try db.execute(
                            sql: "UPDATE play_history SET track_stable_id = ? WHERE track_stable_id = ?",
                            arguments: [newStableId, track.stableId]
                        )

                        stableIdRemapping[track.stableId] = newStableId
                        updatedCount += 1
                    }

                    if updatedCount > 0 {
                        print("✅ Database: Migrated \(updatedCount) stable IDs from filename-based to path-based")
                    } else {
                        print("ℹ️ Database: Stable IDs already path-based")
                    }
                } catch {
                    print("⚠️ Database migration: Path-based stable ID migration failed: \(error)")
                    // Don't throw - allow app to continue and re-index will handle it
                }
                didRunLegacyMigration = true
            }

            // Add UNIQUE constraint to stable_id to prevent duplicates
            do {
                try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_track_stable_id ON track(stable_id)")
                print("✅ Database: Created UNIQUE index on track.stable_id")
            } catch {
                print("⚠️ Database migration: Failed to create UNIQUE index on stable_id: \(error)")
            }
        }

        migrateExternalFileBookmarkKeys(stableIdRemapping)

        // Only mark completion after the write transaction committed, so a
        // failed migration is retried on the next launch.
        if didRunLegacyMigration {
            UserDefaults.standard.set(true, forKey: legacyMigrationKey)
        }
    }

    private func migrateExternalFileBookmarkKeys(_ stableIdRemapping: [String: String]) {
        guard !stableIdRemapping.isEmpty else { return }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else { return }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard var bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                return
            }

            var updatedCount = 0
            for (oldStableId, newStableId) in stableIdRemapping {
                guard let bookmarkData = bookmarks.removeValue(forKey: oldStableId) else {
                    continue
                }

                bookmarks[newStableId] = bookmarkData
                updatedCount += 1
            }

            guard updatedCount > 0 else { return }

            let updatedData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try updatedData.write(to: bookmarksURL, options: .atomic)
            print("✅ Database: Migrated \(updatedCount) external bookmark stable IDs")
        } catch {
            print("⚠️ Database migration: Failed to migrate external bookmark stable IDs: \(error)")
        }
    }

    func read<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.read(operation)
    }

    func write<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.write(operation)
    }

    // SwiftUI rows call getArtistDisplayName on every render - cache the
    // joined names so scrolling doesn't hit the database per visible row
    let artistDisplayNameCacheLock = NSLock()
    var artistDisplayNameCache: [String: String] = [:]

    // MARK: - EQ Operations

    func getAllEQPresets() async throws -> [EQPreset] {
        try await dbWriter.read { db in
            return try EQPreset.order(Column("name")).fetchAll(db)
        }
    }

    func getEQPreset(id: Int64) async throws -> EQPreset? {
        try await dbWriter.read { db in
            return try EQPreset.filter(Column("id") == id).fetchOne(db)
        }
    }

    func saveEQPreset(_ preset: EQPreset) async throws -> EQPreset {
        try await dbWriter.write { db in
            return try preset.insertAndFetch(db) ?? preset
        }
    }

    func deleteEQPreset(_ preset: EQPreset) async throws {
        _ = try await dbWriter.write { db in
            try preset.delete(db)
        }
    }

    func getBands(for preset: EQPreset) async throws -> [EQBand] {
        guard let presetId = preset.id else { return [] }
        return try await dbWriter.read { db in
            return try EQBand
                .filter(Column("preset_id") == presetId)
                .order(Column("band_index"))
                .fetchAll(db)
        }
    }

    func saveEQBand(_ band: EQBand) async throws {
        try await dbWriter.write { db in
            try band.save(db)
        }
    }

    func getEQSettings() async throws -> EQSettings? {
        try await dbWriter.read { db in
            return try EQSettings.fetchOne(db)
        }
    }

    func saveEQSettings(_ settings: EQSettings) async throws {
        try await dbWriter.write { db in
            // Delete existing settings first (there should only be one row)
            try EQSettings.deleteAll(db)
            try settings.save(db)
        }
    }
}

// MARK: - Suspension coordination (0xdead10cc)

/// Suspends GRDB when the app is about to be suspended by iOS.
///
/// The database lives in the app group container. If SQLite still holds a
/// file lock when the process is suspended, the kernel kills the app with
/// 0xdead10cc - the most frequent crash across all shipped versions.
///
/// Background audio keeps the process alive and legitimately writing (play
/// counts, queue state), so the database is only suspended while the app is
/// backgrounded AND playback is stopped. It resumes on foregrounding or when
/// playback restarts (e.g. from the lock screen or a remote command).
@MainActor
final class DatabaseSuspensionCoordinator {
    static let shared = DatabaseSuspensionCoordinator()

    private var observers: [NSObjectProtocol] = []
    private var playbackCancellable: AnyCancellable?
    private var isInBackground = false
    private var isPlaying = false
    private var isSuspended = false

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        #if os(iOS)
            let backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { @Sendable _ in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isInBackground = true
                    coordinator.apply()
                }
            }
            observers.append(backgroundObserver)

            let foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { @Sendable _ in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isInBackground = false
                    coordinator.apply()
                }
            }
            observers.append(foregroundObserver)
        #endif

        isPlaying = PlayerEngine.shared.isPlaying
        playbackCancellable = PlayerEngine.shared.$isPlaying
            .removeDuplicates()
            .sink { playing in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isPlaying = playing
                    coordinator.apply()
                }
            }
    }

    private func apply() {
        let shouldSuspend = isInBackground && !isPlaying
        guard shouldSuspend != isSuspended else { return }
        isSuspended = shouldSuspend
        NotificationCenter.default.post(
            name: shouldSuspend ? Database.suspendNotification : Database.resumeNotification,
            object: nil
        )
        print(shouldSuspend
            ? "🛑 Database suspended (backgrounded, not playing)"
            : "▶️ Database resumed")
    }
}
