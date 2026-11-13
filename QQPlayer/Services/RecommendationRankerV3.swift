//
//  RecommendationRankerV3.swift
//  QQPlayer
//
//  推荐 v3：过滤（顺序固定）+ 打分 + 稳定排序 + 多样性上限。纯逻辑。
//
//  过滤顺序（不得调整，单测逐条覆盖）：
//   1. 曲库排除（硬需求）
//   2. 黑名单（曲目 / 艺人）
//   3. 时长 30s–10min（缺失时长放行）
//   4. 群星 / 合辑 / 伴奏标记
//   5. 归一化去重（同曲目多来源只留分数最高的一条）
//   6. 单艺人 ≤2 首、单专辑 ≤1 首
//
//  打分：score = affinity × 通道权重 × 热度归一 × 年代/语言匹配 × 新鲜度惩罚。
//  排序稳定：同分依次比较热度、标题归一键、艺人归一键、通道（全部与遍历顺序无关）。
//

import Foundation

/// 召回产物（排序前）：远程歌曲 + 召回上下文 + 来源排名。
struct RecommendationV3Candidate: Sendable, Equatable {
    var song: RecommendationRemoteSong
    var context: RecommendationCandidateContext
    /// 来源排行位置（0 = 第一条；nil = 来源给不出排名）。
    var sourceRank: Int?
    /// 分数（`rank` 之后才有意义；召回阶段恒为 0）。
    var score: Double = 0

    init(
        song: RecommendationRemoteSong,
        context: RecommendationCandidateContext,
        sourceRank: Int? = nil
    ) {
        self.song = song
        self.context = context
        self.sourceRank = sourceRank
    }

    /// 归一化曲目键（与曲库排除 / 已下载标记同一口径）。
    var libraryKey: String {
        RecommendationLibraryMatcher.key(title: song.title, artist: song.artist)
    }
}

enum RecommendationRankerV3 {
    /// 时长边界（毫秒）。
    static let minDurationMs = 30_000
    static let maxDurationMs = 600_000
    static let maxSongsPerArtist = 2
    static let maxSongsPerAlbum = 1

    // MARK: - 过滤

