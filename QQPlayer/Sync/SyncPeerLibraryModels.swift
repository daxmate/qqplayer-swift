//
//  SyncPeerLibraryModels.swift
//  QQPlayer
//
//  T9（2026-09-12）「对端内容清单」协议载荷（帧 15/16）：纯声明 + JSON 编解码，
//  平台无关、无 IO。
//
//  背景（用户 2026-09-12 反馈）：内容面板此前显示的是**本端**歌单/曲库——「从
//  iPhone 下载」看到的却是 Mac 的内容。正确设计 = 先选方向，内容面板随方向切换
//  数据源。而既有协议只有**文件清单**（帧 10/11 manifest：只有相对路径 + 大小 +
//  指纹），拿不到对端的**歌单结构与曲目元数据**（标题/歌手/大小）。本对帧补的正是
//  这个能力，UI（T10）按本文件的冻结契约调用。
//
//  帧（见 SyncFrame.swift 类型表 v5）：15 = peer_library_request，16 = peer_library_response。
//  10-14 既有值语义冻结不动（14 = library_push_announce）。
//
//  线上字节确定性：条目在**构造期**排序/去重（歌单按 name 升序、曲目按
//  relativePath 升序），故同一份内容在任何一端编码出的 JSON 字节一致，便于比对与断言。
//
//  分页：请求方给 offset/limit，应答方**强制钳制**（limit 1...500、offset >= 0）——
//  钳制在应答侧（不可信输入的最后一道闸），请求侧只按共识取值。
//

import Foundation

// MARK: - 请求

/// `peer_library_request`（帧 15）载荷：请求对端某一类内容清单。
struct SyncPeerLibraryRequestPayload: Codable, Equatable, Sendable {
    /// 请求范围（`SyncPeerLibraryScope.rawValue`：`"playlists"` / `"tracks"`）。
    /// 非法值 → 对端回空清单 + `total: 0`（不报错、不断会话）。
    var scope: String
    /// 目标歌单标识（**对端 slug**；收藏用 `@favorites`）。
    /// 仅 `scope == "tracks"` 且在歌单内筛选时给；nil/空 = 全库。
    var playlistID: String?
    /// `tracks` 搜索词（可选；对端做 contains 匹配，空 = 不过滤）。
    var query: String?
    /// 分页起点（`>= 0`；负值由对端钳到 0）。
    var offset: Int
    /// 页大小（`1...500`；越界由对端钳制）。
    var limit: Int
    /// 关联请求/响应（本端自增；响应原样回显，不匹配的响应一律丢弃）。
    var requestID: UInt64

    /// 页大小下限（两端共识）。
    static let minLimit = 1
    /// 页大小上限（两端共识；防对端一次拉爆内存/帧上限）。
    static let maxLimit = 500
    /// 搜索词长度上限（不可信输入：超长 query 截断，避免打爆对端 DB）。
    static let maxQueryLength = 128

    init(
        scope: String,
        playlistID: String? = nil,
        query: String? = nil,
        offset: Int = 0,
        limit: Int = 50,
        requestID: UInt64
    ) {
        self.scope = scope
        self.playlistID = playlistID
        self.query = query
        self.offset = offset
        self.limit = limit
        self.requestID = requestID
    }

    // MARK: 归一（应答侧：不可信输入的唯一收口）

    /// 钳制后的页大小（`<= 0 → 1`，`> 500 → 500`）。
    var clampedLimit: Int {
        min(max(limit, Self.minLimit), Self.maxLimit)
    }

    /// 钳制后的分页起点（负值 → 0）。
    var clampedOffset: Int {
        max(offset, 0)
    }

    /// 解析后的范围（未知字符串 → nil = 非法 scope）。
    var scopeValue: SyncPeerLibraryScope? {
        SyncPeerLibraryScope(rawValue: scope)
    }

