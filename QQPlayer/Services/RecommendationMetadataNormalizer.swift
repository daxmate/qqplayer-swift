//
//  RecommendationMetadataNormalizer.swift
//  QQPlayer
//
//  推荐 v3：iTunes 元数据标准化层（B，优先级最高）。
//
//  作用：对高分段候选做一次 iTunes Search 复核，补齐标准曲名 / 专辑 / 年份 / 时长 / previewURL。
//   ① 曲库去重归一（Live 版 vs 原版不再漏判）
//   ② 已下载标记（归一化键与曲库同一口径）
//   ③ 下载衔接（previewURL / songID 由 iTunes 提供时更可靠）
//
//  限流与预算（iTunes 约 20 req/min）：
//  - 同曲（归一化键）7 天缓存，不重复请求；
//  - 全局限速 3s/次（由 `RecommendationMetadataCache` 串行排队）；
//  - 每轮最多 `maxLookups` 次（可配置，0 = 关闭），失败静默跳过、不阻塞整轮。
//

import Foundation

/// 标准化字段（只放 iTunes 能给出的确定值）。
struct RecommendationNormalizedMetadata: Sendable, Equatable {
    var title: String
    var album: String?
    var year: Int?
    var durationMs: Int?
    var previewURL: URL?
    var artworkURL: URL?
}

