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
/// 已下载判定的注入面（`MacRecommendationModel` 只依赖这个协议，单测可换桩）。
protocol RecommendationDownloadedIndexProviding: Sendable {
    /// 候选是否已在曲库（多键口径：多艺人 / 版本后缀 / 繁简都算）。
    func isDownloaded(title: String, artist: String) -> Bool
    /// 用给定曲库键集合替换（生成画像时一次性赋值，省一次 DB 读）。
    func withKeys(_ keys: Set<String>) -> any RecommendationDownloadedIndexProviding
    /// 重新读一次曲库键（下载落库 / 扫描收尾后调用）。
    /// 与具体类型上的 `refreshed()` 同语义，只多一层协议擦除（注入面用）。
    func refreshedIndex() async -> any RecommendationDownloadedIndexProviding
}

struct RecommendationDownloadedIndex: RecommendationDownloadedIndexProviding, Sendable {
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
        let matchKeys = RecommendationLibraryMatcher.keys(title: title, artist: artist)
        guard !matchKeys.isEmpty else { return false }
        return RecommendationLibraryMatcher.matches(matchKeys, libraryKeys: keys)
    }

    /// 直接替换键集合（生成画像时一次性赋值，省一次 DB 读）。
    mutating func replaceKeys(_ newKeys: Set<String>) {
        keys = newKeys
    }

    /// 协议入口（值语义，返回新实例；调用方整体赋值）。
    func withKeys(_ keys: Set<String>) -> any RecommendationDownloadedIndexProviding {
        RecommendationDownloadedIndex(keys: keys, loadKeys: loadKeys)
    }

    /// 用最新曲库键构造新状态（值语义：调用方整体赋值）。
    /// 不做 `mutating async`——actor 隔离下对属性写回跨 await 不安全（编译器禁止）。
    func refreshed() async -> RecommendationDownloadedIndex {
        RecommendationDownloadedIndex(keys: await loadKeys(), loadKeys: loadKeys)
    }

    func refreshedIndex() async -> any RecommendationDownloadedIndexProviding {
        await refreshed()
    }
}
