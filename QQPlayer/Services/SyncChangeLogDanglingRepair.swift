//
//  SyncChangeLogDanglingRepair.swift
//  QQPlayer
//
//  局域网同步（S2, T15b）**出站悬空引用对账修复**：本端 `sync_outbox` 里引用的
//  `stable_id` 在本端 `track` 表查无此歌的行——按 `played_at` 对账改写（可修复）/
//  清理（不可修复），并把业务表现有的收藏 / 歌单成员 / 播放历史补进 outbox
//  （`reconcileLocalTruth`）。
//
//  2026-09-21 从 Sync/SyncChangeLogMapping.swift 原样搬出（纯搬家，无逻辑变更）。
//  落点说明：放 `Services/` 而非 `Sync/` —— `SyncCoverValueContract` 以 `QQPlayer/Sync`
//  为生产扫描根、封面白名单只 4 个路径，而本片含一处本端封面路径透传（原 845 行）
//  ⇒ 只有离开 `Sync/` 才不触发「新的跨端封面消费点」。
//
import Foundation
@preconcurrency import GRDB

// MARK: - T15b 出站悬空引用对账修复

/// 本端 `sync_outbox` **出站悬空引用**的对账修复入口。
///
/// 事故：本端 outbox 里的行引用的 `stable_id` 在本端 `track` 表查无此歌——容器路径
/// 变化后旧 stableId 失效，业务表被 `TrackIdentityMigration` 迁移过、**outbox 没有**。
/// 每轮同步这些行都拿不到 `contentHash` → 对端全部判「未定位」跳过
/// （`SyncEntryLocalization.unresolved`），一次都落不了库：白跑一批 + 面板永远橙。
///
/// 三态处理（**只动 `sync_outbox`**，绝不删/改任何业务行）：
/// - `play_history`：按 **`played_at` 对账**（本地 `play_history` 表里找「同 `played_at`
///   且 `track_stable_id` 在 track 表存在」的行）→ 命中就把 row_key 与 payload 的歌曲
///   引用改写为**当前** stableId（复用 `SyncChangeLogMapper.rewrite`，与接收侧本地化
///   同一变换）。这条路径能救回历史播放。
/// - `favorite` / `playlist_item`（没有可靠对账键）与对不上账的 play_history →
///   **不可修复**，从 `sync_outbox` 清理（否则每轮同步白跑、面板永远橙）。
/// - 引用键解析不出的行 → 计数跳过（判断不了，宁可不碰）。
///
/// 幂等 + 可重入：整趟在**一个写事务**内完成（中途崩溃不留半成品）；跑第二遍零改动。
/// 为什么清理而不是留着重试：这些行的引用键永久失效（重拉重推都拿不到指纹），
/// 留着只消耗每轮批次数与面板噪音；业务表里的同名孤儿由用户决定，不在本入口范围。
struct SyncChangeLogDanglingRepair {
    /// 计数（修复 / 清理 / 跳过 / 补发）。
    struct Report: Equatable, Sendable {
        /// 悬空引用被**改写**为当前可用 stableId 的行数（play_history 按 played_at 命中）。
        var repaired = 0
        /// 悬空引用**无法修复**、已从 `sync_outbox` 清理的行数。
        var cleaned = 0
        /// 悬空引用但本次**未动**的行数（引用键解析不出 → 无法判断，宁可不碰）。
        var skipped = 0
        /// 本地真值**补发**进 outbox 的行数（业务表有、outbox 没有对应 upsert）。
        var emitted = 0
        /// 补发时本地拿不到身份键的行数（track 行在、`content_hash` 空 = 缺指纹）：
        /// 行照样补发（它是本地真值），对端会按「未定位」披露。
        var emittedWithoutIdentity = 0
        /// 本地业务行引用的歌在 `track` 表查无（本地悬空）→ **不补发**、只计数。
        var skippedLocalDangling = 0

        var didChange: Bool { repaired > 0 || cleaned > 0 || emitted > 0 }

        /// 一行诊断文案（Mac / iOS 两个调用点共用，避免两份文案漂移）。
        var logText: String {
            "（修复=\(repaired) 清理=\(cleaned) 跳过=\(skipped)"
                + " 补发=\(emitted) 缺指纹=\(emittedWithoutIdentity)"
                + " 本地悬空=\(skippedLocalDangling)）"
        }
    }

