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
    /// 跨文件共享：`DatabaseManager+Migration.swift` 事务内写入、本文件 setup 后消费
    /// （文件侧引用迁移，见下）。
    var pendingStableIdFileRemapping: [String: String] = [:]

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
        AppLog.info(.db, "✅ Database: stableId 相对化迁移 \(remapping.count) 首（sync_outbox 改写 \(outboxRows) 行，跳过占用 \(skippedOccupied)）")
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
                dbDiagStats()
                AppLog.info(.db, "✅ Database initialized successfully on attempt \(attempt)")
                return
            } catch {
                lastError = error
                dbDiag("⚠️ setup failed attempt \(attempt)/\(maxRetries) error=\(error)")
                AppLog.warn(.db, "⚠️ Database setup failed on attempt \(attempt)/\(maxRetries): \(error)")

                if attempt < maxRetries {
                    // Wait before retrying
                    Thread.sleep(forTimeInterval: Double(retryDelay) / 1_000_000_000.0)
                }
            }
        }

        // If all retries failed, try to recover
        if let error = lastError {
            AppLog.error(.db, "❌ Database setup failed after \(maxRetries) attempts. Attempting recovery...")
            attemptDatabaseRecovery(error: error)
        }
    }

    /// 把 content_hash 回填丢到专用后台串行队列（启动路径**不阻塞主线程**）。
    /// 失败只打印不抛：回填幂等，下次启动自动重试。
    /// 回填跑完后再打一行身份缺失普查（只读统计）——放在回填之后，报的是补齐后的余量。
    /// 供 `DatabaseManager+ContentHash.swift` 入口调用（跨文件需 internal；本体留在
    /// 本文件是因为它要用上面的专用队列与防重入状态）。
    func scheduleContentHashBackfillInBackground() {
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
                AppLog.warn(.db, "⚠️ Database: content_hash backfill failed (will retry next launch): \(error)")
            }
            manager.logIdentityCensus()
        }
    }

    /// 身份缺失普查汇总一行（只读诊断；失败只打印，绝不影响启动）。
    private func logIdentityCensus() {
        do {
            // `try` 不能进 `AppLog.*` 的非 throwing autoclosure（编译期报错），先求值再传。
            let census = try identityCensus()
            AppLog.info(.db, census.summaryLine)
        } catch {
            AppLog.warn(.db, "⚠️ Database: identity census failed (diagnostic only): \(error)")
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
            AppLog.info(.db, "✅ Database: stableId 迁移文件侧引用（书签 \(report.bookmarksRenamed) / 歌词 \(report.lyricsFilesRenamed) / 封面 \(report.artworkKeysRenamed)）")
            pendingStableIdFileRemapping = [:]
        }
        try migrateDatabaseIfNeeded()

        // M3-1: content_hash 存量惰性回填已**移出启动主线程**——dataless（云端未下载）
        // iCloud 文件的 FileHandle.read 会触发云端下载并长时间阻塞（实测 20+ 分钟
        // 不返回）→ 主线程卡死、App 无响应。改为专用串行队列后台执行（见
        // scheduleContentHashBackfillInBackground）。
        scheduleContentHashBackfillInBackground()

        // 存量字形归一（库内简繁归一）：名字全部写规范形（简体），并按归一名合并
        // 同形歌手行。**必须排在下面两条之前** —— 归名后 #81 的分组键
        // （albumMatchKey）才能看见简繁分裂的同名专辑。（2026-09-18 用户拍板：
        // 落库全部是简体中文 + 存量数据同意一次迁移）
        do {
            try migrateCanonicalizeScriptForms()
        } catch {
            AppLog.warn(.db, "⚠️ Script canonicalization migration failed (non-fatal): \(error)")
        }
        // Split combined multi-artist rows ("A; B") left by the old parser
        // (issue #16), then heal libraries where deleted tracks left empty
        // artists/albums behind (issue #74). Both are idempotent and cheap,
        // and run every launch.
        do {
            try migrateSplitCombinedArtistNames()
        } catch {
            AppLog.warn(.db, "⚠️ Combined artist split migration failed (non-fatal): \(error)")
        }
        // After artists are split, merge albums that the old per-track-artist
        // keying broke apart (issue #81)
        do {
            try migrateMergeSplitAlbums()
        } catch {
            AppLog.warn(.db, "⚠️ Split album merge migration failed (non-fatal): \(error)")
        }
        do {
            try cleanupOrphanedLibraryEntries()
        } catch {
            AppLog.warn(.db, "⚠️ Orphaned library cleanup failed (non-fatal): \(error)")
        }
    }

    private func attemptDatabaseRecovery(error: Error) {
        dbDiag("🔧 recovery start originalError=\(error)")
        AppLog.info(.db, "🔧 Attempting database recovery...")

        do {
            let databaseURL = try getDatabaseURL()
            let backupURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("qqplayer_backup_\(Int(Date().timeIntervalSince1970)).db")

            // Try to backup the corrupted database
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                try? FileManager.default.moveItem(at: databaseURL, to: backupURL)
                AppLog.info(.db, "📦 Backed up corrupted database to: \(backupURL.path)")
            }

            // Try to create a fresh database
            try setupDatabase()
            dbDiagStats()
            dbDiag("✅ recovery OK (fresh database created)")
            AppLog.info(.db, "✅ Database recovery successful - created fresh database")
        } catch {
            // The database file is corrupted beyond repair. Fall back to an
            // in-memory database so the app keeps running (degraded, empty
            // library) instead of force-exiting at launch. Migrations are
            // intentionally skipped: an in-memory database has no old data.
            dbDiag("⚠️ recovery failed → in-memory fallback reason=\(error)")
            AppLog.error(.db, "❌ Database recovery failed: \(error)")
            AppLog.warn(.db, "⚠️ Database corrupted, running with in-memory fallback")
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
            AppLog.info(.db, "✅ In-memory database created successfully (degraded mode: library starts empty)")
        } catch {
            // Absolute last resort - keep the app alive instead of crashing.
            dbDiag("❌ in-memory creation failed error=\(error)")
            AppLog.error(.db, "❌ Failed to create in-memory fallback database: \(error)")
            AppLog.warn(.db, "⚠️ Continuing without a usable database (degraded mode)")
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

    /// 打开后记录：**App 实际使用的 App Group 容器路径与根目录条目** + 库内关键计数。
    /// 为什么需要：devicectl 列出的 group 容器可能不是 App 实际用的那个（实测两者不一致），
    /// 只有 App 自己报出的路径与内容才可信。
    private func dbDiagStats() {
        #if os(iOS)
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios") {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: container.path))?
                    .sorted().joined(separator: ",") ?? "?"
                dbDiag("📁 groupContainer=\(container.path) entries=[\(entries)]")
            } else {
                dbDiag("📁 groupContainer=nil（退回 Documents 或降级）")
            }
            guard let writer = dbWriter else {
                dbDiag("📊 stats skipped（dbWriter=nil = 降级）")
                return
            }
            do {
                let stats = try writer.read { db -> String in
                    func count(_ table: String) -> Int {
                        (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")) ?? -1
                    }
                    return "track=\(count("track")) play_history=\(count("play_history")) "
                        + "favorite=\(count("favorite")) playlist=\(count("playlist")) "
                        + "playlist_item=\(count("playlist_item")) outbox=\(count("sync_outbox")) "
                        + "pending=\(count("sync_pending_change"))"
                }
                dbDiag("📊 \(stats)")
            } catch {
                dbDiag("📊 stats failed error=\(error)")
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
