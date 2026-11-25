//
//  RecommendationDownloadedRetention.swift
//  QQPlayer
//
//  推荐 v4：已下载条目的**保留**（纯逻辑、无 IO、无 UI 依赖）。
//
//  为什么需要：
//    v3 把「在曲库里」当硬排除条件——用户刚下载完一首推荐，下一次后台重算
//    （缓存过期 / 画像刷新）就会把它从列表里抹掉，用户看到的是「我下载的歌不见了」。
//    v4 的口径：**当前这一批**里已下载的条目保留并打「已下载」标，最多留 3 首；
//    只有「换一批 / 新生成批次」才把已下载的排除掉（已拥有的不重复推）。
//
//  与引擎的关系：引擎负责「放行」（`keepKeys`），本类型负责「合回列表」——
//  两次重算的候选来源可能不同（换源 / 换种子），靠引擎单侧保证不住，必须在列表层兜底。
//

import Foundation

enum RecommendationDownloadedRetention {
    /// 单批保留上限（超出按原批顺序丢弃）。
    static let maxRetained = 3

    /// 把上一批里「已下载且新批没有」的条目按原位置合回新批。
    ///
    /// - 只在`isDownloaded`为真时保留；未下载的条目照常被新批替换。
    /// - 保序：尽量回到原下标位置（不超过结果长度），避免列表整体跳动。
    static func merge(
        previous: [RecommendedCandidate],
        fresh: [RecommendedCandidate],
        isDownloaded: (RecommendedCandidate) -> Bool,
        limit: Int = maxRetained
    ) -> [RecommendedCandidate] {
        guard limit > 0, !previous.isEmpty else { return fresh }
        var freshKeys = Set(fresh.map { RecommendationLibraryMatcher.key(title: $0.title, artist: $0.artist) })
        var result = fresh
        var retained = 0
        for (index, candidate) in previous.enumerated() {
            guard retained < limit else { break }
            let key = RecommendationLibraryMatcher.key(title: candidate.title, artist: candidate.artist)
            guard !key.isEmpty, !freshKeys.contains(key) else { continue }
            guard isDownloaded(candidate) else { continue }
            let position = min(index, result.count)
            result.insert(candidate, at: position)
            freshKeys.insert(key)
            retained += 1
        }
        return result
    }
}
