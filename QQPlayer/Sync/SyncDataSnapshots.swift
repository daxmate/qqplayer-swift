//
//  SyncDataSnapshots.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）outbox payload 快照模型：各被同步实体业务行的
//  完整数据快照（JSON 编码后存 sync_outbox.payload_json）。对端 LWW 胜出时
//  直接用快照重建本地行（upsert）或按 row_key 删除（delete）。
//
//  快照字段与 DatabaseModels.swift 的 GRDB 模型对齐，但**独立于此文件声明**
//  （并行线 M3-1 正在改 DatabaseModels.swift / Track，此文件不依赖它，避免
//  合入冲突；播放历史/收藏/歌单模型已稳定，字段复制成本低、收益是解耦）。
//
//  语义约定：
//  - row_key：favorite = track_stable_id；play_history = "\(trackStableId)|\(playedAt)"
//    （一次播放事件 = 歌 + 开始时刻，跨端稳定，LWW 可重入）；playlist = 本地
//    playlist 行键（slug？见下）；playlist_item = "\(playlistSlug)|\(position)"。
//  - 应用端拿到 upsert 快照：play_history 用 (track_stable_id, played_at) 匹配本地
//    行，存在则更新、不存在则插入（行 id 本地自增，不入对账键）；其余实体按 row_key
//    匹配本地行。
//

import Foundation

// MARK: - favorite

/// favorite 行快照（表结构 = track_stable_id TEXT PRIMARY KEY）。
struct SyncFavoriteSnapshot: Codable, Equatable, Sendable {
    var trackStableId: String

    enum CodingKeys: String, CodingKey {
        case trackStableId = "track_stable_id"
    }

    var rowKey: String { trackStableId }
}

// MARK: - play_history

/// play_history 行快照。id 不入库对账键（两端各自自增），仅作调试参考。
struct SyncPlayHistorySnapshot: Codable, Equatable, Sendable {
    var trackStableId: String
    var playedAt: Int64
    var playDurationMs: Int64

    enum CodingKeys: String, CodingKey {
        case trackStableId = "track_stable_id"
        case playedAt = "played_at"
        case playDurationMs = "play_duration_ms"
    }

    /// 跨端稳定行键：同一次播放事件（歌 + 开始时刻）两端产生同一 row_key。
    var rowKey: String { "\(trackStableId)|\(playedAt)" }
}

// MARK: - playlist

/// playlist 行快照。跨端结构同步 v1 的键 = slug（本地创建时派生、唯一、
/// 用户可改名但 slug 稳定——rename 不改 slug），单 Host-单 Client 场景下
/// Host 端创建的歌单 slug 同步到 Client 即同一逻辑歌单。
struct SyncPlaylistSnapshot: Codable, Equatable, Sendable {
    var slug: String
    var title: String
    var createdAt: Int64
    var updatedAt: Int64
    var lastPlayedAt: Int64
    var folderPath: String?
    var isFolderSynced: Bool
    var lastFolderSync: Int64?
    var customCoverImagePath: String?

    enum CodingKeys: String, CodingKey {
        case slug, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastPlayedAt = "last_played_at"
        case folderPath = "folder_path"
        case isFolderSynced = "is_folder_synced"
        case lastFolderSync = "last_folder_sync"
        case customCoverImagePath = "custom_cover_image_path"
    }

    /// 行键 = slug（本地唯一；rename 不改 slug，跨端稳定）。
    var rowKey: String { slug }
}

// MARK: - playlist_item

/// playlist_item 行快照。行键 = "\(playlistSlug)|\(trackStableId)"（歌单内同歌
/// 唯一，增删/重排/换位同键可比）；position 是载荷字段，重排后逐条 upsert
/// 新位置、旧键不变——结构收敛比位置键稳定（位置键会因插入/重排漂移）。
struct SyncPlaylistItemSnapshot: Codable, Equatable, Sendable {
    var playlistSlug: String
    var position: Int
    var trackStableId: String

    enum CodingKeys: String, CodingKey {
        case playlistSlug = "playlist_slug"
        case position
        case trackStableId = "track_stable_id"
    }

    /// 行键 = 歌单 slug + 曲目 stableId（位置不入键）。
    var rowKey: String { "\(playlistSlug)|\(trackStableId)" }
}

// MARK: - playback_position

/// 播放位置上下文快照。v1 本地载体 = UserDefaults QQPlayerState（非 DB 行，
/// 见 PlayerEngine.savePlayerState）；捕获挂点留待 M4-2 定本地存储后接入。
/// entity 枚举/行模型/LWW/协议层已支持，本快照供协议与测试使用。
struct SyncPlaybackPositionSnapshot: Codable, Equatable, Sendable {
    var trackStableId: String
    var positionMs: Int64
    var updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case trackStableId = "track_stable_id"
        case positionMs = "position_ms"
        case updatedAtMs = "updated_at"
    }

    var rowKey: String { trackStableId }
}

// MARK: - 通用编解码

enum SyncSnapshotCodec {
    /// 编码快照 → payload_json（Codable 结构；失败 = 编码器故障，调用方决定处理）。
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SyncSnapshotCodecError.utf8EncodeFailed
        }
        return string
    }

    /// 解码 payload_json → 快照。
    static func decode<T: Decodable>(_ type: T.Type, from payloadJSON: String?) throws -> T {
        guard let payloadJSON else {
            throw SyncSnapshotCodecError.missingPayload
        }
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SyncSnapshotCodecError.utf8DecodeFailed
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

enum SyncSnapshotCodecError: Error, Equatable {
    case missingPayload
    case utf8EncodeFailed
    case utf8DecodeFailed
}
