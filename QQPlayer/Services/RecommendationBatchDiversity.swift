//
//  RecommendationBatchDiversity.swift
//  QQPlayer
//
//  推荐 v2 P3：单批多样性（纯函数、确定性、可单测）。
//
//  目标（设计 §5）：
//  - 同艺人 ≤ maxPerArtist（硬上限，永不放宽）
//  - 同专辑 ≤ maxPerAlbum（硬上限，永不放宽）
//  - 至少 minDistinctArtists 个不同艺人
//  - 同一 decade ≤ maxPerDecade、同一 genre ≤ maxPerGenre（软上限：池不够时放宽并**标记**）
//
//  放宽绝不静默：`Outcome.relaxed` 回给调用方落日志 / 状态。
//

import Foundation

enum RecommendationBatchDiversity {
    /// 被放宽的多样性目标（用于 `diversity_relaxed` 日志 / 状态）。
    enum Relaxation: String, Sendable, CaseIterable {
        case decade
        case genre
        case artists
    }

    /// 单批口径（默认取 `RecommendationBatchPolicy`）。
    struct Limits: Sendable, Equatable {
        var batchSize: Int
        var maxPerArtist: Int
        var maxPerAlbum: Int
        var minDistinctArtists: Int
        var maxPerDecade: Int
        var maxPerGenre: Int

        static let standard = Limits(
            batchSize: RecommendationBatchPolicy.batchSize,
            maxPerArtist: RecommendationBatchPolicy.maxSongsPerArtist,
            maxPerAlbum: RecommendationBatchPolicy.maxSongsPerAlbum,
            minDistinctArtists: RecommendationBatchPolicy.minDistinctArtists,
            maxPerDecade: RecommendationBatchPolicy.maxSongsPerDecade,
            maxPerGenre: RecommendationBatchPolicy.maxSongsPerGenre
        )
    }

    struct Outcome: Sendable, Equatable {
        var candidates: [RecommendedCandidate]
        /// 被放宽的目标（空 = 全部满足）。
        var relaxed: [Relaxation]

        var isRelaxed: Bool { !relaxed.isEmpty }
    }

    /// 按池顺序（= 排名顺序）挑一批。
    static func select(_ eligible: [RecommendedCandidate], limits: Limits = .standard) -> Outcome {
        let target = max(1, limits.batchSize)
        var state = State(limits: limits)
        var picked: [Int] = []
        /// 已经进过批次的候选（含被替换掉的），替换轮不得再把它捞回来。
        var used = Set<Int>()
        var skippedBySeason: [Int] = []
        var index = 0

        // 第一轮：硬上限 + 季节软上限。
        while index < eligible.count, picked.count < target {
            let candidate = eligible[index]
            let position = index
            index += 1
            guard state.admitsHard(candidate) else { continue }
            guard state.admitsSeason(candidate) else {
                skippedBySeason.append(position)
                continue
            }
            state.take(candidate)
            picked.append(position)
            used.insert(position)
        }
        // 第二轮：批次不满 → 放宽 decade / genre 收尾（池不够时的**已标记**放宽）。
        if picked.count < target {
            for position in skippedBySeason where picked.count < target {
                let candidate = eligible[position]
                guard state.admitsHard(candidate) else { continue }
                state.take(candidate, relaxingSeason: true)
                picked.append(position)
                used.insert(position)
            }
        }

        // 第三轮：不同艺人不足 → 用池里「还没出现过的艺人」替换重复艺人的末位曲目。
        // 只替换、不把没选中的候选推进垃圾桶；硬上限（艺人 / 专辑）在替换时同样成立。
        while state.distinctArtists < limits.minDistinctArtists, !picked.isEmpty {
            guard let incoming = nextNewArtist(from: eligible, used: used, state: state) else { break }
            guard let victim = picked.lastIndex(where: { state.canReplace(eligible[$0]) }) else { break }
            state.replace(out: eligible[picked[victim]], with: eligible[incoming])
            picked[victim] = incoming
            used.insert(incoming)
        }
        if !picked.isEmpty, state.distinctArtists < limits.minDistinctArtists {
            state.relaxed.insert(.artists)
        }

        return Outcome(
            candidates: picked.map { eligible[$0] },
            relaxed: Relaxation.allCases.filter { state.relaxed.contains($0) }
        )
    }

    // MARK: - 计数状态

    private struct State {
        let limits: Limits
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var decadeCounts: [Int: Int] = [:]
        var genreCounts: [String: Int] = [:]
        var relaxed = Set<Relaxation>()

        var distinctArtists: Int { artistCounts.count }

        func artistKey(_ candidate: RecommendedCandidate) -> String {
            RecommendationNormalization.normalizeArtist(candidate.artist)
        }

        func albumKey(_ candidate: RecommendedCandidate) -> String {
            guard let album = candidate.album, !album.isEmpty else {
                return "no-album#" + artistKey(candidate)
            }
            return RecommendationNormalization.normalizeTitle(album)
        }

