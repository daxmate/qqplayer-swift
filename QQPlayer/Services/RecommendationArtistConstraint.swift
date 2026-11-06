//
//  RecommendationArtistConstraint.swift
//  QQPlayer
//
//  本地 AI 推荐：点名艺人硬约束（纯逻辑层，iOS / macOS 共享）。
//
//  - `RecommendationArtistConstraint`：用户点名的艺人 → 规范化名称集合；
//    候选歌曲的主艺人只有命中集合才允许进入最终列表。
//  - `RecommendationArtistAliasResolver`：从在线艺人搜索结果里挑出同一艺人的
//    官方名 / 别名（如 西城男孩 ↔ Westlife），全部纯函数。
//  - `ArtistAliasProviding`：别名查询契约（在线实现见 NeteaseSearchProvider）。
//
//  ⚠️ 本文件只依赖 Foundation；大小写 / 全半角 / 空白归一口径复用 RecommendationKey。
//

import Foundation

/// 点名艺人的别名查询契约（在线源实现；失败返回 [] 由约束降级为点名原名）。
protocol ArtistAliasProviding: Sendable {
    func aliases(for artist: String) async -> [String]
}

/// 点名艺人的硬约束：最终列表只允许主艺人命中集合的条目，不足不补足。
struct RecommendationArtistConstraint: Sendable, Equatable {
    /// 用户点名的展示名（第一个非空 referenceArtist，UI 文案用）。
    let displayName: String
    /// 归一化后的艺人名集合（点名原名 + 在线别名）。
    let tokens: Set<String>

    init(displayName: String, names: [String]) {
        self.displayName = RecommendationKey.displayPrimaryArtist(displayName)
        var tokens = Set<String>()
        for name in [displayName] + names {
            let token = RecommendationKey.artistMatchKey(name)
            guard !token.isEmpty else { continue }
            tokens.insert(token)
        }
        self.tokens = tokens
    }

    var isEmpty: Bool { tokens.isEmpty }

    /// 候选主艺人是否命中点名集合（归一化后精确比对）。
    func matches(artist: String) -> Bool {
        tokens.contains(RecommendationKey.artistMatchKey(artist))
    }
}

/// 从艺人搜索结果里解析同一艺人的名称集合（纯函数，便于单测）。
enum RecommendationArtistAliasResolver {
    struct Candidate: Sendable, Equatable {
        var name: String
        var aliases: [String]
    }

    /// 只接受「官方名或别名与点名归一化后相等」的条目，避免搜索结果里的无关艺人污染集合。
    static func aliases(for artist: String, from candidates: [Candidate]) -> [String] {
        let token = RecommendationKey.artistMatchKey(artist)
        guard !token.isEmpty else { return [] }
        var result: [String] = []
        for candidate in candidates {
            let names = [candidate.name] + candidate.aliases
            guard names.contains(where: { RecommendationKey.artistMatchKey($0) == token }) else { continue }
            result.append(contentsOf: names)
        }
        return result
    }
}
