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

// MARK: - per-peer 推送游标（sync_push_cursor）

/// sync_push_cursor 一行：**本端已推给某 peer 的本端 outbox 位置**（推送游标）。
///
/// ⚠️ 与 `SyncPeerCursor`（sync_cursor）**方向相反，绝不可复用同一张表**：
/// - `SyncPeerCursor` = 本端**已消费的对端** outbox 位置（拉取游标）：
///   `SyncChangeLogPeer.handlePush` 写入、`sendPull` 读取。
/// - `SyncPeerPushCursor` = 本端**已推给对端**的本端 outbox 位置（推送游标）：
///   `SyncChangeLogPeer.sendIncrement` 写入并读取（增量推送的起点）。
///
/// 两表键同为 peer_id 却指向两条完全不同的变更流，合表 = 推/拉互相把对方的
/// 位置当自己的起点（重复推或漏推）。
struct SyncPeerPushCursor: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var peerID: String
    var lastOutboxID: Int64

    static let databaseTableName = "sync_push_cursor"

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

// MARK: - 连接后自动跑一次「同步数据」（2026-09-15 用户拍板：触发时机 = 连接后自动）

/// 自动触发的纯判定（可单测；调用方只负责把四个事实递进来）。
///
/// 为什么要把「什么时候自动跑」收成纯函数：跨端同步原本只在用户点「同步数据」时才跑
/// （矩阵三级空格：「点过的设备同步了、没点的没有」）；自动触发的条件一旦散在会话回调里，
/// 就会变成“有时跑有时不跑”。
enum SyncDataAutoRunDecision {
    /// 已连接 + 有会话 + 没有一轮在跑 + 本次连接还没自动跑过 → 才自动跑。
    /// 一次连接只自动一次：重连（断后重连）会由调用方清标记，再跑一次。
    static func shouldStart(
        isConnected: Bool,
        hasActiveSession: Bool,
        isBusy: Bool,
        didAutoRunForCurrentConnection: Bool
    ) -> Bool {
        guard isConnected, hasActiveSession, !isBusy, !didAutoRunForCurrentConnection else { return false }
        return true
    }
}

/// 「同步数据」在飞门：**手动（面板按钮）与自动（连接就绪）共用一个门**。
///
/// 为什么必须有：同一会话上两个协调器并发 = 同一 outbox 两个推送者
/// （游标/账目双写、批次互相越过）。取不到门 = 直接放弃本轮，**不排队**
/// （排队会积压出“点了没反应、过一会儿才跑”的怪行为）。
/// `@MainActor` 隔离：调用点都在主线程（面板按钮 / 会话回调）。
@MainActor
final class SyncDataRunGate {
    static let shared = SyncDataRunGate()
    private var isBusy = false

    private init() {}

    /// 取门；已被占用 = false。
    func acquire() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    func release() {
        isBusy = false
    }

    /// 当前是否有一轮在跑（诊断/测试读）。
    var isHeld: Bool { isBusy }

    /// 测试用：清掉（避免用例之间相互影响）。
    func resetForTesting() {
        isBusy = false
    }
}
