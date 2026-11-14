//
//  RecommendationDownloadedIndexTests.swift
//  QQPlayerTests
//
//  推荐 v3：已下载判定状态（下载落库 → 刷新 → 条目变为已下载样式）。
//  曲库读取用可注入桩，不依赖真实数据库。
//

import Foundation
@testable import QQPlayer
import Testing

private actor LibraryKeysStub {
    private var keys: Set<String>

    init(keys: Set<String> = []) {
        self.keys = keys
    }

    func set(_ newKeys: Set<String>) {
        keys = newKeys
    }

    func load() -> Set<String> {
        keys
    }
}

@Suite("推荐 v3：已下载索引")
struct RecommendationDownloadedIndexTests {
    private static func key(_ title: String, _ artist: String) -> String {
        RecommendationLibraryMatcher.key(title: title, artist: artist)
    }

    @Test("初始键集合为空 → 未下载")
    func emptyIsNotDownloaded() {
        let index = RecommendationDownloadedIndex(keys: [])
        #expect(!index.isDownloaded(title: "晴天", artist: "周杰伦"))
    }

    @Test("刷新读到刚落库的曲库键 → 立即变为已下载")
    func refreshPicksUpNewlyLandedTrack() async {
        let stub = LibraryKeysStub()
        var index = RecommendationDownloadedIndex(loadKeys: { await stub.load() })
        #expect(!index.isDownloaded(title: "晴天", artist: "周杰伦"))

        await stub.set([Self.key("晴天", "周杰伦")])
        index = await index.refreshed()

        #expect(index.isDownloaded(title: "晴天", artist: "周杰伦"))
    }

    @Test("归一化口径：候选带版本后缀 / feat. 也命中曲库主键")
    func normalizationMatchesLibraryKey() async {
        let stub = LibraryKeysStub(keys: [Self.key("晴天", "周杰伦")])
        var index = RecommendationDownloadedIndex(loadKeys: { await stub.load() })
        index = await index.refreshed()
        #expect(index.isDownloaded(title: "晴天 (Live)", artist: "周杰伦 feat. 杨瑞代"))
    }

    @Test("replaceKeys：下一次生成换新集合，曲库清掉后回退为未下载")
    func replaceKeysOverridesPreviousState() {
        var index = RecommendationDownloadedIndex(keys: [Self.key("晴天", "周杰伦")])
        #expect(index.isDownloaded(title: "晴天", artist: "周杰伦"))
        index.replaceKeys([])
        #expect(!index.isDownloaded(title: "晴天", artist: "周杰伦"))
    }

    @Test("标题与艺人都为空 → 永不算已下载")
    func emptyTitleAndArtistNeverDownloaded() {
        let index = RecommendationDownloadedIndex(keys: [""])
        #expect(!index.isDownloaded(title: "", artist: ""))
    }
}