    /// 归一后的搜索词：去首尾空白 + 截断到 `maxQueryLength`；空 → nil（= 不过滤）。
    var normalizedQuery: String? {
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxQueryLength))
    }

    /// 归一后的歌单标识：去空白；空 → nil（= 全库）。
    /// 形态非法（超长/含分隔符/控制字符）时仍返回原值——由成员表查不到自然收成空集，
    /// 绝不回落「全库」（那会把整个曲库甩给一个非法请求）。
    var normalizedPlaylistID: String? {
        let trimmed = (playlistID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 请求范围取值（线上字符串；枚举只为编译期收口，载荷字段仍是 String 以保证前向兼容）。
enum SyncPeerLibraryScope: String, Equatable, Sendable, CaseIterable {
    /// 歌单清单（含收藏伪歌单，若对端有收藏）
    case playlists
    /// 曲目清单（可再按歌单/搜索词收窄）
    case tracks
}

// MARK: - 响应

/// 歌单条目（对端事实）。
struct SyncPeerPlaylistItem: Codable, Equatable, Sendable {
    /// 对端歌单标识（slug；收藏用 `@favorites`）
    var id: String
    /// 展示名
    var name: String
    /// 曲目数
    var trackCount: Int
}

/// 曲目条目（对端事实）。
struct SyncPeerTrackItem: Codable, Equatable, Sendable {
    /// 跨端对账键（wire 口径：相对**对端曲库根**的 POSIX 路径）
    var relativePath: String
    /// 标题（nil = 未知）
    var title: String?
    /// 歌手展示名（nil = 未知）
    var artistName: String?
    /// 文件字节数（对端 `file_size` 口径；未知 = 0）
    var sizeBytes: Int64
    /// 内容指纹（nil = 尚未指纹，与 manifest 同口径）
    var contentHash: String?

    init(
        relativePath: String,
        title: String? = nil,
        artistName: String? = nil,
        sizeBytes: Int64 = 0,
        contentHash: String? = nil
    ) {
        self.relativePath = relativePath
        self.title = title
        self.artistName = artistName
        self.sizeBytes = sizeBytes
        self.contentHash = contentHash
    }
}

/// 清单条目（两端同构的联合：歌单 / 曲目）。
/// 手写 Codable：带 `kind` 判别字段的扁平 JSON（而非 Swift 合成 enum 的嵌套形态），
/// 跨语言/跨版本可读且加新 case 不破坏旧端解码。
enum SyncPeerLibraryItemPayload: Codable, Equatable, Sendable {
    case playlist(SyncPeerPlaylistItem)
    case track(SyncPeerTrackItem)

    private enum CodingKeys: String, CodingKey {
        case kind
        case playlist
        case track
    }

    private enum Kind: String, Codable {
        case playlist
        case track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .playlist:
            self = .playlist(try container.decode(SyncPeerPlaylistItem.self, forKey: .playlist))
        case .track:
            self = .track(try container.decode(SyncPeerTrackItem.self, forKey: .track))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .playlist(item):
            try container.encode(Kind.playlist, forKey: .kind)
            try container.encode(item, forKey: .playlist)
        case let .track(item):
            try container.encode(Kind.track, forKey: .kind)
            try container.encode(item, forKey: .track)
        }
    }

    /// 歌单条目（非歌单 → nil）。
    var playlistValue: SyncPeerPlaylistItem? {
        if case let .playlist(item) = self { return item }
        return nil
    }

    /// 曲目条目（非曲目 → nil）。
    var trackValue: SyncPeerTrackItem? {
        if case let .track(item) = self { return item }
        return nil
    }
}

/// `peer_library_response`（帧 16）载荷：一页清单 + 摘要。
/// 摘要（`libraryTrackCount` / `librarySizeBytes`）**恒返回**——UI 顶部「N 首 · 约 X GB」
/// 不依赖分页，空页/非法 scope 也有值。
struct SyncPeerLibraryResponsePayload: Codable, Equatable, Sendable {
    /// 回显请求的 `requestID`
    var requestID: UInt64
    /// 回显请求的 scope（非法值原样回显，便于请求方定位）
    var scope: String
    /// 该 scope 下（含筛选）总条数
    var total: Int
    /// 本页条目
    var items: [SyncPeerLibraryItemPayload]
    /// 后面还有页
    var hasMore: Bool
    /// 对端曲库总曲目数（摘要）
    var libraryTrackCount: Int
    /// 对端曲库总大小（摘要；未知大小按 0 计）
    var librarySizeBytes: Int64
    /// 对端因上限截断（诊断）
    var truncated: Bool

    init(
        requestID: UInt64,
        scope: String,
        total: Int,
        items: [SyncPeerLibraryItemPayload] = [],
        hasMore: Bool = false,
        libraryTrackCount: Int = 0,
        librarySizeBytes: Int64 = 0,
        truncated: Bool = false
    ) {
        self.requestID = requestID
        self.scope = scope
        self.total = total
        self.items = items
        self.hasMore = hasMore
        self.libraryTrackCount = libraryTrackCount
        self.librarySizeBytes = librarySizeBytes
        self.truncated = truncated
    }

    /// 本页歌单条目（保持页内序）。
    var playlistItems: [SyncPeerPlaylistItem] {
        items.compactMap(\.playlistValue)
    }

    /// 本页曲目条目（保持页内序）。
    var trackItems: [SyncPeerTrackItem] {
        items.compactMap(\.trackValue)
    }
}

// MARK: - 编解码（帧 payload = 载荷类型 JSON 字节，风格对齐 SyncManifestCodec）

enum SyncPeerLibraryCodec {
    /// 编码：**键排序**（`.sortedKeys`）——同一份值编出的字节逐字节一致，
    /// 便于跨端比对与测试断言（JSON 对象键序本无语义，不影响解码）。
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
