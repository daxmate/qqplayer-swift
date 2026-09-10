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
//
//  线程：应用走 DatabaseManager.write（同步）；调用方负责串行（会话层锁外）。
//

import Foundation
@preconcurrency import GRDB

struct SyncChangeLogApplier {
    /// internal（M4-2a）：会话层用它构造跨端映射器/挂起存储（同一库连接）。
    let database: DatabaseManager

    /// playback_position 落点（v1 可选注入；nil = 丢弃并打印调试日志）。
    /// 生产接线（写 UserDefaults QQPlayerState / 未来 DB 行）留 M4-2。
    var playbackPositionSink: ((SyncPlaybackPositionSnapshot) -> Void)?

    init(database: DatabaseManager) {
        self.database = database
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

    // MARK: favorite

    /// row_key = track_stable_id。落 upsert 收藏行（replace 幂等）。
    private func applyFavorite(rowKey: String) throws -> Bool {
        try database.write { db in
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
    private func applyPlaylist(payloadJSON: String?) throws -> Bool {
        return try database.write { db in
            let snapshot = try SyncSnapshotCodec.decode(SyncPlaylistSnapshot.self, from: payloadJSON)
            if let existing = try Playlist.filter(Column("slug") == snapshot.slug).fetchOne(db) {
                var updated = existing
                updated.title = snapshot.title
                updated.updatedAt = snapshot.updatedAt
                updated.lastPlayedAt = snapshot.lastPlayedAt
                updated.customCoverImagePath = snapshot.customCoverImagePath
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
                    customCoverImagePath: snapshot.customCoverImagePath
                ).insert(db)
            }
            return true
        }
    }

    // MARK: playlist_item

    /// 落远端歌单项快照：按 slug 找本地歌单（未同步到则跳过，结构收敛由 playlist
    /// upsert 先行保证）；存在则更新 position，不存在则插入。
    private func applyPlaylistItem(payloadJSON: String?) throws -> Bool {
        let snapshot = try SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON)
        return try database.write { db in
            guard let playlist = try Playlist.filter(Column("slug") == snapshot.playlistSlug).fetchOne(db),
                  let playlistId = playlist.id else {
                return false // 歌单未同步到本地，结构收敛由 playlist upsert 先行保证
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
    private func applyPlaybackPosition(payloadJSON: String?) throws -> Bool {
        let snapshot = try SyncSnapshotCodec.decode(SyncPlaybackPositionSnapshot.self, from: payloadJSON)
        if let playbackPositionSink {
            playbackPositionSink(snapshot)
        } else {
            print("ℹ️ SyncChangeLogApplier: playback_position 落点未接（M4-2 定本地存储），丢弃 \(snapshot.trackStableId)")
        }
        return true
    }
}