        /// 硬上限：同艺人 / 同专辑。
        func admitsHard(_ candidate: RecommendedCandidate) -> Bool {
            if (artistCounts[artistKey(candidate)] ?? 0) >= limits.maxPerArtist { return false }
            if (albumCounts[albumKey(candidate)] ?? 0) >= limits.maxPerAlbum { return false }
            return true
        }

        /// 软上限：同 decade / 同 genre（缺数据的维度不参与）。
        func admitsSeason(_ candidate: RecommendedCandidate) -> Bool {
            if let decade = candidate.year.map({ RecommendationScorer.decadeBucket(for: $0) }),
               (decadeCounts[decade] ?? 0) >= limits.maxPerDecade {
                return false
            }
            if let genre = Self.genreKey(candidate), (genreCounts[genre] ?? 0) >= limits.maxPerGenre {
                return false
            }
            return true
        }

        mutating func take(_ candidate: RecommendedCandidate, relaxingSeason: Bool = false) {
            if relaxingSeason, !admitsSeason(candidate) {
                if let decade = candidate.year.map({ RecommendationScorer.decadeBucket(for: $0) }),
                   (decadeCounts[decade] ?? 0) >= limits.maxPerDecade {
                    relaxed.insert(.decade)
                }
                if let genre = Self.genreKey(candidate), (genreCounts[genre] ?? 0) >= limits.maxPerGenre {
                    relaxed.insert(.genre)
                }
            }
            artistCounts[artistKey(candidate), default: 0] += 1
            albumCounts[albumKey(candidate), default: 0] += 1
            if let decade = candidate.year.map({ RecommendationScorer.decadeBucket(for: $0) }) {
                decadeCounts[decade, default: 0] += 1
            }
            if let genre = Self.genreKey(candidate) {
                genreCounts[genre, default: 0] += 1
            }
        }

        /// 该条能不能被换掉：只有「同艺人还有别的曲目」时换掉才不损失多样性。
        func canReplace(_ candidate: RecommendedCandidate) -> Bool {
            (artistCounts[artistKey(candidate)] ?? 0) > 1
        }

        mutating func replace(out removed: RecommendedCandidate, with added: RecommendedCandidate) {
            decrement(removed)
            // 替换同样受软上限约束：超了必须留下标记（放宽绝不静默）。
            if let decade = added.year.map({ RecommendationScorer.decadeBucket(for: $0) }),
               (decadeCounts[decade] ?? 0) >= limits.maxPerDecade {
                relaxed.insert(.decade)
            }
            if let genre = Self.genreKey(added), (genreCounts[genre] ?? 0) >= limits.maxPerGenre {
                relaxed.insert(.genre)
            }
            artistCounts[artistKey(added), default: 0] += 1
            albumCounts[albumKey(added), default: 0] += 1
            if let decade = added.year.map({ RecommendationScorer.decadeBucket(for: $0) }) {
                decadeCounts[decade, default: 0] += 1
            }
            if let genre = Self.genreKey(added) {
                genreCounts[genre, default: 0] += 1
            }
        }

        private mutating func decrement(_ candidate: RecommendedCandidate) {
            Self.drop(&artistCounts, key: artistKey(candidate))
            Self.drop(&albumCounts, key: albumKey(candidate))
            if let decade = candidate.year.map({ RecommendationScorer.decadeBucket(for: $0) }) {
                Self.drop(&decadeCounts, key: decade)
            }
            if let genre = Self.genreKey(candidate) {
                Self.drop(&genreCounts, key: genre)
            }
        }

        private static func drop<Key: Hashable>(_ counts: inout [Key: Int], key: Key) {
            guard let value = counts[key] else { return }
            if value <= 1 {
                counts.removeValue(forKey: key)
            } else {
                counts[key] = value - 1
            }
        }

        static func genreKey(_ candidate: RecommendedCandidate) -> String? {
            guard let genre = candidate.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !genre.isEmpty
            else { return nil }
            return genre.lowercased()
        }
    }

    /// 找一条「艺人尚未出现」的候选：优先不突破硬上限（艺人 / 专辑）也不突破季节软上限的；
    /// 只有全都超季节上限时才退而求其次（由 `replace` 落放宽标记）。
    private static func nextNewArtist(
        from eligible: [RecommendedCandidate],
        used: Set<Int>,
        state: State
    ) -> Int? {
        var seasonOverflow: Int?
        for index in eligible.indices where !used.contains(index) {
            let candidate = eligible[index]
            guard state.admitsHard(candidate) else { continue }
            guard state.artistCounts[state.artistKey(candidate)] == nil else { continue }
            if state.admitsSeason(candidate) { return index }
            if seasonOverflow == nil { seasonOverflow = index }
        }
        return seasonOverflow
    }
}
