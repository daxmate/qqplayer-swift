//
//  SyncChangeLogApplier.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）LWW 胜出条目的本地应用：把 SyncLWWReconcile 判定的
//  "应应用的远端行"逐条落到本地业务表（只落 upsert 快照）。
//
//  ⚠️ v2 语义修订（2026-09-10 用户拍板，docs/lan-sync-design.md §6.2 / §12b-7）：
//  **不再有删除传播**——本地删除只在本地生效，远端 delete 一律忽略。
//  本文件是应用层的最后一道兜底：applyOne 按 SyncChangeLogDeletionPolicy 直接丢弃
//  delete 行，**绝不删本地业务行**（正常情况下 delete 已在 SyncChangeLogPeer
//  handlePush 的 localize 之前被拦掉；见该文件）。
//
//  ⚠️ 身份兜底（2026-09-14 身份缺口包）：引用歌曲的实体（favorite / play_history /
//  playlist_item）落库前先查本地 `track` 表**行是否存在**，不存在 → 跳过（返回 false）
//  + 一行诊断。理由：最近播放 / 常听排行是 `JOIN track ON t.stable_id = h.track_stable_id`
//  （见 SmartPlaylistStore），引用不存在歌曲的业务行**永远不可见**——先前的
//  passThrough 透传路径会拿对端 stableId 写出这类孤儿行，界面毫无变化而面板显示
//  「应用 N 条」。任何路径（含挂起重放 SyncChangeLogReplay）都不该写出它。
//
//  各实体应用语义（与捕获侧 SyncDataSnapshots 对称；v2 起只应用 upsert）：
//  - favorite：row_key = track_stable_id。upsert = INSERT OR REPLACE。
//  - play_history：row_key = "\(trackStableId)|\(playedAt)"。upsert = 本地按
//    (track_stable_id, played_at) 匹配：存在则更新 play_duration_ms（快照值，
//    LWW 已判远端胜，直接覆盖），不存在则 INSERT（行 id 本地自增）。
//    注意：远端快照不含跨端歌曲键，M4-2a 起由 SyncChangeLogMapper 在应用前改写为
//    本地 stableId（本地缺歌则挂起，见 SyncChangeLogMapping.swift）。
//  - playlist：row_key = slug。upsert = 按 slug 查本地，存在则更新标题/封面等
//    字段（保留本地 id 与 FK 完整性），不存在则 INSERT（自增 id）；folder-synced
//    远端歌单（本地扫描派生语义）直接按快照应用，由对端捕获侧已跳过产生。
//  - playlist_item：row_key = "\(playlistSlug)|\(trackStableId)"。upsert =
//    按 slug 找本地 playlist id，存在则按 (playlist_id, track_stable_id) 匹配：
//    存在更新 position，不存在 INSERT；本地无此 slug（歌单未同步到）则跳过
//    （结构收敛由 playlist upsert 先行保证）。
//  - playback_position：本地载体 = UserDefaults QQPlayerState（非 DB 行）。
//    v1 不落库：通过 playbackPositionSink 注入回调（测试用内存捕获）；生产
//    接线（写 UserDefaults QQPlayerState / 未来 DB 行）留 M4-2 定本地载体。
//    entity 枚举/行模型/LWW/协议层已支持，payload 见 SyncPlaybackPositionSnapshot。
//    ⚠️ 跨端续播开关（2026-09-14）：`playbackPositionSyncEnabled` 关（默认）/ 开但
//    sink 未接时，该行**不落任何本地位置**——因此**不算「已应用」**（不返回 true），
//    只触发 `onPlaybackPositionUnsupported`（面板据此披露「未支持」）。
//    修复 INV-20：先前 sink == nil 时 print「丢弃」却 return true
//    ⇒ 面板报「已应用 N」而本地零变化。
//
//  线程：应用走 DatabaseManager.write（同步）；调用方负责串行（会话层锁外）。
//

import Foundation
@preconcurrency import GRDB

struct SyncChangeLogApplier {
    /// internal（M4-2a）：会话层用它构造跨端映射器/挂起存储（同一库连接）。
    let database: DatabaseManager

