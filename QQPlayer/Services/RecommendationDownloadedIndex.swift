//
//  RecommendationDownloadedIndex.swift
//  QQPlayer
//
//  推荐 v3：已下载判定状态（平台无关纯逻辑，可单测）。
//
//  口径：候选的归一化键（标题剥离版本后缀 + 主艺人）命中曲库键集合 → 已下载。
//  曲库键读取走可注入闭包：生产环境读数据库，单测注入桩集合，无需真实曲库。
//

import Foundation

/// 「推荐条目是否已下载」的唯一判定状态。
struct RecommendationDownloadedIndex: Sendable {
    /// 曲库键读取器（生产 = 数据库读；单测可注入）。
    typealias LibraryKeysLoader = @Sendable () async -> Set<String>

    private(set) var keys: Set<String>
    private let loadKeys: LibraryKeysLoader

    init(
        keys: Set<String> = [],
        loadKeys: @escaping LibraryKeysLoader = { await RecommendationV3DataSource.loadLibraryKeys() }
    ) {
        self.keys = keys
        self.loadKeys = loadKeys
    }

    /// 候选是否已在曲库（含本会话刚从推荐页下载完成、已落库的）。
    func isDownloaded(title: String, artist: String) -> Bool {
        let key = RecommendationLibraryMatcher.key(title: title, artist: artist)
        guard !key.isEmpty else { return false }
        return keys.contains(key)
    }

    /// 直接替换键集合（生成画像时一次性赋值，省一次 DB 读）。
    mutating func replaceKeys(_ newKeys: Set<String>) {
        keys = newKeys
    }

    /// 用最新曲库键构造新状态（值语义：调用方整体赋值）。
    /// 不做 `mutating async`——actor 隔离下对属性写回跨 await 不安全（编译器禁止）。
    func refreshed() async -> RecommendationDownloadedIndex {
        RecommendationDownloadedIndex(keys: await loadKeys(), loadKeys: loadKeys)
    }
}
