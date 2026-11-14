//
//  MacRecommendationModel+Downloaded.swift
//  QQPlayer
//
//  推荐 v3：已下载标记（渲染层判定）。
//
//  口径：候选的归一化键（标题剥离版本后缀 + 主艺人）命中曲库 → 已下载。
//  与「生成时排除曲库曲目」不冲突：本轮已下载项保留并标记，下一次生成自然消失。
//
//  刷新时机（三条，均幂等）：
//   1. 下载落库通知：`.trackFound`（新曲入库 = 下载链路真正完成的信号）；
//   2. 曲库批量变更：`.libraryNeedsRefresh`（扫描收尾 / 元数据刷新 / 清理）；
//   3. 兜底：下载面板关闭（`onDismiss`）。
//  通知是突发的（一次扫描可连发多条）→ `scheduleDownloadedKeysRefresh()` 用短去抖合并成一次 DB 读。
//

import Foundation

extension MacRecommendationModel {
    /// 候选是否已在曲库（含本会话刚从推荐页下载完成的）。
    func isDownloaded(_ candidate: RecommendedCandidate) -> Bool {
        downloadedIndex.isDownloaded(title: candidate.title, artist: candidate.artist)
    }

    /// 重新读曲库键（下载面板关闭 / 下载完成后调用）。
    func refreshDownloadedKeys() async {
        downloadedIndex = await downloadedIndex.refreshed()
    }

    /// 通知驱动的合并刷新：短去抖后只读一次曲库；连续通知会取消上一次未执行的刷新。
    func scheduleDownloadedKeysRefresh() {
        downloadedKeysRefreshTask?.cancel()
        downloadedKeysRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.downloadedKeysRefreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refreshDownloadedKeys()
        }
    }

    /// 去抖窗口：一次扫描的 `trackFound` / `libraryNeedsRefresh` 连发在此窗口内合并。
    static var downloadedKeysRefreshDebounceNanoseconds: UInt64 { 300_000_000 }
}
