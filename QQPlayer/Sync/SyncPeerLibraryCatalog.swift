//
//  SyncPeerLibraryCatalog.swift
//  QQPlayer
//
//  T9（2026-09-12）「对端内容清单」的**纯逻辑**一层：把对端曲库事实（歌单 + 曲目 +
//  歌单成员关系）整理成可上线的分页响应。零 IO、零 DB 依赖——生产事实由
//  `DatabaseSyncPeerLibraryFacts`（Services/，读 DB）装配，测试/harness 注入内存事实。
//
//  职责边界（与既有 `SyncCollection.filter` 同风格）：
//  - 排序/去重/分页/筛选/钳制全在本文件（纯函数，可单测）；
//  - 事实从哪来（DB / 内存）不归本文件管。
//
//  确定性：构造时歌单按 (name, id) 升序、曲目按 relativePath 升序，并按标识去重
//  （同 id 同路径只留首个）——同一份事实在任何一端、任何一次编码出同样的字节。
//
//  安全口径（不可信输入只在这里收口）：
//  - scope 非法 → 空清单 + total 0（摘要仍返回）；
//  - limit/offset 钳制（1...500 / >= 0）；
//  - playlistID 指定但未知/非法 → **空集**（绝不回落全库，那是把整个曲库甩给非法请求）；
//  - query 长度上限截断（见 `SyncPeerLibraryRequestPayload.normalizedQuery`）。
//

import Foundation

/// 对端内容清单的全量事实（纯值）。
struct SyncPeerLibraryCatalog: Equatable, Sendable {
    /// 歌单清单（构造时按 name 升序、按 id 去重；含收藏伪歌单由装配方决定）
    var playlists: [SyncPeerPlaylistItem]
    /// 曲目清单（构造时按 relativePath 升序、按 relativePath 去重）
    var tracks: [SyncPeerTrackItem]
    /// 歌单标识 → 成员曲目 relativePath 集合（**本端事实，不上线**；tracks 按歌单筛选用）
    var trackPathsByPlaylist: [String: Set<String>]
    /// 装配时因上限截断（诊断；透传到响应）
    var truncated: Bool

    /// 装配上限：超过就截断（防超大曲库把内存/帧撑爆；截断按已排序前缀，确定性）。
    static let maxEntries = 50_000

    static let empty = SyncPeerLibraryCatalog()

    init(
        playlists: [SyncPeerPlaylistItem] = [],
        tracks: [SyncPeerTrackItem] = [],
        trackPathsByPlaylist: [String: Set<String>] = [:],
        truncated: Bool = false
    ) {
        self.playlists = Self.normalizedPlaylists(playlists)
        self.tracks = Self.normalizedTracks(tracks)
        self.trackPathsByPlaylist = trackPathsByPlaylist
        self.truncated = truncated
    }

    /// 曲库总曲目数（摘要）。
    var trackCount: Int { tracks.count }

    /// 曲库总大小（摘要；负值/未知按 0 计）。
    var totalSizeBytes: Int64 {
        tracks.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
    }

    // MARK: - 响应构建

    /// 一个请求 → 一页响应（**全函数，不抛**）。
    func response(for request: SyncPeerLibraryRequestPayload) -> SyncPeerLibraryResponsePayload {
        guard let scope = request.scopeValue else {
            return emptyResponse(for: request)
        }
        switch scope {
        case .playlists:
            // playlists 范围下 playlistID 无意义（按契约只有 tracks 用），忽略。
            return page(
                items: playlists.map(SyncPeerLibraryItemPayload.playlist),
                request: request
            )
        case .tracks:
            return page(
                items: matchedTracks(for: request).map(SyncPeerLibraryItemPayload.track),
                request: request
            )
        }
    }

    /// 按 playlistID / query 收窄的曲目（保持 relativePath 升序）。
    func matchedTracks(for request: SyncPeerLibraryRequestPayload) -> [SyncPeerTrackItem] {
        var matched = tracks
        if let members = memberPaths(forPlaylistID: request.normalizedPlaylistID) {
            matched = matched.filter { members.contains($0.relativePath) }
        }
        if let query = request.normalizedQuery {
            matched = matched.filter { Self.matches($0, query: query) }
        }
        return matched
    }

