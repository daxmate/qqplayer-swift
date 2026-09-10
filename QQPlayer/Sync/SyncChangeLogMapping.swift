//
//  SyncChangeLogMapping.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2a）跨端歌曲引用映射收口：本地 stable_id ↔ content_hash
//  双向解析 + 线上 entry 的本地化改写。
//
//  语义（docs/lan-sync-design.md §6.2："跨端同步载荷引用 content_hash，同步层
//  做双向映射"）：
//  - 发送侧（SyncChangeLogPeer.handlePull）：outbox 行 → wire entry 时按行内歌曲
//    引用（row_key / payload 的 track_stable_id）查 track 表取 content_hash 填入
//    wire entry.contentHash；该行不引用歌曲（歌单）/ 引用歌不在本端 / 指纹为空
//    → contentHash = nil。wire 的 row_key 与 payload 仍是**发送端本地 stableId**
//    （v1 线上格式与 M4-1 一致，老 peer 可平滑互通），接收端靠 contentHash 本地化。
//  - 接收侧：contentHash → 本地 stableId（查 track by content_hash）。命中则把
//    row_key 与 payload 内的歌曲引用改写成本地 stableId 再进 LWW 对账——LWW 键 =
//    (entity, row_key)，同一个收藏/播放历史在两端 stableId 不同，不先本地化就
//    对不上键（各记一条、永不收敛）。本地还没有这首歌 → 挂起（见
//    SyncChangeLogPendingStore.swift），歌到位后重放，不丢数据。
//  - 降级：contentHash 为 nil（对端是 M4-1 老版本，或该行无歌曲引用）→ 不做映射，
//    按 M4-1 原样透传应用，保证与老 peer 互通。
//
//  本文件只做只读查询 + 纯变换，无写副作用；挂起/重放见
//  SyncChangeLogPendingStore.swift。
//

import Foundation
@preconcurrency import GRDB

// MARK: - 双向解析

/// 本地 stable_id ↔ content_hash 双向解析（只读查询）。
struct SyncContentHashResolver {
    let database: DatabaseManager

    /// 本地 stableId → content_hash（无此歌 / 指纹未回填 = nil）。
    func contentHash(forTrackStableId stableId: String) throws -> String? {
        try database.read { db in
            try Self.contentHash(db, forTrackStableId: stableId)
        }
    }

    /// 事务内版本（发送侧一批行共用一个读事务时用）。
    static func contentHash(_ db: Database, forTrackStableId stableId: String) throws -> String? {
        guard !stableId.isEmpty else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT content_hash FROM track WHERE stable_id = ? LIMIT 1",
            arguments: [stableId]
        )
    }

    /// content_hash → 本地 stableId（无此歌 = nil）。
    /// 同 hash 多行（理论上不该有，重复路径审计后仍可能残留）取 id 最小 = 最早入库，
    /// 保证同一输入在两端都得到确定性结果。
    func trackStableId(forContentHash contentHash: String) throws -> String? {
        try database.read { db in
            try Self.trackStableId(db, forContentHash: contentHash)
        }
    }

    static func trackStableId(_ db: Database, forContentHash contentHash: String) throws -> String? {
        guard !contentHash.isEmpty else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT stable_id FROM track WHERE content_hash = ? ORDER BY id LIMIT 1",
            arguments: [contentHash]
        )
    }
}

// MARK: - 歌词同步映射的生产实现（M4-2b）

/// aligned 歌词随歌同步的 content_hash 映射：复用本文件上面的
/// `SyncContentHashResolver`（M4-2a），不新写 SQL。
extension SyncLyricsContentMapping {
    /// 生产实现：本地 stableId ↔ 歌曲 content_hash（查不到 / 指纹未回填 = nil，
    /// 与 M4-2a 同一语义）。
    static func live(database: DatabaseManager) -> SyncLyricsContentMapping {
        let resolver = SyncContentHashResolver(database: database)
        return SyncLyricsContentMapping(
            contentHashForStableId: { stableId in
                (try? resolver.contentHash(forTrackStableId: stableId)) ?? nil
            },
            stableIdForContentHash: { contentHash in
                (try? resolver.trackStableId(forContentHash: contentHash)) ?? nil
            }
        )
    }
}

