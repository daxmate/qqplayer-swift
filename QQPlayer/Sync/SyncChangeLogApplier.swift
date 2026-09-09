//
//  SyncChangeLogApplier.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）LWW 胜出条目的本地应用：把 SyncLWWReconcile 判定的
//  "应应用的远端行"逐条落到本地业务表（upsert 快照 / op=delete 删本地行）。
//
//  各实体应用语义（与捕获侧 SyncDataSnapshots 对称）：
//  - favorite：row_key = track_stable_id。upsert = INSERT OR REPLACE；
//    delete = DELETE。
//  - play_history：row_key = "\(trackStableId)|\(playedAt)"。upsert = 本地按
//    (track_stable_id, played_at) 匹配：存在则更新 play_duration_ms（快照值，
//    LWW 已判远端胜，直接覆盖），不存在则 INSERT（行 id 本地自增）；
//    delete = DELETE 匹配行。注意：远端快照不含跨端歌曲键（content_hash 映射
//    M4-2 收口），v1 用本地 stableId 兜底，见 SyncLWWReconcile 文件头。
//  - playlist：row_key = slug。upsert = 按 slug 查本地，存在则更新标题/封面等
//    字段（保留本地 id 与 FK 完整性），不存在则 INSERT（自增 id）；folder-synced
//    远端歌单（本地扫描派生语义）直接按快照应用，由对端捕获侧已跳过产生。
//    delete = DELETE 按 slug 找到本地行删（playlist_item 经 FK CASCADE 一并删）。
//  - playlist_item：row_key = "\(playlistSlug)|\(trackStableId)"。upsert =
//    按 slug 找本地 playlist id，存在则按 (playlist_id, track_stable_id) 匹配：
//    存在更新 position，不存在 INSERT；本地无此 slug（歌单未同步到）则跳过
//    （结构收敛由 playlist upsert 先行保证）。delete = 匹配行删除。
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
    private let database: DatabaseManager

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
    /// delete 语义统一走 row_key（捕获侧 row_key 即跨端行标识，与 favorite 一致）；
    /// payload 只为 upsert 快照所需——delete 无 payload（或 payload 丢失）不抛错。
    private func applyOne(_ row: SyncChangeLogRow) throws -> Bool {
        guard let entity = row.entityValue, let op = row.opValue else { return false }
        switch entity {
        case .favorite:
            return try applyFavorite(op: op, rowKey: row.rowKey)
        case .playHistory:
            return try applyPlayHistory(op: op, rowKey: row.rowKey, payloadJSON: row.payloadJSON)
        case .playlist:
            return try applyPlaylist(op: op, rowKey: row.rowKey, payloadJSON: row.payloadJSON)
        case .playlistItem:
            return try applyPlaylistItem(op: op, rowKey: row.rowKey, payloadJSON: row.payloadJSON)
        case .playbackPosition:
            return try applyPlaybackPosition(op: op, payloadJSON: row.payloadJSON)
        }
    }

    // MARK: favorite

    private func applyFavorite(op: SyncChangeOp, rowKey: String) throws -> Bool {
        try database.write { db in
            switch op {
            case .upsert:
                try Favorite(trackStableId: rowKey).insert(db, onConflict: .replace)
                return true
            case .delete:
                let deleted = try Favorite.filter(Column("track_stable_id") == rowKey).deleteAll(db)
                return deleted > 0
            }
        }
    }

    // MARK: play_history

    private func applyPlayHistory(op: SyncChangeOp, rowKey: String, payloadJSON: String?) throws -> Bool {
        return try database.write { db in
            switch op {
            case .upsert:
                // upsert 需要快照（时长值来自远端）。
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
            case .delete:
                // delete 走 row_key（"\(trackStableId)|\(playedAt)"），无需 payload。
                guard let (stableId, playedAt) = Self.parseCompositeRowKey(rowKey) else { return false }
                let deleted = try PlayHistoryEntry
                    .filter(Column("track_stable_id") == stableId
                        && Column("played_at") == playedAt)
                    .deleteAll(db)
                return deleted > 0
            }
        }
    }

    // MARK: playlist

    private func applyPlaylist(op: SyncChangeOp, rowKey: String, payloadJSON: String?) throws -> Bool {
        return try database.write { db in
            switch op {
            case .upsert:
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
            case .delete:
                // delete 走 row_key（= slug），无需 payload。
                let deleted = try Playlist.filter(Column("slug") == rowKey).deleteAll(db)
                return deleted > 0
            }
        }
    }

    // MARK: playlist_item

    private func applyPlaylistItem(op: SyncChangeOp, rowKey: String, payloadJSON: String?) throws -> Bool {
        // upsert 需要快照（playlistSlug/position/trackStableId）；
        // delete 走 row_key（"\(playlistSlug)|\(trackStableId)"），无需 payload。
        let upsertSnapshot: SyncPlaylistItemSnapshot?
        if op == .upsert {
            upsertSnapshot = try SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON)
        } else {
            upsertSnapshot = nil
        }
        let playlistSlug: String
        let trackStableId: String
        if let upsertSnapshot {
            playlistSlug = upsertSnapshot.playlistSlug
            trackStableId = upsertSnapshot.trackStableId
        } else if let parsed = Self.splitRowKey(rowKey) {
            playlistSlug = parsed.0
            trackStableId = parsed.1
        } else {
            return false
        }
        return try database.write { db in
            guard let playlist = try Playlist.filter(Column("slug") == playlistSlug).fetchOne(db),
                  let playlistId = playlist.id else {
                return false // 歌单未同步到本地，结构收敛由 playlist upsert 先行保证
            }
            switch op {
            case .upsert:
                guard let upsertSnapshot else { return false }
                let itemExists = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId
                        && Column("track_stable_id") == upsertSnapshot.trackStableId)
                    .fetchOne(db) != nil
                if itemExists {
                    _ = try PlaylistItem
                        .filter(Column("playlist_id") == playlistId
                            && Column("track_stable_id") == upsertSnapshot.trackStableId)
                        .updateAll(db, Column("position").set(to: upsertSnapshot.position))
                    return true
                }
                try PlaylistItem(
                    playlistId: playlistId,
                    position: upsertSnapshot.position,
                    trackStableId: upsertSnapshot.trackStableId
                ).insert(db)
                return true
            case .delete:
                let deleted = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId
                        && Column("track_stable_id") == trackStableId)
                    .deleteAll(db)
                return deleted > 0
            }
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

    private func applyPlaybackPosition(op: SyncChangeOp, payloadJSON: String?) throws -> Bool {
        // delete 无对象可删（非 DB 行），幂等视为已应用。
        guard op == .upsert else { return true }
        let snapshot = try SyncSnapshotCodec.decode(SyncPlaybackPositionSnapshot.self, from: payloadJSON)
        if let playbackPositionSink {
            playbackPositionSink(snapshot)
        } else {
            print("ℹ️ SyncChangeLogApplier: playback_position 落点未接（M4-2 定本地存储），丢弃 \(snapshot.trackStableId)")
        }
        return true
    }
}
