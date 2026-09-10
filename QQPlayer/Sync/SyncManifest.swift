//
//  SyncManifest.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）文件 manifest 模型：条目 / 请求 / 响应载荷（纯声明，无 IO）。
//
//  语义（docs/lan-sync-design.md §5 原语 manifestFetch、§6.1 文件同步）：
//  - 对账键 = relativePath（相对**曲库根**，POSIX 分隔，非绝对路径）——跨端同曲
//    落盘相对路径一致时可直接比对；本端 stableId 是绝对路径哈希，跨端必不一致，
//    只作本端引用映射，不参与对账。
//  - 身份键 = contentHash（SHA-256 = Track.content_hash，M3-1 已落库）——判定
//    "同一首歌"用内容而非路径；nil 表示尚未指纹（保守视为内容未知，见 Reconciler）。
//  - size / mtimeMs 为快速差异提示（生成端一次扫描即可拿到，无额外 IO）；
//    v1 不做基于它们的跳过判定，留给 M3-3b 优化。
//
//  生成/对账逻辑见 SyncManifestGenerator.swift / SyncManifestReconciler.swift；
//  集合过滤见 SyncCollection.swift；帧分发钩子见 SyncManifestPeer.swift。
//

import Foundation

// MARK: - 条目

/// 曲库文件的一条 manifest 记录（线上载荷元素）。
struct ManifestEntry: Codable, Equatable, Sendable {
    /// 相对**曲库根**的路径（POSIX "/"，如 `Album/01 Song.flac`）——对账键。
    var relativePath: String
    /// 文件字节数。
    var size: Int64
    /// 文件修改时间（毫秒 since 1970）——变更提示，不参与 v1 判定。
    var mtimeMs: Int64
    /// 全文件 SHA-256 小写 hex（跨端歌曲身份键）；nil = 尚未指纹。
    var contentHash: String?
    /// 本端 stableId（可选；跨端引用映射用，不参与对账）。
    var stableId: String?

    init(
        relativePath: String,
        size: Int64,
        mtimeMs: Int64,
        contentHash: String? = nil,
        stableId: String? = nil
    ) {
        self.relativePath = relativePath
        self.size = size
        self.mtimeMs = mtimeMs
        self.contentHash = contentHash
        self.stableId = stableId
    }
}

// MARK: - 线载荷

/// manifest_request 帧载荷：请求对端在指定集合下的文件 manifest。
struct SyncManifestRequest: Codable, Equatable, Sendable {
    /// 集合过滤参数（v1：全库 / 歌单 / 手动勾选）。
    var collection: SyncCollection
    /// 请求方已知的 相对路径 → content_hash（增量请求预留）。
    /// v1 恒 nil（请求全量）；M3-3b 需要"只回变更"时再启用，响应端可据此裁剪。
    var knownHashes: [String: String]?

    init(collection: SyncCollection = .all, knownHashes: [String: String]? = nil) {
        self.collection = collection
        self.knownHashes = knownHashes
    }
}

/// manifest_response 帧载荷：对端在请求集合下的 manifest。
struct SyncManifestResponse: Codable, Equatable, Sendable {
    /// 集合过滤后的条目（按 relativePath 升序，确定性）。
    var entries: [ManifestEntry]
    /// 对端曲库根显示名（诊断/UI 用；不参与对账）。
    var rootName: String?

    init(entries: [ManifestEntry], rootName: String? = nil) {
        self.entries = entries
        self.rootName = rootName
    }
}

/// manifest 载荷 JSON 编解码（帧 payload = 载荷类型 JSON 字节）。
enum SyncManifestCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