// MARK: - 行内歌曲引用提取

/// 从被同步实体行里提取"它引用的歌曲本地 stableId"；不引用歌曲的实体（歌单）返回 nil。
enum SyncTrackReference {
    /// 该实体是否引用歌曲（playlist 只是结构，不含歌曲键）。
    static func referencesTrack(_ entity: SyncChangeEntity) -> Bool {
        entity != .playlist
    }

    /// 行内歌曲引用：优先取 row_key（跨端行键即承载引用），row_key 形态不符时回落
    /// 读 payload 快照。两者都取不到 = nil（该行没有可用歌曲键）。
    static func trackStableId(entity: SyncChangeEntity, rowKey: String, payloadJSON: String?) -> String? {
        switch entity {
        case .favorite, .playbackPosition:
            return rowKey.isEmpty ? nil : rowKey
        case .playHistory:
            // row_key = "\(trackStableId)|\(playedAt)"
            if let parsed = SyncChangeLogApplier.parseCompositeRowKey(rowKey) { return parsed.0 }
            return (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON))?.trackStableId
        case .playlistItem:
            // row_key = "\(playlistSlug)|\(trackStableId)"
            if let parsed = SyncChangeLogApplier.splitRowKey(rowKey) { return parsed.1 }
            return (try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON))?.trackStableId
        case .playlist:
            return nil
        }
    }
}

// MARK: - 本地化结果

/// 接收侧一条线上 entry 的本地化结果。
enum SyncEntryLocalization: Equatable {
    /// 命中 content_hash 映射：row_key 与 payload 歌曲引用已改写为**本地 stableId**。
    case mapped(SyncChangeLogRow)
    /// 无需映射：该行不引用歌曲（歌单），或 entry.contentHash 为空（降级 = M4-1 原样）。
    case passThrough(SyncChangeLogRow)
    /// 本地还没有这首歌（content_hash 映射不到本地 stableId）→ 挂起，歌到后重放。
    case suspended(contentHash: String, remoteRow: SyncChangeLogRow)

    /// 本地化后的行（挂起分支 = 未改写的远端行，供挂起存储使用）。
    var row: SyncChangeLogRow {
        switch self {
        case .mapped(let row), .passThrough(let row), .suspended(_, let row):
            return row
        }
    }
}

// MARK: - 收发两侧的映射变换

/// changeLog 帧的跨端映射变换（发送侧填 contentHash / 接收侧本地化）。
struct SyncChangeLogMapper {
    let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var resolver: SyncContentHashResolver { SyncContentHashResolver(database: database) }

    // MARK: 发送侧

    /// outbox 行批 → wire entry 批（逐行按歌曲引用查 track 取 content_hash）。
    /// 一个读事务内完成，避免逐行开关事务。
    func wireEntries(_ rows: [SyncChangeLogRow]) throws -> [SyncChangeLogWireEntry] {
        try database.read { db in
            try rows.map { row in
                var contentHash: String?
                if let entity = row.entityValue,
                   let trackStableId = SyncTrackReference.trackStableId(
                       entity: entity,
                       rowKey: row.rowKey,
                       payloadJSON: row.payloadJSON
                   ) {
                    contentHash = try SyncContentHashResolver.contentHash(db, forTrackStableId: trackStableId)
                }
                return Self.wireEntry(row, contentHash: contentHash)
            }
        }
    }

    /// 纯变换（无 IO；发送侧与测试共用）。
    static func wireEntry(_ row: SyncChangeLogRow, contentHash: String?) -> SyncChangeLogWireEntry {
        SyncChangeLogWireEntry(
            id: row.id ?? 0,
            entity: row.entity,
            rowKey: row.rowKey,
            op: row.op,
            updatedAtMs: row.updatedAtMs,
            contentHash: contentHash,
            payloadJSON: row.payloadJSON
        )
    }