/// 元数据查询缓存 + 全局限速（actor：跨轮复用，同曲不重复打网络）。
actor RecommendationMetadataCache {
    static let shared = RecommendationMetadataCache()

    /// 缓存有效期（7 天）。
    static let ttl: TimeInterval = 7 * 24 * 3600
    /// 限速间隔（20 req/min ≈ 3s）。
    static let minInterval: TimeInterval = 3.0

    private var entries: [String: (storedAt: Date, value: RecommendationNormalizedMetadata)] = [:]
    private var nextSlot: Date = .distantPast

    func cached(_ key: String, now: Date) -> RecommendationNormalizedMetadata? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) < Self.ttl else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func store(_ key: String, value: RecommendationNormalizedMetadata, now: Date) {
        entries[key] = (now, value)
    }

    /// 预约一个请求时隙（超出限速就等待；actor 重入安全：先占位再 sleep）。
    func reserveSlot(now: Date = Date()) async {
        let target = max(now, nextSlot)
        nextSlot = target.addingTimeInterval(Self.minInterval)
        let delay = target.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

struct RecommendationMetadataNormalizer: Sendable {
    /// iTunes 搜索源（生产 = `ITunesRecommendationProvider`；测试注入桩）。
    var provider: any OnlineSearchProviding
    var cache: RecommendationMetadataCache = .shared
    /// 每轮最多查询条数（0 = 关闭）。
    var maxLookups: Int = 8
    var now: @Sendable () -> Date = { Date() }

    /// 对高分段候选做标准化；返回新数组（顺序不变）与命中数。
    func normalize(
        _ candidates: [RecommendationV3Candidate],
        profile: RecommendationTasteProfileV3
    ) async -> (candidates: [RecommendationV3Candidate], hits: Int) {
        guard maxLookups > 0, !candidates.isEmpty else { return (candidates, 0) }
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let ls = RecommendationRankerV3.score(lhs.element, profile: profile)
            let rs = RecommendationRankerV3.score(rhs.element, profile: profile)
            if abs(ls - rs) > 0.000_001 { return ls > rs }
            return lhs.offset < rhs.offset
        }
        var result = candidates
        var hits = 0
        var lookups = 0
        for (offset, candidate) in ranked {
            guard lookups < maxLookups else { break }
            let key = candidate.libraryKey
            guard !key.isEmpty else { continue }
            let timestamp = now()
            if let cached = await cache.cached(key, now: timestamp) {
                result[offset] = apply(cached, to: candidate)
                hits += 1
                continue
            }
            lookups += 1
            await cache.reserveSlot(now: timestamp)
            let query = "\(candidate.song.artist) \(candidate.song.title)"
            guard let matches = try? await provider.search(query: query, limit: 5), !matches.isEmpty else { continue }
            guard let best = bestMatch(for: candidate, in: matches) else { continue }
            let metadata = RecommendationNormalizedMetadata(
                title: best.title,
                album: best.album,
                year: best.year,
                durationMs: best.durationMs,
                previewURL: best.previewURL,
                artworkURL: best.artworkURL
            )
            await cache.store(key, value: metadata, now: now())
            result[offset] = apply(metadata, to: candidate)
            hits += 1
        }
        return (result, hits)
    }

    /// 只接受「艺人一致」的命中（宁缺勿错）：
    ///   1. 标题键 + 艺人键都一致 → 直接用；
    ///   2. 标题键一致 + 艺人键互相包含（feat. / 多艺人写法差异）→ 用；
    ///   3. 标题键**不同** + 艺人一致 + 该艺人只有唯一候选标题 → 视为「错名纠正」
    ///      （来源写了别名 / 错名，例：Last.fm 的 Ageless Tale → 她来听我的演唱会）。
    ///      唯一性判据是关键：同一艺人回来多首都算不准，宁可放弃也不改名（防把 A 歌改成 B 歌）。
    private func bestMatch(
        for candidate: RecommendationV3Candidate,
        in matches: [RecommendationRemoteSong]
    ) -> RecommendationRemoteSong? {
        let titleKey = RecommendationLibraryMatcher.titleKey(candidate.song.title)
        let artistKey = RecommendationLibraryMatcher.artistKey(candidate.song.artist)
        let exact = matches.filter {
            RecommendationLibraryMatcher.titleKey($0.title) == titleKey
                && RecommendationLibraryMatcher.artistKey($0.artist) == artistKey
        }
        if let first = exact.first { return first }
        // 艺人写法差异（feat. / 多艺人）：标题一致 + 艺人键互相包含也算。
        if let loose = matches.first(where: { match in
            RecommendationLibraryMatcher.titleKey(match.title) == titleKey
                && artistKeysIntersect(artistKey, match.artist)
        }) {
            return loose
        }
        // 错名纠正：艺人一致且回来只有一种标题时，才敢替换标题。
        let sameArtist = matches.filter { artistKeysIntersect(artistKey, $0.artist) }
        let distinctTitles = Set(sameArtist.map { RecommendationLibraryMatcher.titleKey($0.title) })
        guard distinctTitles.count == 1, let only = sameArtist.first else { return nil }
        return only
    }

    /// 艺人键非空且互相包含（多艺人写法差异）。
    private func artistKeysIntersect(_ mine: String, _ other: String) -> Bool {
        let otherKey = RecommendationLibraryMatcher.artistKey(other)
        guard !mine.isEmpty, !otherKey.isEmpty else { return false }
        return otherKey.contains(mine) || mine.contains(otherKey)
    }

    private func apply(
        _ metadata: RecommendationNormalizedMetadata,
        to candidate: RecommendationV3Candidate
    ) -> RecommendationV3Candidate {
        var copy = candidate
        let originalTitleKey = RecommendationLibraryMatcher.titleKey(copy.song.title)
        let normalizedTitleKey = RecommendationLibraryMatcher.titleKey(metadata.title)
        // 只有「真正的错名纠正」才替换标题（例：Last.fm 的 Ageless Tale → 她来听我的演唱会）；
        // 同曲不同版本（Live / Remastered）保持原名，交给归一化键去重。
        if !normalizedTitleKey.isEmpty, normalizedTitleKey != originalTitleKey {
            copy.song.title = metadata.title
        }
        if copy.song.album == nil { copy.song.album = metadata.album }
        if copy.song.year == nil { copy.song.year = metadata.year }
        if copy.song.durationMs == nil { copy.song.durationMs = metadata.durationMs }
        if copy.song.previewURL == nil { copy.song.previewURL = metadata.previewURL }
        if copy.song.artworkURL == nil { copy.song.artworkURL = metadata.artworkURL }
        if copy.context.year == nil { copy.context.year = metadata.year }
        return copy
    }
}
