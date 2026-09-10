//
//  SyncDataSyncModels.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）播放数据 LWW 同步模型：outbox 变更日志 / per-peer
//  游标 / 线载荷模型。纯声明层（Codable + GRDB Record），无 IO 无业务逻辑；
//  存储与对账逻辑见 SyncChangeLogStore.swift + SyncLWWReconcile.swift。
//
//  语义（docs/lan-sync-design.md §6.2，v1 简化）：
//  - 每端一张变更日志表 sync_outbox：所有被同步实体（收藏/播放历史/歌单结构/
//    播放位置上下文）的本地写入点先落 outbox，再异步同步给 peer。
//  - LWW 键 = (entity, row_key)；同键冲突用 updated_at(毫秒) 大者胜。
//  - row_key 使用本地 stableId 或业务行唯一键（v1）；跨端 content_hash 映射
//    已收口（M4-2a：载荷 contentHash 字段承载跨端身份，收发两侧双向映射，本地
//    缺歌时挂起至歌曲到位重放，见 SyncChangeLogMapping / SyncChangeLogPendingStore）。
//
//  新增表对齐 DatabaseManager.createTables（幂等 IF NOT EXISTS，旧库启动自动
//  补表，同 sync_device 模式）；模型 struct 独立于此文件，不动 DatabaseModels.swift
//  （并行线 M3-1 正在改 Track 模型）。
//

import Foundation
@preconcurrency import GRDB

// MARK: - 被同步实体

/// outbox 记录的实体类型（sync_outbox.entity 列）。
enum SyncChangeEntity: String, Codable, CaseIterable, Sendable {
    case favorite
    case playHistory = "play_history"
    case playlist
    case playlistItem = "playlist_item"
    case playbackPosition = "playback_position"

    // v1 参与同步的实体清单（设置白名单 v1 不做，待产品定后接入）。
    // swiftlint:disable:next todo
    // TODO: 设置白名单同步（M4-2，产品定白名单字段后实现）
    static let v1Synced: [SyncChangeEntity] = [.favorite, .playHistory, .playlist, .playlistItem]
}

/// outbox 操作类型（sync_outbox.op 列）。
enum SyncChangeOp: String, Codable, Sendable {
    case upsert
    case delete
}

// MARK: - 变更日志行（sync_outbox）

/// sync_outbox 一行：本地一次业务写入的变更记录。
/// payload_json 存该行完整数据快照（JSON 字符串），对端 LWW 胜出后可直接应用。
struct SyncChangeLogRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var id: Int64?
    var entity: String
    var rowKey: String
    var op: String
    var updatedAtMs: Int64
    var payloadJSON: String?

    static let databaseTableName = "sync_outbox"

    enum CodingKeys: String, CodingKey {
        case id, entity
        case rowKey = "row_key"
        case op
        case updatedAtMs = "updated_at"
        case payloadJSON = "payload_json"
    }

    init(
        id: Int64? = nil,
        entity: SyncChangeEntity,
        rowKey: String,
        op: SyncChangeOp,
        updatedAtMs: Int64,
        payloadJSON: String? = nil
    ) {
        self.id = id
        self.entity = entity.rawValue
        self.rowKey = rowKey
        self.op = op.rawValue
        self.updatedAtMs = updatedAtMs
        self.payloadJSON = payloadJSON
    }

    var entityValue: SyncChangeEntity? { SyncChangeEntity(rawValue: entity) }
    var opValue: SyncChangeOp? { SyncChangeOp(rawValue: op) }
}

// MARK: - per-peer 游标（sync_cursor）

/// sync_cursor 一行：某 peer 已消费到的本端 outbox 最大 id。
/// 拉取 = peer 带自己游标来取增量；推送到对端后推进对端游标。
struct SyncPeerCursor: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var peerID: String
    var lastOutboxID: Int64

    static let databaseTableName = "sync_cursor"

    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case lastOutboxID = "last_outbox_id"
    }
}

// MARK: - 线载荷（changeLogPull / changeLogPush）

/// changeLogPull 请求：对端带自己已消费的本端 outbox id（cursor）来拉增量。
/// 应答 = changeLogPush（服务端取 id > cursor 的批）。
struct SyncChangeLogPullRequest: Codable, Equatable, Sendable {
    /// 请求方已消费到的**本端** outbox 最大 id（0 = 全量拉）。
    var cursor: Int64
}

/// changeLogPush 载荷：一批 outbox 行 + 该批末尾 id（供对端推进游标）。
/// 本端主动推送（推自己 > peer 游标 的增量）与 pull 应答共用同一帧。
struct SyncChangeLogPushPayload: Codable, Equatable, Sendable {
    /// 线上行（含服务端自增 id，对端用它推进游标）。
    var entries: [SyncChangeLogWireEntry]
    /// 本批末尾的本端 outbox id（= 对端应记下的游标）。
    var lastOutboxID: Int64
}

/// 线上 outbox 行（changeLogPush 的 entry）。
/// contentHash：跨端歌曲引用键（M4-2a 已收口：发送侧填本地 track 指纹，接收侧
/// 映射回本地 stableId，缺歌挂起重放，见 SyncChangeLogMapping）。
struct SyncChangeLogWireEntry: Codable, Equatable, Sendable {
    var id: Int64
    var entity: String
    var rowKey: String
    var op: String
    var updatedAtMs: Int64
    var contentHash: String?
    var payloadJSON: String?
}