    // MARK: 接收侧

    /// 线上 entry → 本地化结果（见 SyncEntryLocalization）。
    func localize(_ entry: SyncChangeLogWireEntry) throws -> SyncEntryLocalization {
        let remoteRow = Self.remoteRow(entry)
        guard let entity = SyncChangeEntity(rawValue: entry.entity) else {
            return .passThrough(remoteRow) // 未知实体：交对账/应用层按未知忽略
        }
        // 不引用歌曲（歌单）或没有跨端歌曲键（老 peer / 指纹缺失）→ 降级透传
        guard SyncTrackReference.referencesTrack(entity),
              let contentHash = entry.contentHash, !contentHash.isEmpty else {
            return .passThrough(remoteRow)
        }
        guard let localStableId = try resolver.trackStableId(forContentHash: contentHash) else {
            return .suspended(contentHash: contentHash, remoteRow: remoteRow)
        }
        return .mapped(Self.rewrite(remoteRow, entity: entity, localStableId: localStableId))
    }

    /// wire entry → 远端 outbox 行（保留远端 id：merge 排序键 (updated_at, id) 需要它）。
    static func remoteRow(_ entry: SyncChangeLogWireEntry) -> SyncChangeLogRow {
        SyncChangeLogRow(
            id: entry.id > 0 ? entry.id : nil,
            entity: SyncChangeEntity(rawValue: entry.entity) ?? .favorite,
            rowKey: entry.rowKey,
            op: SyncChangeOp(rawValue: entry.op) ?? .upsert,
            updatedAtMs: entry.updatedAtMs,
            payloadJSON: entry.payloadJSON
        )
    }

    // MARK: 本地化改写（row_key + payload 歌曲引用 → 本地 stableId）

    /// 把远端行的歌曲引用改写成本地 stableId。playlist 不改（无歌曲键）。
    /// 复合 row_key 的构造段（playedAt / playlistSlug）优先取 row_key，取不到时回落
    /// payload 快照；两者都取不到则只改写 payload 能改的部分（row_key 保持远端值，
    /// 应用层会因解析不出本地键而幂等跳过）。
    static func rewrite(
        _ row: SyncChangeLogRow,
        entity: SyncChangeEntity,
        localStableId: String
    ) -> SyncChangeLogRow {
        var rewritten = row
        switch entity {
        case .favorite:
            rewritten.rowKey = localStableId
            rewritten.payloadJSON = rewriteFavoritePayload(row.payloadJSON, localStableId)
        case .playHistory:
            let playedAt = SyncChangeLogApplier.parseCompositeRowKey(row.rowKey)?.1
                ?? (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: row.payloadJSON))?.playedAt
            guard let playedAt else { break }
            rewritten.rowKey = "\(localStableId)|\(playedAt)"
            rewritten.payloadJSON = rewritePlayHistoryPayload(row.payloadJSON, localStableId)
        case .playlistItem:
            let slug = SyncChangeLogApplier.splitRowKey(row.rowKey)?.0
                ?? (try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: row.payloadJSON))?.playlistSlug
            guard let slug else { break }
            rewritten.rowKey = "\(slug)|\(localStableId)"
            rewritten.payloadJSON = rewritePlaylistItemPayload(row.payloadJSON, localStableId)
        case .playbackPosition:
            rewritten.rowKey = localStableId
            rewritten.payloadJSON = rewritePlaybackPositionPayload(row.payloadJSON, localStableId)
        case .playlist:
            break
        }
        return rewritten
    }

    /// 以下 rewrite* 均：payload 存在且能解码 → 改歌曲引用后重编码；payload 为 nil
    /// （delete 行）或解码失败 → 原值返回（应用层已有对应错误处理，不在此吞掉语义）。
    private static func rewriteFavoritePayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncFavoriteSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlayHistoryPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlaylistItemPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlaybackPositionPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlaybackPositionSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }
}