    /// playback_position 落点（nil = 无落点实现）。**返回 true 仅当这条真的落到了本地位置**
    /// ——静态丢弃（不同曲 / 远端更旧 / 位置差过小）一律 false，账目按「未支持」披露。
    var playbackPositionSink: ((SyncPlaybackPositionSnapshot) -> Bool)?

    /// 跨端续播开关（关 = 本端不接受 playback_position）。
    /// 注入 nil = 读真实设置（`DeleteSettings.syncPlaybackPositionEnabled`，默认关）；
    /// 测试注入明确的 true/false，不依赖真实 UserDefaults。
    let playbackPositionSyncEnabled: Bool

    /// 一条 playback_position 行**没有落到任何本地位置**时逐条触发。
    /// 两种成因合并成一个回调（面板口径都是「这条没应用」，本步不区分）：
    /// ① 开关关（默认，本端不接受）；② 开关开但落点未接（sink 由下一版本接入）。
    /// 调用方（SyncChangeLogPeer）据此计数 → 账目 → 面板披露。
    var onPlaybackPositionUnsupported: (() -> Void)?

    /// 一行引用**父行/被引用行不存在**而被跳过时逐条触发（2026-09-15，矩阵三级 #8）。
    /// 三种成因（都返回 false、都不落库）：
    /// - `playlist_item` 的歌单结构还没落本地（父行不存在）；
    /// - 收藏 / 播放历史 / 歌单项引用的歌在本地 `track` 表查无。
    /// 以前这三种**只打印**、既不计失败也不计数 ⇒ 面板看不到“到底丢了多少”。
    var onSkippedMissingParent: (() -> Void)?

    init(database: DatabaseManager, playbackPositionSyncEnabled: Bool? = nil) {
        self.database = database
        self.playbackPositionSyncEnabled = playbackPositionSyncEnabled
            ?? DeleteSettings.load().syncPlaybackPositionEnabled
    }

    /// 应用一批远端胜出行（顺序无关；每行独立事务，单行失败不影响其余行）。
    /// 返回成功应用的行数。调用方（SyncChangeLogPeer）负责把 lastOutboxID
    /// 记为对端游标。
    @discardableResult
    func apply(_ rows: [SyncChangeLogRow]) throws -> Int {
        var applied = 0
        for row in rows where try applyOne(row) {
            applied += 1
        }
        return applied
    }

    /// 应用单行；返回 false = 无可应用对象（幂等跳过，不算失败）。
    /// payload 只为 upsert 快照所需；delete 行统一在入口丢弃（见下）。
    private func applyOne(_ row: SyncChangeLogRow) throws -> Bool {
        guard let entity = row.entityValue, row.opValue != nil else { return false }
        // v2（§12b-7）：删除不跨端传播——应用层兜底，delete 行一律忽略（返回 false，
        // 不算应用、不删本地行）。正常路径上 SyncChangeLogPeer 已在 localize 前拦掉。
        if SyncChangeLogDeletionPolicy.shouldIgnore(op: row.op) { return false }
        switch entity {
        case .favorite:
            return try applyFavorite(rowKey: row.rowKey)
        case .playHistory:
            return try applyPlayHistory(payloadJSON: row.payloadJSON)
        case .playlist:
            return try applyPlaylist(payloadJSON: row.payloadJSON)
        case .playlistItem:
            return try applyPlaylistItem(payloadJSON: row.payloadJSON)
        case .playbackPosition:
            return try applyPlaybackPosition(payloadJSON: row.payloadJSON)
        }
    }

    // MARK: 身份兜底（引用歌曲的实体：本地必须有该 track 行）

