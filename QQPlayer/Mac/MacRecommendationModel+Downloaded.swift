//
//  MacRecommendationModel+Downloaded.swift
//  QQPlayer
//
//  推荐 v3：已下载标记（渲染层判定）。
//
//  口径：候选的归一化键（标题剥离版本后缀 + 主艺人）命中曲库 → 已下载。
//  与「生成时排除曲库曲目」不冲突：本轮已下载项保留并标记，下一次生成自然消失。
//

import Foundation

extension MacRecommendationModel {
    /// 候选是否已在曲库（含本会话刚从推荐页下载完成的）。
    func isDownloaded(_ candidate: RecommendedCandidate) -> Bool {
        let key = RecommendationLibraryMatcher.key(title: candidate.title, artist: candidate.artist)
        guard !key.isEmpty else { return false }
        return downloadedKeys.contains(key)
    }

    /// 重新读曲库键（下载面板关闭 / 下载完成后调用）。
    func refreshDownloadedKeys() async {
        downloadedKeys = await RecommendationV3DataSource.loadLibraryKeys()
    }
}