    /// 指定歌单的成员相对路径：
    /// - nil（未指定）→ nil = 不过滤
    /// - 未知/非法标识 → 空集（与 `SyncCollection.selectedStableIds` 同语义：
    ///   「选不出内容」比「误给全库」安全）
    func memberPaths(forPlaylistID playlistID: String?) -> Set<String>? {
        guard let playlistID else { return nil }
        guard SyncCollectionSelection.isValidPlaylistID(playlistID) else { return [] }
        return trackPathsByPlaylist[playlistID] ?? []
    }

    /// 搜索词命中（contains，大小写不敏感；标题/歌手/相对路径三者任一命中）。
    static func matches(_ track: SyncPeerTrackItem, query: String) -> Bool {
        let needle = query.lowercased()
        if track.relativePath.lowercased().contains(needle) { return true }
        if let title = track.title?.lowercased(), title.contains(needle) { return true }
        if let artistName = track.artistName?.lowercased(), artistName.contains(needle) { return true }
        return false
    }

    // MARK: - 内部

    /// 非法 scope：空清单 + total 0；**摘要照常返回**（UI 顶部展示不依赖分页）。
    private func emptyResponse(for request: SyncPeerLibraryRequestPayload) -> SyncPeerLibraryResponsePayload {
        SyncPeerLibraryResponsePayload(
            requestID: request.requestID,
            scope: request.scope,
            total: 0,
            items: [],
            hasMore: false,
            libraryTrackCount: trackCount,
            librarySizeBytes: totalSizeBytes,
            truncated: truncated
        )
    }

    /// 取一页（offset/limit 已由请求侧归一钳制）。
    private func page(
        items: [SyncPeerLibraryItemPayload],
        request: SyncPeerLibraryRequestPayload
    ) -> SyncPeerLibraryResponsePayload {
        let start = min(request.clampedOffset, items.count)
        let end = min(start + request.clampedLimit, items.count)
        let slice = start < end ? Array(items[start ..< end]) : []
        return SyncPeerLibraryResponsePayload(
            requestID: request.requestID,
            scope: request.scope,
            total: items.count,
            items: slice,
            hasMore: end < items.count,
            libraryTrackCount: trackCount,
            librarySizeBytes: totalSizeBytes,
            truncated: truncated
        )
    }

    /// 歌单归一：按 (name, id) 升序 + 按 id 去重（同 id 保留首个 = 排序后最靠前者）。
    static func normalizedPlaylists(_ raw: [SyncPeerPlaylistItem]) -> [SyncPeerPlaylistItem] {
        var seen: Set<String> = []
        var out: [SyncPeerPlaylistItem] = []
        let sorted = raw.sorted {
            ($0.name, $0.id) < ($1.name, $1.id)
        }
        for item in sorted where seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }

    /// 曲目归一：按 (relativePath, 其余字段) 升序 + 去重；再按上限截断
    /// （截断标记由装配方给）。
    /// 同路径重复时用其余字段作**确定性**破平（`sorted` 不保证稳定），
    /// 否则同一份事实在不同编译/运行下可能取到不同行，线上字节就不确定了。
    static func normalizedTracks(_ raw: [SyncPeerTrackItem]) -> [SyncPeerTrackItem] {
        var seen: Set<String> = []
        var out: [SyncPeerTrackItem] = []
        for item in raw.sorted(by: isOrderedBefore) where seen.insert(item.relativePath).inserted {
            out.append(item)
        }
        if out.count > maxEntries {
            return Array(out.prefix(maxEntries))
        }
        return out
    }

    /// 曲目全序（相对路径优先；同路径用其余字段破平，保证确定性）。
    private static func isOrderedBefore(_ lhs: SyncPeerTrackItem, _ rhs: SyncPeerTrackItem) -> Bool {
        guard lhs.relativePath == rhs.relativePath else { return lhs.relativePath < rhs.relativePath }
        return tieBreakKey(lhs) < tieBreakKey(rhs)
    }

    private static func tieBreakKey(_ item: SyncPeerTrackItem) -> String {
        "\(item.title ?? "")\u{1F}\(item.artistName ?? "")\u{1F}\(item.sizeBytes)\u{1F}\(item.contentHash ?? "")"
    }
}