    /// 固定顺序的准入过滤（不排序、不截断）。
    static func admit(
        _ candidates: [RecommendationV3Candidate],
        profile: RecommendationTasteProfileV3
    ) -> [RecommendationV3Candidate] {
        let library = profile.libraryKeys
        let blacklistTracks = profile.blacklistTracks
        let blacklistArtists = Set(profile.blacklistArtists.map { RecommendationLibraryMatcher.artistKey($0) })

        var seen = Set<String>()
        var out: [RecommendationV3Candidate] = []
        out.reserveCapacity(candidates.count)
        for candidate in candidates {
            let key = candidate.libraryKey
            guard !key.isEmpty else { continue }
            // 1. 曲库排除（硬需求）
            guard !library.contains(key) else { continue }
            // 2. 黑名单
            guard !blacklistTracks.contains(key) else { continue }
            guard !blacklistArtists.contains(RecommendationLibraryMatcher.artistKey(candidate.song.artist)) else { continue }
            // 3. 时长
            if let duration = candidate.song.durationMs, duration < minDurationMs || duration > maxDurationMs {
                continue
            }
            // 4. 群星 / 合辑 / 伴奏
            guard !isCompilationOrKaraoke(candidate.song) else { continue }
            // 5. 归一化去重（首次出现即保留；调用方已按分数预排序时高者优先）
            guard seen.insert(key).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    /// 群星 / 合辑 / 伴奏判定（只认明确标记，不用模糊猜测）。
    static func isCompilationOrKaraoke(_ song: RecommendationRemoteSong) -> Bool {
        let artist = song.artist.lowercased()
        let album = (song.album ?? "").lowercased()
        let title = song.title.lowercased()
        let artistTokens = ["群星", "various artists", "various artist", "va ", "ost"]
        let albumTokens = ["群星", "various artists", "compilation", "greatest hits", "精选", "合辑", "合集"]
        let titleTokens = ["伴奏", "instrumental", "karaoke", "off vocal", "カラオケ", "inst."]
        if artistTokens.contains(where: { artist == $0.trimmingCharacters(in: .whitespaces) || artist.contains($0) }) { return true }
        if !album.isEmpty, albumTokens.contains(where: { album.contains($0) }) { return true }
        if titleTokens.contains(where: { title.contains($0) }) { return true }
        return false
    }

    // MARK: - 打分

    static func score(
        _ candidate: RecommendationV3Candidate,
        profile: RecommendationTasteProfileV3,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Double {
        let affinity = affinityScore(candidate, profile: profile)
        let channelWeight = candidate.context.channel.scoreWeight
        let popularity = popularityScore(candidate)
        let match = eraLanguageMatch(candidate, profile: profile)
        let freshness = freshnessScore(candidate.context.year ?? candidate.song.year, now: now, calendar: calendar)
        return affinity * channelWeight * (0.5 + 0.5 * popularity) * match * freshness
    }

    static func affinityScore(_ candidate: RecommendationV3Candidate, profile: RecommendationTasteProfileV3) -> Double {
        if let affinity = candidate.context.affinity { return clamp01(affinity) }
        let seed = candidate.context.seedArtist ?? candidate.song.artist
        let seedAffinity = profile.affinity(forArtist: seed)
        switch candidate.context.channel {
        case .seed, .request:
            return seedAffinity > 0 ? seedAffinity : 0.2
        case .similar:
            let similarity = clamp01(candidate.context.similarity ?? 0.5)
            let base = seedAffinity > 0 ? seedAffinity : 0.2
            return base * (0.6 + 0.4 * similarity)
        case .explore:
            return max(0.15, seedAffinity)
        }
    }

    static func popularityScore(_ candidate: RecommendationV3Candidate) -> Double {
        if let popularity = candidate.context.popularity { return clamp01(popularity) }
        guard let rank = candidate.sourceRank else { return 0.5 }
        return clamp01(1.0 - Double(rank) / 20.0)
    }

    /// 年代 / 语言匹配：命中画像 Top 簇 → 1；部分命中 → 0.9；未知 → 0.85；明确不符 → 0.75。
    static func eraLanguageMatch(_ candidate: RecommendationV3Candidate, profile: RecommendationTasteProfileV3) -> Double {
        guard !profile.clusters.isEmpty else { return 0.85 }
        let language = candidate.context.language ?? RecommendationLanguageDetector.detect(in: [candidate.song.artist, candidate.song.title])
        let decade = RecommendationProfileV3Builder.decadeStart(candidate.context.year ?? candidate.song.year)
        var best = 0.75
        for cluster in profile.clusters {
            let languageMatches = language != .unknown && language == cluster.language
            let decadeMatches = decade != nil && decade == cluster.decade
            if languageMatches && (cluster.decade == nil || decadeMatches) {
                best = max(best, 1.0)
            } else if languageMatches {
                best = max(best, 0.9)
            } else if language == .unknown {
                best = max(best, 0.85)
            }
        }
        return best
    }

    /// 新鲜度惩罚：3 年内满权重，之后线性衰减，最低 0.6。
    static func freshnessScore(_ year: Int?, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        guard let year else { return 0.9 }
        let currentYear = calendar.component(.year, from: now)
        let age = currentYear - year
        guard age > 3 else { return 1.0 }
        return max(0.6, 1.0 - Double(age - 3) / 60.0)
    }

    // MARK: - 排序 + 多样性

    /// 打分 + 稳定排序 + 多样性上限。
    static func rank(
        _ candidates: [RecommendationV3Candidate],
        profile: RecommendationTasteProfileV3,
        now: Date = Date()
    ) -> [RecommendationV3Candidate] {
        let admitted = admit(candidates, profile: profile)
        var scored = admitted.map { candidate -> RecommendationV3Candidate in
            var copy = candidate
            copy.score = score(candidate, profile: profile, now: now)
            return copy
        }
        scored.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score > rhs.score }
            let lp = popularityScore(lhs)
            let rp = popularityScore(rhs)
            if abs(lp - rp) > 0.000_001 { return lp > rp }
            let lt = RecommendationLibraryMatcher.titleKey(lhs.song.title)
            let rt = RecommendationLibraryMatcher.titleKey(rhs.song.title)
            if lt != rt { return lt < rt }
            let la = RecommendationLibraryMatcher.artistKey(lhs.song.artist)
            let ra = RecommendationLibraryMatcher.artistKey(rhs.song.artist)
            if la != ra { return la < ra }
            return lhs.context.channel.rawValue < rhs.context.channel.rawValue
        }
        return applyDiversity(scored)
    }

    /// 单艺人 ≤2、单专辑 ≤1（专辑缺失不去重；纯函数、保持原顺序）。
    static func applyDiversity(_ sorted: [RecommendationV3Candidate]) -> [RecommendationV3Candidate] {
        var artistCounts: [String: Int] = [:]
        var albums = Set<String>()
        var out: [RecommendationV3Candidate] = []
        for candidate in sorted {
            let artistKey = RecommendationLibraryMatcher.artistKey(candidate.song.artist)
            let artistCount = artistCounts[artistKey, default: 0]
            guard artistCount < maxSongsPerArtist else { continue }
            if let album = candidate.song.album.map({ RecommendationLibraryMatcher.normalize($0) }), !album.isEmpty {
                guard albums.insert(album).inserted else { continue }
            }
            artistCounts[artistKey] = artistCount + 1
            out.append(candidate)
        }
        return out
    }

    // MARK: - 工具

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
