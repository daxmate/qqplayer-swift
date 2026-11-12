//
//  RecallSession.swift
//  QQPlayer
//
//  推荐 P2：会话池 + 游标 + 已推集合（「换一批」不重新请求网络）。
//
//  - 首批 15 首；游标推进；池剩余 < 一批 = needsRefill（由调用方做增量查询）
//  - 同批约束：同艺人 ≤4、同专辑 ≤2（设计 §5）
//  - `seen` 会话内持久：同一候选不会被两批重复推荐
//

import Foundation

/// 推荐会话池（值类型；由调用方持有并更新）。
struct RecallSession: Sendable, Equatable {
    enum RefillState: String, Sendable {
        /// 剩余足够下一批。
        case ready
        /// 不足一批，仍需增量查询（调用方可在换批前补池）。
        case needsRefill
        /// 池已耗尽。
        case exhausted
    }

    private(set) var pool: [RecommendedCandidate]
    private(set) var cursor: Int
    private(set) var seen: Set<String>
    let batchSize: Int
    let maxPerArtist: Int
    let maxPerAlbum: Int

    init(
        pool: [RecommendedCandidate] = [],
        batchSize: Int = RecommendationBatchPolicy.batchSize,
        maxPerArtist: Int = RecommendationBatchPolicy.maxSongsPerArtist,
        maxPerAlbum: Int = RecommendationBatchPolicy.maxSongsPerAlbum
    ) {
        self.pool = pool
        self.cursor = 0
        self.seen = []
        self.batchSize = max(1, batchSize)
        self.maxPerArtist = max(1, maxPerArtist)
        self.maxPerAlbum = max(1, maxPerAlbum)
    }

    /// 池里还没被消费/标记的候选数。
    var remaining: Int {
        pool.reduce(into: 0) { count, candidate in
            if !seen.contains(Self.key(candidate)) { count += 1 }
        }
    }

    var state: RefillState {
        if remaining == 0 { return .exhausted }
        return remaining < batchSize ? .needsRefill : .ready
    }

    /// 取下一批：推进游标、标记 seen、应用同批上限。
    mutating func nextBatch() -> [RecommendedCandidate] {
        var picked: [RecommendedCandidate] = []
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        while picked.count < batchSize, cursor < pool.count {
            let candidate = pool[cursor]
            cursor += 1
            let key = Self.key(candidate)
            guard !seen.contains(key) else { continue }

            let artist = Self.artistKey(candidate)
            let album = Self.albumKey(candidate)
            guard artistCounts[artist, default: 0] < maxPerArtist,
                  albumCounts[album, default: 0] < maxPerAlbum else {
                continue
            }
            artistCounts[artist, default: 0] += 1
            albumCounts[album, default: 0] += 1
            seen.insert(key)
            picked.append(candidate)
        }
        return picked
    }

    /// 增量补池（去重；返回实际加入条数）。游标保持不动，新条目追加在末尾。
    @discardableResult
    mutating func append(pool newItems: [RecommendedCandidate]) -> Int {
        var added = 0
        for item in newItems {
            let key = Self.key(item)
            guard !seen.contains(key), !pool.contains(where: { Self.key($0) == key }) else { continue }
            pool.append(item)
            added += 1
        }
        return added
    }

    /// 标记一批已展示但未消费的候选（例如缓存恢复的历史结果）。
    mutating func markSeen(_ candidates: [RecommendedCandidate]) {
        for candidate in candidates {
            seen.insert(Self.key(candidate))
        }
    }

    static func key(_ candidate: RecommendedCandidate) -> String {
        RecommendationNormalization.dedupeKey(title: candidate.title, artist: candidate.artist)
    }

    static func artistKey(_ candidate: RecommendedCandidate) -> String {
        RecommendationNormalization.normalizeArtist(candidate.artist)
    }

    static func albumKey(_ candidate: RecommendedCandidate) -> String {
        guard let album = candidate.album, !album.isEmpty else {
            return "no-album#\(artistKey(candidate))"
        }
        return RecommendationNormalization.normalizeTitle(album)
    }
}