    /// 参与修复的实体：引用歌曲、且对端靠稳定身份键定位的那几类。
    /// （`playlist` 不引用歌曲；`playback_position` 的本地载体不是 DB 行，都不在范围。）
    /// **派生自唯一声明处 `SyncEntityRegistry`**（见 `repairsDanglingReferences`）。
    static var repairableEntities: [SyncChangeEntity] { SyncEntityRegistry.danglingRepairableEntities }

    let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    @discardableResult
    func run() throws -> Report {
        try database.write { db in try Self.run(db) }
    }

    /// 事务内版本（测试可直接在内存库事务里调用）：**先修悬空引用，再补发本地真值**。
    /// 两步顺序有讲究——先清/改掉废行，补发阶段再判「outbox 里有没有这一条」，
    /// 否则刚被清掉的键会被误判成「已存在」。两步都在同一写事务内，幂等可重入。
    @discardableResult
    static func run(_ db: Database) throws -> Report {
        var report = try repairDanglingRows(db)
        let reconcile = try reconcileLocalTruth(db)
        report.emitted = reconcile.emitted
        report.emittedWithoutIdentity = reconcile.emittedWithoutIdentity
        report.skippedLocalDangling = reconcile.skippedLocalDangling
        return report
    }

    /// 第一步：出站**悬空引用**修复（只动 `sync_outbox`）。
    @discardableResult
    static func repairDanglingRows(_ db: Database) throws -> Report {
        var report = Report()
        let entityValues = repairableEntities.map(\.rawValue)
        let rows = try SyncChangeLogRow
            .filter(entityValues.contains(Column("entity")))
            .order(Column("id"))
            .fetchAll(db)
        for row in rows {
            guard let entity = row.entityValue, repairableEntities.contains(entity) else { continue }
            // 引用键解析不出（如 playlist_item 的 row_key 形态不符且 payload 缺失）→
            // 判断不了是否悬空，宁可不碰。
            guard let stableId = SyncTrackReference.trackStableId(
                entity: entity,
                rowKey: row.rowKey,
                payloadJSON: row.payloadJSON
            ), !stableId.isEmpty else {
                report.skipped += 1
                continue
            }
            // 引用在 track 表里有行（哪怕指纹为空 = 缺指纹，归 T13/T14）→ 不是悬空，不动。
            guard try isDangling(db, stableId: stableId) else { continue }

            if entity == .playHistory, let currentStableId = try currentPlayHistoryTrackStableId(db, row: row) {
                let rewritten = SyncChangeLogMapper.rewrite(row, entity: .playHistory, localStableId: currentStableId)
                guard rewritten != row else {
                    // 改写后逐字没变（理论不可达：旧键无 track 行、新键有）→ 当不可修复处理，
                    // 避免「计数说修了、实际没变」的假账。
                    try row.delete(db)
                    report.cleaned += 1
                    continue
                }
                try rewritten.update(db)
                report.repaired += 1
            } else {
                try row.delete(db)
                report.cleaned += 1
            }
        }
        return report
    }

    // MARK: - 判定

    /// 该 stableId 是否**悬空**（本端 track 表查无此歌）。
    /// 复用发送侧同一事实源：`.noTrackRow` = 悬空；`.emptyContentHash`（有行、指纹未回填）
    /// 只是「缺指纹」，不在本入口范围（T13/T14 口径）。
    private static func isDangling(_ db: Database, stableId: String) throws -> Bool {
        if case .noTrackRow = try SyncContentHashResolver.trackIdentity(db, forTrackStableId: stableId) {
            return true
        }
        return false
    }

