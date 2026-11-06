//
//  RecommendationEngine+ArtistConstraint.swift
//  QQPlayer
//
//  本地 AI 推荐：点名艺人约束的接线层（别名查询 / 约束构建 / 请求路径）。
//
//  - 纯逻辑（名称集合、相似语义判定、别名解析）在 RecommendationArtistConstraint.swift；
//    本文件只负责把约束接进引擎，并保证排序确定（不依赖字典 / Set 遍历顺序）。
//

import Foundation

// MARK: - 网易云别名

extension NeteaseSearchProvider: ArtistAliasProviding {
    /// 点名艺人别名：只返回与点名归一化后相等的艺人条目的名称集合；失败降级为空。
    func aliases(for artist: String) async -> [String] {
        do {
            let artists = try await client.searchArtists(query: artist, limit: 5)
            let candidates = artists.map {
                RecommendationArtistAliasResolver.Candidate(name: $0.name, aliases: $0.aliases)
            }
            return RecommendationArtistAliasResolver.aliases(for: artist, from: candidates)
        } catch {
            AppLog.warn(.general, "⚠️ 推荐艺人别名解析失败（\(artist)）：\(error.localizedDescription)")
            return []
        }
    }

}

// MARK: - 约束构建

extension RecommendationEngine {
    /// 点名艺人约束：referenceArtists 非空、且请求不是「类似 X」、别名解析成功时才启用。
    /// 任一条件不满足返回 nil，保持既有行为（宁可不约束，也不静默返回 0 条）。
    private func makeArtistConstraint(for request: RecommendationUserRequest) async -> RecommendationArtistConstraint? {
        if RecommendationArtistRequestSemantics.isSimilarityRequest(request.rawText) {
            AppLog.info(.general, "🎵 推荐解析：识别为相似/风格请求，不启用点名硬约束")
            return nil
        }

        let named = request.referenceArtists
            .map { RecommendationKey.displayPrimaryArtist($0) }
            .filter { !$0.isEmpty }
        guard let primary = named.first else {
            AppLog.debug(.general, "🎵 推荐解析：referenceArtists 为空，按既有行为召回")
            return nil
        }

        let aliasProvider = providers.compactMap { $0 as? any ArtistAliasProviding }.first
        var names: [String] = []
        for artist in named {
            let aliases = await aliasProvider?.aliases(for: artist) ?? []
            guard !aliases.isEmpty else {
                AppLog.warn(
                    .general,
                    "⚠️ 推荐点名艺人别名解析失败/为空（\(artist)），放弃硬约束并回退旧行为"
                )
                return nil
            }
            names.append(contentsOf: aliases)
        }
        let constraint = RecommendationArtistConstraint(displayName: primary, names: names)
        AppLog.info(
            .general,
            "🎵 推荐点名艺人：\(named.joined(separator: "、")) 约束集合=\(constraint.tokens.sorted())"
        )
        return constraint
    }

}

// MARK: - 请求路径（点名约束接线）

extension RecommendationEngine {
    /// 指令输入：显式条件优先于画像；召回 / 打分 / 去重 / 多样性上限全部复用。
    func recommend(
        request: RecommendationUserRequest,
        profile: TasteProfile,
        count: Int
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        guard !request.isEmpty else { return .failure(.emptyRequest) }
        let intents = RecommendationIntentBuilder.intents(from: request, profile: profile)
        guard !intents.isEmpty else { return .failure(.emptyRequest) }
        guard !providers.isEmpty else { return .failure(.allSourcesFailed) }

        let excluded = Set(
            request.excludeArtists
                .map { RecommendationKey.primaryArtist($0) }
                .filter { !$0.isEmpty }
        )
        let artistConstraint = await makeArtistConstraint(for: request)
        let gathered = await gather(
            profile: profile,
            intents: intents,
            excludedArtists: excluded,
            artistConstraint: artistConstraint
        )
        if gathered.items.isEmpty {
            if gathered.allFailed { return .failure(.allSourcesFailed) }
            AppLog.info(.general, "🎵 推荐结果：点名艺人 \(artistConstraint?.displayName ?? "无") 无匹配候选，返回 0 条")
            return .success([])
        }

        let explicitArtists = RecommendationIntentBuilder.explicitArtistTokens(intents: intents, request: request)
        let explicitKeys = Set(
            intents
                .filter { RecommendationIntentBuilder.isExplicit($0, artists: explicitArtists) }
                .map(\.priorityKey)
        )

        let ranked = rank(gathered.items, profile: profile)
        // 点名模式：直接同艺人召回稳定排在相似召回之前（不依赖字典 / Set 顺序）。
        let prioritized = artistConstraint == nil ? ranked : Self.artistFirst(ranked)
        let ordered = RecommendationExplicitPriority.order(prioritized) { item in
            explicitKeys.contains(item.item.intent.priorityKey)
                || RecommendationExplicitPriority.matches(RecommendationKey.primaryArtist(item.item.song.artist), artists: explicitArtists)
        }
        let picked = select(ordered, count: count, profile: profile, artistConstraint: artistConstraint)
        AppLog.info(
            .general,
            "🎵 推荐结果：\(picked.count)/\(max(1, count)) 条（点名艺人 \(artistConstraint?.displayName ?? "无")）"
        )
        return .success(picked)
    }

    /// 稳定分区：直接同艺人召回（.artist）在前，其余保持原相对顺序。
    private static func artistFirst(_ items: [RankedItem]) -> [RankedItem] {
        let direct = items.filter { $0.item.intent.kind == .artist }
        let rest = items.filter { $0.item.intent.kind != .artist }
        return direct + rest
    }
}