    /// 本地 `track` 表是否存在该 stable_id 的行。
    /// 引用歌曲的业务行（收藏 / 播放历史 / 歌单项）只有能 JOIN 上 track 才在界面可见
    /// （最近播放 / 常听排行都走 JOIN），所以不存在该行时一律不写。
    private static func trackRowExists(_ db: Database, stableId: String) throws -> Bool {
        guard !stableId.isEmpty else { return false }
        return try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM track WHERE stable_id = ? LIMIT 1",
            arguments: [stableId]
        ) != nil
    }

    /// 一行诊断（隐私：只打实体/键，不打曲目内容）。
    private static func logOrphanSkip(entity: SyncChangeEntity, stableId: String) {
        print("⚠️ SyncChangeLogApplier: 跳过引用不存在歌曲的 \(entity.rawValue) 行（本地无 stable_id=\(stableId) 的 track）")
    }

    // MARK: favorite

    /// row_key = track_stable_id。本地必须有该歌（否则该收藏永不进入列表）→
    /// 落 upsert 收藏行（replace 幂等）。
    private func applyFavorite(rowKey: String) throws -> Bool {
        try database.write { db in
            guard try Self.trackRowExists(db, stableId: rowKey) else {
                Self.logOrphanSkip(entity: .favorite, stableId: rowKey)
                onSkippedMissingParent?()
                return false
            }
            try Favorite(trackStableId: rowKey).insert(db, onConflict: .replace)
            return true
        }
    }

    // MARK: play_history

    /// 落远端播放历史快照：按 (track_stable_id, played_at) 匹配本地行，存在则更新时长
    /// （LWW 已判远端胜，直接覆盖），不存在则插入。
    private func applyPlayHistory(payloadJSON: String?) throws -> Bool {
        return try database.write { db in
            let snapshot = try SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON)
            guard try Self.trackRowExists(db, stableId: snapshot.trackStableId) else {
                Self.logOrphanSkip(entity: .playHistory, stableId: snapshot.trackStableId)
                onSkippedMissingParent?()
                return false
            }
            let existing = try PlayHistoryEntry
                .filter(Column("track_stable_id") == snapshot.trackStableId
                    && Column("played_at") == snapshot.playedAt)
                .fetchOne(db)
            if var existing {
                existing.playDurationMs = snapshot.playDurationMs
                try existing.update(db)
            } else {
                try PlayHistoryEntry(
                    trackStableId: snapshot.trackStableId,
                    playedAt: snapshot.playedAt,
                    playDurationMs: snapshot.playDurationMs
                ).insert(db)
            }
            return true
        }
    }

    // MARK: playlist

    /// 落远端歌单快照：按 slug 查本地，存在则更新字段（保留本地 id 与 FK 完整性），
    /// 不存在则插入（自增 id）。
    ///
    /// ⚠️ INV-23（2026-09-15）：`customCoverImagePath` **不跳端引用**——载荷里带的是
    /// 发送端的**设备本地相对路径**，在本端必然解析不到（面板会静默回落默认封面，谁也看不见）。
    /// 所以：更新既有歌单时**保留本端自己的封面**；新建时封面为空。
    /// 跳端封面若要真支持，必须另做按 `content_hash` 寻址的文件通道（matrix H 段，未做）。
    private func applyPlaylist(payloadJSON: String?) throws -> Bool {
        return try database.write { db in
            let snapshot = try SyncSnapshotCodec.decode(SyncPlaylistSnapshot.self, from: payloadJSON)
            if let existing = try Playlist.filter(Column("slug") == snapshot.slug).fetchOne(db) {
                var updated = existing
                updated.title = snapshot.title
                updated.updatedAt = snapshot.updatedAt
                updated.lastPlayedAt = snapshot.lastPlayedAt
                // 封面：保持本端值（不写对端设备路径，见上方 INV-23）
                try updated.update(db)
            } else {
                try Playlist(
                    id: nil,
                    slug: snapshot.slug,
                    title: snapshot.title,
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt,
                    lastPlayedAt: snapshot.lastPlayedAt,
                    folderPath: snapshot.folderPath,
                    isFolderSynced: snapshot.isFolderSynced,
                    lastFolderSync: snapshot.lastFolderSync,
                    customCoverImagePath: nil
                ).insert(db)
            }
            return true
        }
    }

    // MARK: playlist_item

    /// 落远端歌单项快照：按 slug 找本地歌单（未同步到则跳过，结构收敛由 playlist
    /// upsert 先行保证）；本地无该歌（item 引用的 track 行不存在）也跳过——歌单项
    /// 只有能 JOIN 上 track 才可见，否则是永远不可见的孤儿行。存在则更新 position，
    /// 不存在则插入。
    private func applyPlaylistItem(payloadJSON: String?) throws -> Bool {
        let snapshot = try SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON)
        return try database.write { db in
            guard let playlist = try Playlist.filter(Column("slug") == snapshot.playlistSlug).fetchOne(db),
                  let playlistId = playlist.id else {
                // 歌单结构还没到本地（父行不存在）：不落库、**计数**（矩阵三级 #8：静默失败必须可见）
                onSkippedMissingParent?()
                return false
            }
            guard try Self.trackRowExists(db, stableId: snapshot.trackStableId) else {
                Self.logOrphanSkip(entity: .playlistItem, stableId: snapshot.trackStableId)
                onSkippedMissingParent?()
                return false
            }
            let itemExists = try PlaylistItem
                .filter(Column("playlist_id") == playlistId
                    && Column("track_stable_id") == snapshot.trackStableId)
                .fetchOne(db) != nil
            if itemExists {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId
                        && Column("track_stable_id") == snapshot.trackStableId)
                    .updateAll(db, Column("position").set(to: snapshot.position))
                return true
            }
            try PlaylistItem(
                playlistId: playlistId,
                position: snapshot.position,
                trackStableId: snapshot.trackStableId
            ).insert(db)
            return true
        }
    }

    // MARK: playback_position（v1 不落库）

    /// 解析复合 row_key "\(左侧标识)|\(右侧整数)"（play_history 用：右段 = playedAt
    /// 毫秒时间戳）。从右往左找最后一个 "|"：标识本身可含 "|"，右段整数不可能是
    /// 错误切分点——取最后一个分隔符最稳。
    static func parseCompositeRowKey(_ rowKey: String) -> (String, Int64)? {
        guard let sep = rowKey.lastIndex(of: "|") else { return nil }
        let left = String(rowKey[..<sep])
        let right = String(rowKey[rowKey.index(after: sep)...])
        guard let number = Int64(right) else { return nil }
        return (left, number)
    }

    /// 按最后一个 "|" 切分为两段字符串（playlist_item 用：row_key =
    /// "\(playlistSlug)|\(trackStableId)"，两侧都是字符串）。
    static func splitRowKey(_ rowKey: String) -> (String, String)? {
        guard let sep = rowKey.lastIndex(of: "|") else { return nil }
        let left = String(rowKey[..<sep])
        let right = String(rowKey[rowKey.index(after: sep)...])
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    /// v2：delete 已在 applyOne 入口丢弃（删除不传播），这里只处理 upsert。
    ///
    /// 返回 true **仅当**这一条真的落到了本地位置（调用了 sink）——「已应用」= 真的落库，
    /// 静默丢弃一律返回 false（INV-20）。两种未落地情形：
    /// - 开关关（默认）：本端不接受播放位置，不调 sink；
    /// - 开关开但 sink 未接（落点实现由下一版本接入）：同样不调 sink。
    /// 两者都触发 `onPlaybackPositionUnsupported`（本步在账目/面板上不区分）。
    private func applyPlaybackPosition(payloadJSON: String?) throws -> Bool {
        let snapshot = try SyncSnapshotCodec.decode(SyncPlaybackPositionSnapshot.self, from: payloadJSON)
        guard playbackPositionSyncEnabled else {
            print("ℹ️ SyncChangeLogApplier: 跨端续播已关闭，不接受播放位置，跳过 \(snapshot.trackStableId)")
            onPlaybackPositionUnsupported?()
            return false
        }
        guard let playbackPositionSink else {
            print("ℹ️ SyncChangeLogApplier: 跨端续播已开启但落点未接，跳过 \(snapshot.trackStableId)")
            onPlaybackPositionUnsupported?()
            return false
        }
        guard playbackPositionSink(snapshot) else {
            // 落点存在但**未接受**（不同曲 / 远端更旧 / 位置差过小）：仍然没落地，
            // 不能计「已应用」（INV-20 的口径对这两条路一视同仁）。
            print("ℹ️ SyncChangeLogApplier: 跨端续播落点未接受这条位置，跳过 \(snapshot.trackStableId)")
            onPlaybackPositionUnsupported?()
            return false
        }
        return true
    }
}
