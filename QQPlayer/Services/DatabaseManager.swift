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
//  身份键自愈（M3-1 后续，2026-09-14）：track.content_hash 是跨端歌曲身份键，缺它
//  接收侧只能把对端 stableId 原样落库 → 孤儿行。回填**不再**走一次性完成门（旧 key
//  database.contentHashBackfillCompleted.v1 已退役并在启动时清理）——取舍：一次性门省下
//  的只是「零 NULL 行时的一次索引查询」，代价却是「入库时没算到指纹」的行永久 NULL
//  （哪怕文件一直在本地），跨端身份随之永久对不上；故改为每次启动在后台队列自愈跑一遍，
//  保留 dataless（云端未下载）跳过语义，补齐后顺手重放该指纹下的挂起变更。
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

    // content_hash 惰性回填的专用后台队列（串行）：主线程零文件 IO——dataless
    // iCloud 文件的读取会触发云端下载并长时间阻塞，绝不能在启动路径同步跑。
    private static let contentHashBackfillQueue = DispatchQueue(
        label: "com.daxmate.qqplayer.content-hash-backfill",
        qos: .utility
    )
    /// 防重复入队（只在 setupDatabase 调用一次；锁保护以兼容重试路径）。
    private let contentHashBackfillEnqueueLock = NSLock()
    private var contentHashBackfillEnqueued = false

    /// 端内歌曲身份的**基准根**：iOS = 沙盒 Documents，macOS = nil（绝对路径）。
    ///
    /// 为什么分平台（2026-09-14 同步事故修复）：iOS 数据容器 UUID 会变（重装 / 迁移），
    /// 用绝对路径派生身份 → **整库 stable_id 全变** → 业务表引用（靠
    /// `TrackIdentityMigration` 迁移）看着还行，但 `sync_outbox` 里的行键/载荷仍是旧 id
    /// → 发送端查不到 track 行 → 整批变更拿不到身份键、对端全部判「未定位」。
    /// macOS 曲库路径稳定且支持多根，改相对只会在无收益的情况下打乱既有身份，故不动。
    /// 跨端身份恒为 `content_hash`，stableId 只是端内身份，两端各自演进没有兼容问题。
    static var defaultStableIdRoot: URL? {
        #if os(iOS)
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #else
            return nil
        #endif
    }

    /// stableId 的唯一输入：标准化路径在基准根之下时改写成**相对路径**（跨容器前缀
    /// 变化稳定）；不在根下 / 无基准根 → 回落绝对路径（保守，不误改）。
    /// 纯函数（基准根可注入），迁移与测试共用同一事实源，避免两处派生漂移。
    static func identityPath(forPath path: String, relativeRoot: URL?) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let rootPath = relativeRoot?.standardizedFileURL.path, !rootPath.isEmpty else {
            return normalized
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard normalized.hasPrefix(prefix) else { return normalized }
        return String(normalized.dropFirst(prefix.count))
    }

    static func generatePathStableId(forPath path: String) -> String {
        generatePathStableId(forPath: path, relativeRoot: defaultStableIdRoot)
    }

    /// 可注入基准根的版本（迁移 / 测试用）。
    static func generatePathStableId(forPath path: String, relativeRoot: URL?) -> String {
        let identityPath = identityPath(forPath: path, relativeRoot: relativeRoot)
        let digest = SHA256.hash(data: identityPath.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - stableId 相对化迁移（iOS 一次性；含 sync_outbox）

    /// 迁移完成门（UserDefaults）：成功才置位，失败下次启动重试（迁移幂等）。
    static let relativeStableIdMigrationKey = "database.relativeStableIdMigrationCompleted.v1"

    /// `createTables` 事务内产出的 old→new 映射，事务外消费做文件侧引用迁移
    /// （文件 IO 不进写事务）。
    private var pendingStableIdFileRemapping: [String: String] = [:]

    /// 把既有 stableId（绝对路径派生）迁到「曲库根相对路径」派生（iOS）。
    ///
    /// **必须连 `sync_outbox` 一起迁**：身份变更牵动的引用有七处——业务四表、外部文件
    /// 书签、三个歌词目录、封面映射（前六处由 `TrackIdentityMigration` 负责），以及
    /// **同步层 `sync_outbox` 的行键/载荷**（本函数负责）。漏掉 outbox 的后果就是
    /// 2026-09-14 的事故：业务表看着正常、同步整批发不出去。
    ///
    /// - Returns: old→new 映射（供事务外文件侧迁移与日志）。
    @discardableResult
    static func migrateStableIdsToIdentityPaths(
        _ db: Database,
        relativeRoot: URL?
    ) throws -> [String: String] {
        guard relativeRoot != nil else { return [:] }
        var remapping: [String: String] = [:]
        var skippedOccupied = 0
        for track in try Track.fetchAll(db) {
            let newStableId = generatePathStableId(forPath: track.path, relativeRoot: relativeRoot)
            guard track.stableId != newStableId else { continue }
            // 目标 id 已被别的行占用（理论上不可达：同一容器内相对路径唯一）→ 保守跳过，
            // 不做会撞唯一索引的改写（撞了会回滚整个迁移事务）。
            let occupied = try Track
                .filter(Column("stable_id") == newStableId && Column("id") != track.id)
                .fetchCount(db)
            guard occupied == 0 else {
                skippedOccupied += 1
                continue
            }
            try db.execute(
                sql: "UPDATE track SET stable_id = ? WHERE id = ?",
                arguments: [newStableId, track.id]
            )
            // 业务四表引用跟随（唯一入口；OR IGNORE + 清残留，幂等）
            try TrackIdentityMigration.migrateDatabaseReferences(db, from: track.stableId, to: newStableId)
            remapping[track.stableId] = newStableId
        }
        guard !remapping.isEmpty else { return [:] }
        let outboxRows = try rewriteSyncOutboxReferences(db, remapping: remapping)
        print("✅ Database: stableId 相对化迁移 \(remapping.count) 首（sync_outbox 改写 \(outboxRows) 行，跳过占用 \(skippedOccupied)）")
        return remapping
    }

    /// `sync_outbox` 行的歌曲引用改写：`row_key` 与 `payload_json` 里的稳定 id 子串
    /// 替换（stableId 是 64 位十六进制，无歧义）。只 UPDATE 已有行，**不新增、不删除**。
    /// 引用歌曲的实体（favorite / play_history / playlist_item / playback_position）的
    /// 行键与载荷都承载 stableId；歌单（playlist）不承载，替换自然不命中。
    @discardableResult
    static func rewriteSyncOutboxReferences(
        _ db: Database,
        remapping: [String: String]
    ) throws -> Int {
        guard !remapping.isEmpty else { return 0 }
        var updated = 0
        for row in try SyncChangeLogRow.fetchAll(db) {
            var rowKey = row.rowKey
            var payload = row.payloadJSON
            var changed = false
            for (oldId, newId) in remapping {
                if rowKey.contains(oldId) {
                    rowKey = rowKey.replacingOccurrences(of: oldId, with: newId)
                    changed = true
                }
                if let current = payload, current.contains(oldId) {
                    payload = current.replacingOccurrences(of: oldId, with: newId)
                    changed = true
                }
            }
            guard changed, let rowId = row.id else { continue }
            try db.execute(
                sql: "UPDATE sync_outbox SET row_key = ?, payload_json = ? WHERE id = ?",
                arguments: [rowKey, payload, rowId]
            )
            updated += 1
        }
        return updated
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
                dbDiag("⚠️ setup failed attempt \(attempt)/\(maxRetries) error=\(error)")
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

    /// 把 content_hash 回填丢到专用后台串行队列（启动路径**不阻塞主线程**）。
    /// 失败只打印不抛：回填幂等，下次启动自动重试。
    /// 回填跑完后再打一行身份缺失普查（只读统计）——放在回填之后，报的是补齐后的余量。
    private func scheduleContentHashBackfillInBackground() {
        contentHashBackfillEnqueueLock.lock()
        if contentHashBackfillEnqueued {
            contentHashBackfillEnqueueLock.unlock()
            return
        }
        contentHashBackfillEnqueued = true
        contentHashBackfillEnqueueLock.unlock()

        let manager = self
        Self.contentHashBackfillQueue.async {
            do {
                try manager.backfillTrackContentHashesIfNeeded()
            } catch {
                print("⚠️ Database: content_hash backfill failed (will retry next launch): \(error)")
            }
            manager.logIdentityCensus()
        }
    }

    /// 身份缺失普查汇总一行（只读诊断；失败只打印，绝不影响启动）。
    private func logIdentityCensus() {
        do {
            print(try identityCensus().summaryLine)
        } catch {
            print("⚠️ Database: identity census failed (diagnostic only): \(error)")
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

        do {
            dbWriter = try DatabasePool(path: databaseURL.path, configuration: configuration)
        } catch {
            dbDiag("❌ open failed path=\(databaseURL.path) error=\(error)")
            throw error
        }
        dbDiag("✅ open OK path=\(databaseURL.path)")
        try createTables()
        // stableId 相对化迁移的**文件侧**引用（书签 / 三个歌词目录 / 封面映射）在事务外做：
        // 文件 IO 不进写事务；失败只记日志（DB 侧已提交，下次入库/对账再走）。
        if !pendingStableIdFileRemapping.isEmpty {
            let report = TrackIdentityMigration.migrateFileReferences(remapping: pendingStableIdFileRemapping)
            print("✅ Database: stableId 迁移文件侧引用（书签 \(report.bookmarksRenamed) / 歌词 \(report.lyricsFilesRenamed) / 封面 \(report.artworkKeysRenamed)）")
            pendingStableIdFileRemapping = [:]
        }
        try migrateDatabaseIfNeeded()

        // M3-1: content_hash 存量惰性回填已**移出启动主线程**——dataless（云端未下载）
        // iCloud 文件的 FileHandle.read 会触发云端下载并长时间阻塞（实测 20+ 分钟
        // 不返回）→ 主线程卡死、App 无响应。改为专用串行队列后台执行（见
        // scheduleContentHashBackfillInBackground）。
        scheduleContentHashBackfillInBackground()

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
        dbDiag("🔧 recovery start originalError=\(error)")
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
            dbDiag("✅ recovery OK (fresh database created)")
            print("✅ Database recovery successful - created fresh database")
        } catch {
            // The database file is corrupted beyond repair. Fall back to an
            // in-memory database so the app keeps running (degraded, empty
            // library) instead of force-exiting at launch. Migrations are
            // intentionally skipped: an in-memory database has no old data.
            dbDiag("⚠️ recovery failed → in-memory fallback reason=\(error)")
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
            dbDiag("✅ in-memory created (DEGRADED: library starts empty)")
            print("✅ In-memory database created successfully (degraded mode: library starts empty)")
        } catch {
            // Absolute last resort - keep the app alive instead of crashing.
            dbDiag("❌ in-memory creation failed error=\(error)")
            print("❌ Failed to create in-memory fallback database: \(error)")
            print("⚠️ Continuing without a usable database (degraded mode)")
            if dbWriter == nil {
                dbWriter = try? DatabaseQueue()
            }
        }
    }

    // MARK: - DB 打开诊断（2026-09-15）

    /// 把「选了哪条路径 → 拿到没拿到 App Group 容器 → 打开结果 → 降级原因」追加写入
    /// 容器内 `Documents/db-debug.log`（环形：超 256KB 留尾部 64KB）。
    ///
    /// 为什么落盘：iOS 的 `print` 只进 stdout，真机拿不到（`devicectl process launch
    /// --console` 实测报 CoreDeviceError 10002）。而「静默降级成一局空库」我们已经栽过两次
    /// —— 这条日志让降级原因可离线取证（拉容器文件即可读）。
    /// 只在启动期决策点写（每次启动 ≤ 6 行），不进任何热路径；诊断自身失败绝不影响启动。
    private func dbDiag(_ message: String) {
        #if os(iOS)
            guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("db-debug.log") else { return }
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            do {
                if FileManager.default.fileExists(atPath: url.path),
                   let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
                   size > 256_000 {
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        defer { _ = try? handle.close() }
                        try? handle.seek(toOffset: UInt64(max(0, size - 64_000)))
                        let tail = handle.readDataToEndOfFile()
                        _ = try? tail.write(to: url, options: .atomic)
                    }
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { _ = try? handle.close() }
                    _ = try? handle.seekToEnd()
                    _ = try? handle.write(contentsOf: Data(line.utf8))
                    return
                }
                try line.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // 诊断日志失败不影响启动
            }
        #endif
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
            let resolved = DatabasePathResolver.iosDatabaseURL(
                appGroupContainer: containerURL,
                documentsDirectory: documentsPath)
            dbDiag("🔎 resolve appGroup=\(containerURL == nil ? "nil" : containerURL!.path) "
                + "documents=\(documentsPath.path) → chosen=\(resolved.path) "
                + "exists=\(FileManager.default.fileExists(atPath: resolved.path))")
            return resolved
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
                    content_hash TEXT,
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
                    last_folder_sync INTEGER,
                    custom_cover_image_path TEXT
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

            // 注：play_history 建表/索引在本函数上方（约 :315）已定义一次，此处原先
            // 逐字重复的同样 DDL 已删除（第二遍恒为空操作，审计 ⚰️-6）。

            // 局域网同步配对记录（S2, M1；docs/lan-sync-design.md §7）。
            // 新表对旧库亦生效：createTables 每次启动都跑（CREATE TABLE IF
            // NOT EXISTS 幂等），旧库下次启动自动补表（与 eq_* / play_history
            // 新增表同一模式，无需 ALTER）。列定义与 DeviceStore 的 upsert SQL
            // 及 PeerDevice(Codable, FetchableRecord, PersistableRecord) 对齐。
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_device (
                    peer_id TEXT PRIMARY KEY,
                    peer_public_key TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    role TEXT NOT NULL,
                    paired_at INTEGER NOT NULL,
                    last_seen_at INTEGER NOT NULL,
                    notes TEXT,
                    updated_at INTEGER NOT NULL
                )
            """)

            // 局域网同步播放数据（S2, M4-1；docs/lan-sync-design.md §6.2/§7）。
            // 新表对旧库亦生效：createTables 每次启动都跑（CREATE TABLE IF
            // NOT EXISTS 幂等），旧库下次启动自动补表（同 sync_device 模式）。
            // 模型见 Sync/SyncDataSyncModels.swift；存储/对账见 SyncChangeLogStore.swift。
            // - sync_outbox：本地变更日志（每端一份），LWW 键 = (entity, row_key)，
            //   updated_at 毫秒；payload_json = 该行完整数据快照（对端胜出可直接应用）。
            // - sync_cursor：per-peer **拉取**游标（peer_id = DeviceID，last_outbox_id = 本端
            //   已消费的对端 outbox 最大 id）。拉取应答（pull 请求携带）与收推送后推进共用。
            // - sync_push_cursor：per-peer **推送**游标（last_outbox_id = 本端**已推给对端**的
            //   本端 outbox 最大 id）。⚠️ 与 sync_cursor **方向相反**（一个描述对方 outbox，
            //   一个描述本端 outbox），键同为 peer_id 却语义相反，故刻意分表——合表必被写错。
            //   模型见 SyncDataSyncModels.swift 的 SyncPeerPushCursor。
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity TEXT NOT NULL,
                    row_key TEXT NOT NULL,
                    op TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    payload_json TEXT
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sync_outbox_entity_row ON sync_outbox(entity, row_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sync_outbox_updated ON sync_outbox(updated_at)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_cursor (
                    peer_id TEXT PRIMARY KEY,
                    last_outbox_id INTEGER NOT NULL DEFAULT 0
                )
            """)

            // 推送游标（S2-T12，2026-09-13）：本端 outbox 已推给某 peer 的位置。
            // 与 sync_cursor 并列但**方向相反**（见上）；同样幂等建表，旧库启动自动补表。
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_push_cursor (
                    peer_id TEXT PRIMARY KEY,
                    last_outbox_id INTEGER NOT NULL DEFAULT 0
                )
            """)

            // 局域网同步挂起变更（S2, M4-2a）：“远端变更引用的歌曲本地还没有”时
            // 挂起在此（row_key = content_hash），歌曲入库后重放，不丢数据。
            // 模型/存储/重放见 Sync/SyncChangeLogPendingStore.swift，映射见
            // Sync/SyncChangeLogMapping.swift。唯一索引 (entity, row_key,
            // remote_row_key) = 挂起行幂等 upsert 的冲突目标（重复拉取不产生重复行）。
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_pending_change (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity TEXT NOT NULL,
                    row_key TEXT NOT NULL,
                    remote_row_key TEXT NOT NULL,
                    op TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    payload_json TEXT
                )
            """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_pending_identity
                ON sync_pending_change(entity, row_key, remote_row_key)
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sync_pending_row_key ON sync_pending_change(row_key)")

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

    /// 老库 track 表补 content_hash 列（M3-1，跨端同步对账键 = 文件内容 SHA-256）。
    /// 幂等：列已存在直接跳过。
    /// 独立成 internal：生产迁移（migrateDatabaseIfNeeded）与测试
    /// （TrackContentHashTests 老 schema → 补列 → 往返）共用同一实现，避免两处漂移。
    static func addTrackContentHashColumnIfNeeded(_ db: Database) throws {
        if try !db.columns(in: "track").contains(where: { $0.name == "content_hash" }) {
            try db.execute(sql: "ALTER TABLE track ADD COLUMN content_hash TEXT")
            print("✅ Database: Added content_hash column to track table")
        } else {
            print("ℹ️ Database migration: content_hash column already exists")
        }
    }

    private func migrateDatabaseIfNeeded() throws {
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

    func read<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.read(operation)
    }

    func write<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.write(operation)
    }

    // MARK: - content_hash（M3-1）

    /// 文件存在则流式计算 SHA-256；不存在/读失败返回 nil（调用方按"未指纹"
    /// 处理，后续 upsert 或惰性回填会再试）。复用 Sync/SyncFileChecksum（共享实现，
    /// 协议目录只读），不另起哈希逻辑。
    ///
    /// iCloud dataless（云端未下载）文件同样返回 nil 并**不读取内容**——流式读取会
    /// 触发云端下载并长时间阻塞（实测 20+ 分钟不返回），是启动主线程卡死的根因。
    /// 可用性判定注入以便单测；默认走唯一判定 CloudFileAvailability。
    static func contentHashIfFilePresent(
        atPath path: String,
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard isLocallyAvailable(url) else { return nil }
        return try? SyncFileChecksum.sha256Hex(ofFile: url)
    }

    /// content_hash 存量自愈回填（**无一次性门**，每次启动在后台队列跑一遍）。
    ///
    /// 取舍：旧实现用一次性完成门 database.contentHashBackfillCompleted.v1 挡重复扫描，
    /// 省下的只是「零 NULL 行时的一次索引查询」；代价是只要门被置位（含「文件当时不存在」
    /// 这类非云端跳过），NULL 指纹就**永不重试** → 身份键永久缺失，跨端同步永久对不上。
    /// 改成「上次运行标记」后：每次启动都尝试，零 NULL 行时仅一次索引查询即返回；
    /// dataless/文件未就绪只是本次跳过，下次启动自然重试。
    ///
    /// 补齐后对本次新填的每个 content_hash 调用 SyncChangeLogReplay.replay
    /// ——「因缺身份键而长期挂起的对端播放数据」借此落库。重放失败只打日志。
    ///
    /// ⚠️ 不再在启动主线程调用——见 scheduleContentHashBackfillInBackground()
    /// （dataless iCloud 文件会阻塞主线程）。
    /// - Parameters:
    ///   - defaults: 运行标记所用 UserDefaults（测试注入独立 suite）。
    ///   - isLocallyAvailable: 本地可读性判定（避免读取 dataless 文件触发云端下载）。
    /// - Returns: 本次回填结果（新填指纹列表 + 跳过/候选计数）。
    @discardableResult
    func backfillTrackContentHashesIfNeeded(
        defaults: UserDefaults = .standard,
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) throws -> ContentHashBackfillOutcome {
        if ContentHashBackfillMarker.removeRetiredCompletionGate(defaults: defaults) {
            print("ℹ️ Database: 退役一次性 content_hash 回填门（改为每次启动自愈回填）")
        }

        let outcome = try backfillMissingContentHashesDetailed(isLocallyAvailable: isLocallyAvailable)
        ContentHashBackfillMarker.markRun(defaults: defaults)

        // 身份键补齐 → 重放之前因「本地查不到该 content_hash」而挂起的对端变更。
        for hash in outcome.filledHashes {
            do {
                let replayed = try SyncChangeLogReplay.replay(contentHash: hash, database: self)
                if replayed > 0 {
                    print("🔁 Sync: 回填指纹后重放挂起变更 \(replayed) 条（hash=\(hash.prefix(12))…）")
                }
            } catch {
                print("⚠️ Sync: 回填后挂起变更重放失败（下次回填/入库再试）：\(error)")
            }
        }

        if outcome.skippedCloudOnly > 0 {
            print("⏭️ Database: content_hash backfill skipped \(outcome.skippedCloudOnly) cloud-only track(s); will retry next launch")
        }
        return outcome
    }

    /// 回填核心（internal 供测试直调）：扫 content_hash IS NULL 行 → 文件存在且本地已
    /// 实体化则算 SHA-256 → 批量 UPDATE。幂等：再跑一遍无 NULL 行可补，不崩。
    /// - Returns: 因 iCloud 云端未下载被跳过的曲目数（文件不存在的旧行为不计入）。
    @discardableResult
    func backfillMissingContentHashes(
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) throws -> Int {
        try backfillMissingContentHashesDetailed(isLocallyAvailable: isLocallyAvailable).skippedCloudOnly
    }

    /// 回填核心（详版）：与 backfillMissingContentHashes 同一套语义，另外交出本次新填的
    /// content_hash 列表（启动路径据此重放挂起变更）。
    @discardableResult
    func backfillMissingContentHashesDetailed(
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) throws -> ContentHashBackfillOutcome {
        struct PendingFill {
            let id: Int64
            let hash: String
        }

        // Phase 1: 只读事务取候选（无文件 IO）。走 idx_track_content_hash 索引。
        let candidates = try read { db in
            try Track.filter(sql: "content_hash IS NULL").fetchAll(db)
        }
        guard !candidates.isEmpty else {
            // 零 NULL 行：到此为止（一次索引查询），不写库、不触发重放。
            return ContentHashBackfillOutcome(filledHashes: [], skippedCloudOnly: 0, candidateCount: 0)
        }

        // Phase 2: 事务外逐文件哈希（syscalls 不碰 GRDB writer）。
        var pending: [PendingFill] = []
        var skippedCloudOnly = 0
        for track in candidates {
            guard let id = track.id else { continue }
            // 文件真不存在：本次跳过（不计入云端跳过数），下次启动再试。
            guard FileManager.default.fileExists(atPath: track.path) else { continue }
            // 云端未下载：不读内容（会阻塞），计入跳过数，下次重试。
            guard isLocallyAvailable(URL(fileURLWithPath: track.path)) else {
                skippedCloudOnly += 1
                continue
            }
            guard let hash = Self.contentHashIfFilePresent(
                atPath: track.path,
                isLocallyAvailable: isLocallyAvailable
            ) else { continue }
            pending.append(PendingFill(id: id, hash: hash))
        }
        guard !pending.isEmpty else {
            return ContentHashBackfillOutcome(
                filledHashes: [],
                skippedCloudOnly: skippedCloudOnly,
                candidateCount: candidates.count
            )
        }

        // Phase 3: 短写事务批量落库。
        try write { db in
            for fill in pending {
                try db.execute(
                    sql: "UPDATE track SET content_hash = ? WHERE id = ?",
                    arguments: [fill.hash, fill.id]
                )
            }
        }
        print("✅ Database: Backfilled content_hash for \(pending.count) track(s)")
        return ContentHashBackfillOutcome(
            filledHashes: pending.map(\.hash),
            skippedCloudOnly: skippedCloudOnly,
            candidateCount: candidates.count
        )
    }

    // MARK: - 身份缺失普查（诊断，只读）

    /// 身份缺失普查（**只读**：绝不删除/修改任何行，孤儿行清理由 maintainer 单独执行）。
    /// 供启动时打印汇总与测试直调。
    func identityCensus() throws -> IdentityCensus {
        try read { db in try Self.identityCensus(db) }
    }

    /// 事务内版本（纯读；调用方须自行保证所在事务不接受写操作）。
    static func identityCensus(_ db: Database) throws -> IdentityCensus {
        func count(_ sql: String) throws -> Int {
            try Int.fetchOne(db, sql: sql) ?? 0
        }
        return IdentityCensus(
            nullHash: try count(
                "SELECT COUNT(*) FROM track WHERE content_hash IS NULL OR content_hash = ''"
            ),
            danglingHistory: try count("""
            SELECT COUNT(*) FROM play_history h
            WHERE NOT EXISTS (SELECT 1 FROM track t WHERE t.stable_id = h.track_stable_id)
            """),
            danglingFavorite: try count("""
            SELECT COUNT(*) FROM favorite f
            WHERE NOT EXISTS (SELECT 1 FROM track t WHERE t.stable_id = f.track_stable_id)
            """),
            danglingItem: try count("""
            SELECT COUNT(*) FROM playlist_item i
            WHERE NOT EXISTS (SELECT 1 FROM track t WHERE t.stable_id = i.track_stable_id)
            """)
        )
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

// MARK: - 旧库迁移完成门（审计 2026-09-12 D1）

/// `migrateDatabaseIfNeeded` 的两步全表迁移（同路径去重 + filename→path stableId）
/// 的完成门 —— **唯一决策点**。
///
/// 语义：只有两步都成功才允许上锁。此前只要进入过迁移块就置位，任一步失败
/// （例如 stable_id 更新撞 `idx_track_stable_id` 中断循环）都会被永久固化，
/// 之后不再重试 → 半迁移状态：部分行停在旧 filename id，其 favorite /
/// playlist_item / play_history 与后续新入库的 path id 分叉。
///
/// 键提到 v3：v2 时代可能已被失败路径误置位的库因此重跑一次
/// （两步迁移均幂等，重跑只多一次启动成本）。
enum LegacyTrackMigrationGate {
    static let completionKey = "database.legacyTrackMigrationsCompleted.v3"

    /// 完成门判定（纯函数，可单测）。
    static func shouldMarkCompleted(pathDedupSucceeded: Bool, stableIdMigrationSucceeded: Bool) -> Bool {
        pathDedupSucceeded && stableIdMigrationSucceeded
    }

    static func isCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completionKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
    }
}

// MARK: - content_hash 回填运行标记（替代已退役的一次性完成门）

/// content_hash 回填的**运行标记**（非完成门）：只记录「上次跑过的时间」，
/// **不参与跳过判定** —— 回填每次启动都跑（零 NULL 行时只是一次索引查询）。
///
/// 为何退役一次性门：该门一旦置位，NULL 指纹永不重试；而指纹缺失的成因不止
/// 「存量老库」（还有入库时文件尚未就绪、云端未下载等），这些行即使文件一直在
/// 本地也永远拿不到身份键 → 跨端同步永久把对端 stableId 落成孤儿行。省下的却是
/// 可忽略的一次索引查询。故改为「每次都试 + 只跳过读不了的文件」。
/// 保留标记键仅为诊断（排查「回填上次何时跑、跑没跑」）。
/// 旧 key `database.contentHashBackfillCompleted.v1` 已退役，启动时由
/// `removeRetiredCompletionGate` 清理，避免历史遗留的 true 误导排查。
enum ContentHashBackfillMarker {
    /// 上次回填时间（Unix 秒；0/缺失 = 本机从未跑过）。
    static let lastRunKey = "database.contentHashBackfillLastRun.v1"
    /// 已退役的一次性完成门（仅用于启动清理，任何路径都不得再回读它做判定）。
    static let retiredCompletionKey = "database.contentHashBackfillCompleted.v1"

    static func lastRunDate(defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.double(forKey: lastRunKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    static func markRun(defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: lastRunKey)
    }

    /// 清理旧一次性门。
    /// - Returns: 是否真的清了（旧库升级后第一次启动为 true，仅打印用）。
    @discardableResult
    static func removeRetiredCompletionGate(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: retiredCompletionKey) != nil else { return false }
        defaults.removeObject(forKey: retiredCompletionKey)
        return true
    }
}

// MARK: - content_hash 回填结果

/// 一次 content_hash 回填的结果。
struct ContentHashBackfillOutcome: Equatable, Sendable {
    /// 本次新填入的 content_hash（顺序 = 扫描顺序）。启动路径据此重放挂起变更。
    let filledHashes: [String]
    /// 因 iCloud 云端未下载跳过的曲目数（下次启动重试，不置任何永久门）。
    let skippedCloudOnly: Int
    /// 本次扫到的 NULL 指纹候选行数（诊断用；0 = 零 NULL 行，只花了一次索引查询）。
    let candidateCount: Int
}

// MARK: - 身份缺失普查

/// 身份缺失普查结果（只读诊断）：身份键缺口的三个面。
struct IdentityCensus: Equatable, Sendable {
    /// ① track.content_hash 为 NULL/空 的行数。
    var nullHash: Int
    /// ② play_history.track_stable_id 在 track 表找不到的行数（孤儿）。
    var danglingHistory: Int
    /// ③ favorite.track_stable_id 悬空行数。
    var danglingFavorite: Int
    /// ③ playlist_item.track_stable_id 悬空行数。
    var danglingItem: Int

    var summaryLine: String {
        "🔎 Identity census: nullHash=\(nullHash) danglingHistory=\(danglingHistory) "
            + "danglingFavorite=\(danglingFavorite) danglingItem=\(danglingItem)"
    }
}
