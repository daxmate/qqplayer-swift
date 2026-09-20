//
//  DatabaseManager+Schema.swift
//  QQPlayer
//
//  生产 schema 建表 + 老库补列（genre / content_hash，幂等）。
//
//  2026-09-19 从 DatabaseManager.swift 原样搬出（纯搬家）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    /// Creates the full production schema. Internal so tests can build an
    /// in-memory database via the `init(dbWriter:)` seam.
    func createTables() throws {
        try write { db in
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
                AppLog.info(.db, "✅ Database: Added last_played_at column to playlist table")
            } catch {
                // Column may already exist, which is fine
                AppLog.info(.db, "ℹ️ Database migration: last_played_at column already exists or migration failed: \(error)")
            }

            // Migration: Add preset_type column to eq_preset if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE eq_preset ADD COLUMN preset_type TEXT DEFAULT 'imported'
                """)
                AppLog.info(.db, "✅ Database: Added preset_type column to eq_preset table")
            } catch {
                // Column may already exist, which is fine
                AppLog.info(.db, "ℹ️ Database migration: preset_type column already exists or migration failed: \(error)")
            }
        }
    }

    /// 老库 track 表补 genre 列（E1-S3）。幂等：列已存在直接跳过。
    /// 独立成 internal：生产迁移（migrateDatabaseIfNeeded）与测试
    /// （GenreParsingTests 老 schema → 补列 → 往返）共用同一实现，避免两处漂移。
    static func addTrackGenreColumnIfNeeded(_ db: Database) throws {
        if try !db.columns(in: "track").contains(where: { $0.name == "genre" }) {
            try db.execute(sql: "ALTER TABLE track ADD COLUMN genre TEXT")
            AppLog.info(.db, "✅ Database: Added genre column to track table")
        } else {
            AppLog.info(.db, "ℹ️ Database migration: genre column already exists")
        }
    }

    /// 老库 track 表补 content_hash 列（M3-1，跨端同步对账键 = 文件内容 SHA-256）。
    /// 幂等：列已存在直接跳过。
    /// 独立成 internal：生产迁移（migrateDatabaseIfNeeded）与测试
    /// （TrackContentHashTests 老 schema → 补列 → 往返）共用同一实现，避免两处漂移。
    static func addTrackContentHashColumnIfNeeded(_ db: Database) throws {
        if try !db.columns(in: "track").contains(where: { $0.name == "content_hash" }) {
            try db.execute(sql: "ALTER TABLE track ADD COLUMN content_hash TEXT")
            AppLog.info(.db, "✅ Database: Added content_hash column to track table")
        } else {
            AppLog.info(.db, "ℹ️ Database migration: content_hash column already exists")
        }
    }
}