    /// 按 `played_at` 对账：本地 `play_history` 表里「同 played_at 且 track_stable_id 在
    /// track 表存在」的首行（id 升序 → 同一输入确定性）→ 当前 stableId；对不上 = nil。
    ///
    /// 为什么 played_at 能当对账键：播放历史是**事件**，容器路径变化后 stableId 会重新
    /// 派生（TrackIdentityMigration），但事件的发生时间不变 → 用它把旧引用接回当前曲目。
    private static func currentPlayHistoryTrackStableId(_ db: Database, row: SyncChangeLogRow) throws -> String? {
        var playedAt = SyncChangeLogApplier.parseCompositeRowKey(row.rowKey)?.1
        if playedAt == nil {
            playedAt = (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: row.payloadJSON))?.playedAt
        }
        guard let playedAt else { return nil }
        let candidates = try String.fetchAll(
            db,
            sql: "SELECT track_stable_id FROM play_history WHERE played_at = ? ORDER BY id",
            arguments: [playedAt]
        )
        for candidate in candidates where !candidate.isEmpty {
            if try !isDangling(db, stableId: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 第二步：本地真值 → outbox 对账补发（T15b-2，2026-09-14）

    /// 参与补发的实体：本地载体是 DB 行的那几类。
    /// （`playlist` 结构行**不引用歌曲**，补发时不做身份判定；`playback_position`
    /// 本地载体不是 DB 行，不在范围。）
    /// **派生自唯一声明处 `SyncEntityRegistry`**（见 `reconcilesLocalTruth`）。
    static var reconcilableEntities: [SyncChangeEntity] { SyncEntityRegistry.reconcilableEntities }

    /// 把本端业务表里**现有**的真值，补进 `sync_outbox`（缺对应 upsert 行时才补）。
    ///
    /// 为什么需要它（2026-09-14 真机事故）：收藏 / 歌单成员 / 播放历史的 outbox 行可能
    /// **根本不存在**——① 在 outbox 机制建立之前产生的业务行；② 引用失效后被
    /// `repairDanglingRows` 清理掉的行（favorite / playlist_item 没有可靠对账键，只能清）。
    /// 两种情况下业务行都还在（用户看得见），同步层却永远看不到它 ⇒ 收藏「从来没同步过」
    /// 且零报错（面板不报、日志不报）。补发把本地现状重新变成一条可发送的变更。
    ///
    /// 判定口径（与发送侧同一事实源、与写入侧同一行键形态）：
    /// - 已有同实体同键的 `upsert` 行 → 不动。**delete 行不算**：v2 删除不上线、只做
    ///   批次抑制，所以「有 delete」不等于「这个事实已经进过 outbox」。
    /// - 引用歌在 `track` 表查无（本地悬空）→ **不补发**、计数 `skippedLocalDangling`
    ///   （补了也拿不到身份键，只会给对端添「未定位」噪音）。
    /// - 引用歌在表里但 `content_hash` 空（缺指纹）→ 照发，计数 `emittedWithoutIdentity`
    ///   （对端面板按「未定位」披露，不静默）。
    /// - `playlist` 是**结构行、不引用歌曲**：没有 track 身份键可判，跳过身份判定直
    ///   接补发，补发计数只计 `emitted`（不碰 `emittedWithoutIdentity` /
    ///   `skippedLocalDangling`）；folder-synced 歌单由本地扫描派生，与写入侧同一
    ///   口径不补。
    static func reconcileLocalTruth(_ db: Database) throws -> Report {
        var report = Report()
        var existing: [String: Set<String>] = [:]
        for entity in reconcilableEntities {
            let keys = try String.fetchAll(
                db,
                sql: "SELECT row_key FROM sync_outbox WHERE entity = ? AND op = ?",
                arguments: [entity.rawValue, SyncChangeOp.upsert.rawValue]
            )
            existing[entity.rawValue] = Set(keys)
        }
        var seen = Set<String>()

        /// 各实体的统一收口：去重 → 「已有 upsert 就跳过」→ 身份判定 → 补发 + 计数。
        /// 收在一处，避免每个分支各写一份判定而漂移。
        /// `requiresTrackIdentity = false`：不引用歌曲的结构实体（`playlist`）——没有
        /// 身份键可判，跳过身份判定，补发计数只计 `emitted`。
        func emit(
            entity: SyncChangeEntity,
            stableId: String,
            payloadJSON: String,
            requiresTrackIdentity: Bool = true
        ) throws {
            guard let key = Self.rowKey(entity: entity, stableId: stableId, payloadJSON: payloadJSON),
                  !key.isEmpty else { return }
            let dedupe = "\(entity.rawValue)|\(key)"
            guard seen.insert(dedupe).inserted else { return }
            guard existing[entity.rawValue]?.contains(key) != true else { return }
            var missingIdentity = false
            if requiresTrackIdentity {
                let identity = try SyncContentHashResolver.trackIdentity(db, forTrackStableId: stableId)
                if case .noTrackRow = identity {
                    report.skippedLocalDangling += 1
                    return
                }
                if case .emptyContentHash = identity { missingIdentity = true }
            }
            try SyncChangeLogStore.record(
                db,
                entity: entity,
                rowKey: key,
                op: .upsert,
                payloadJSON: payloadJSON
            )
            report.emitted += 1
            if missingIdentity { report.emittedWithoutIdentity += 1 }
        }

        // 歌单结构（row_key = slug）。**不引用歌曲** → 不做身份判定（见 emit 的
        // `requiresTrackIdentity`），载荷与写入侧 `createPlaylist` 逐字同形。
        // folder-synced 歌单内容由本地扫描派生（folder_path 是设备本地路径），
        // 不入跨端同步——与写入侧同一口径。
        let playlists = try Playlist
            .filter(Column("is_folder_synced") == false)
            .order(Column("slug"))
            .fetchAll(db)
        for playlist in playlists where !playlist.slug.isEmpty {
            let snapshot = SyncPlaylistSnapshot(
                slug: playlist.slug,
                title: playlist.title,
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt,
                lastPlayedAt: playlist.lastPlayedAt,
                folderPath: playlist.folderPath,
                isFolderSynced: playlist.isFolderSynced,
                lastFolderSync: playlist.lastFolderSync,
                customCoverImagePath: playlist.customCoverImagePath
            )
            try emit(
                entity: .playlist,
                stableId: playlist.slug,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot),
                requiresTrackIdentity: false
            )
        }

        // 收藏（row_key = track_stable_id）
        let favoriteIds = try String.fetchAll(
            db,
            sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id"
        )
        for stableId in favoriteIds where !stableId.isEmpty {
            let snapshot = SyncFavoriteSnapshot(trackStableId: stableId)
            try emit(
                entity: .favorite,
                stableId: stableId,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
        }

        // 歌单成员（row_key = slug|track_stable_id）。folder-synced 歌单内容由本地扫描
        // 派生（folder_path 是设备本地路径），不入跨端同步——与写入侧同一口径。
        let items = try Row.fetchAll(db, sql: """
        SELECT p.slug AS slug, pi.position AS position, pi.track_stable_id AS stable_id
        FROM playlist_item pi
        JOIN playlist p ON p.id = pi.playlist_id
        WHERE p.is_folder_synced = 0
        ORDER BY p.slug, pi.position
        """)
        for item in items {
            let slug: String = item["slug"]
            let stableId: String = item["stable_id"]
            let position: Int = item["position"]
            guard !slug.isEmpty, !stableId.isEmpty else { continue }
            let snapshot = SyncPlaylistItemSnapshot(
                playlistSlug: slug,
                position: position,
                trackStableId: stableId
            )
            try emit(
                entity: .playlistItem,
                stableId: stableId,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
        }

        // 播放历史（row_key = stableId|played_at）
        let history = try Row.fetchAll(db, sql: """
        SELECT track_stable_id AS stable_id, played_at AS played_at, play_duration_ms AS duration
        FROM play_history ORDER BY id
        """)
        for entry in history {
            let stableId: String = entry["stable_id"]
            guard !stableId.isEmpty else { continue }
            let playedAt: Int64 = entry["played_at"]
            let duration: Int64 = (entry["duration"] as Int64?) ?? 0
            let snapshot = SyncPlayHistorySnapshot(
                trackStableId: stableId,
                playedAt: playedAt,
                playDurationMs: duration
            )
            try emit(
                entity: .playHistory,
                stableId: stableId,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
        }
        return report
    }

    /// 补发行键：与写入侧 `SyncChangeLogStore.record` 的形态逐字对齐
    /// （favorite = stableId；play_history = stableId|playedAt；playlist = slug；
    /// playlist_item = slug|stableId）。从 payload 快照派生，避免每个分支各拼一次字符串。
    private static func rowKey(entity: SyncChangeEntity, stableId: String, payloadJSON: String) -> String? {
        switch entity {
        case .favorite:
            return SyncFavoriteSnapshot(trackStableId: stableId).rowKey
        case .playHistory:
            guard let snapshot = try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON) else {
                return nil
            }
            return snapshot.rowKey
        case .playlistItem:
            guard let snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON) else {
                return nil
            }
            return snapshot.rowKey
        case .playlist:
            guard let snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistSnapshot.self, from: payloadJSON) else {
                return nil
            }
            return snapshot.rowKey
        case .playbackPosition:
            return nil
        }
    }
}
