//
//  RecommendationResultCacheTests.swift
//  QQPlayerTests
//
//  推荐结果缓存（P3）纯逻辑单测：键 / 命中 / TTL / LRU / 损坏文件 / 手动刷新。
//
//  缓存实现位于共享层（QQPlayer/Services/RecommendationResultCache.swift），
//  测试全部注入临时目录 + 可注入时钟，不碰真实 App Support。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

private final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func read() -> Date {
        now
    }
}

private func makeKey(
    rawText: String = "",
    profile: String = "artists=五月天;decades=2000:0.5000",
    library: String = "lib-1",
    planner: RecommendationPlanSource = .rule,
    model: String = "none",
    locale: String = "zh-Hans"
) -> RecommendationCacheKeyInput {
    RecommendationCacheKeyInput(
        rawText: rawText,
        profileSummary: profile,
        libraryFingerprint: library,
        planner: planner,
        modelIdentity: model,
        localeIdentifier: locale
    )
}

private func makeCandidate(_ title: String) -> RecommendedCandidate {
    RecommendedCandidate(
        title: title,
        artist: "artist",
        album: "album",
        year: 2004,
        source: .netease,
        score: 0.8,
        reasons: ["reason"]
    )
}

private func makeCache(
    _ clock: TestClock
) -> (cache: RecommendationResultCache, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("recommendation-cache-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = RecommendationResultCache(directory: directory, clock: clock.read)
    return (cache, directory)
}

// MARK: - 键

@Suite("RecommendationCacheKey")
struct RecommendationCacheKeyTests {
    @Test("同输入 → 同键；空白与大小写归一化")
    func normalization() {
        let base = makeKey(rawText: "  五月天  类似  ")
        let variant = makeKey(rawText: "五月天 类似")
        let upper = makeKey(rawText: "Mayday  Similar")
        let upperVariant = makeKey(rawText: "  mayday similar ")
        #expect(base.sha256 == variant.sha256)
        #expect(upper.sha256 == upperVariant.sha256)
        #expect(base.sha256 != upper.sha256)
    }

    @Test("任一输入变化 → 换键（含 planner / 模型 / locale / 曲库指纹）")
    func sensitivity() {
        let base = makeKey()
        #expect(base.sha256 != makeKey(rawText: "周杰伦").sha256)
        #expect(base.sha256 != makeKey(profile: "artists=其他").sha256)
        #expect(base.sha256 != makeKey(library: "lib-2").sha256)
        #expect(base.sha256 != makeKey(planner: .localModel, model: "qwen#1").sha256)
        #expect(base.sha256 != makeKey(model: "qwen#1").sha256)
        #expect(base.sha256 != makeKey(locale: "en").sha256)
    }

    @Test("规则与本地模型不串键")
    func plannerIsolation() {
        let rule = makeKey(planner: .rule)
        let model = makeKey(planner: .localModel, model: "qwen#1")
        #expect(rule.sha256 != model.sha256)
    }
}

// MARK: - 指纹

@Suite("RecommendationLibraryFingerprint")
struct RecommendationLibraryFingerprintTests {
    @Test("输入顺序不影响指纹")
    func orderIndependent() {
        let a = RecommendationLibraryFingerprint.make(stableIds: ["b", "a", "c"], latestModificationMicros: 10)
        let b = RecommendationLibraryFingerprint.make(stableIds: ["c", "b", "a"], latestModificationMicros: 10)
        #expect(a == b)
    }

    @Test("增删 / 时间变化 → 指纹变化")
    func changes() {
        let base = RecommendationLibraryFingerprint.make(stableIds: ["a", "b"], latestModificationMicros: 10)
        let added = RecommendationLibraryFingerprint.make(stableIds: ["a", "b", "c"], latestModificationMicros: 20)
        let removed = RecommendationLibraryFingerprint.make(stableIds: ["a"], latestModificationMicros: 10)
        #expect(base != added)
        #expect(base != removed)
    }
}

// MARK: - 存储语义

@Suite("RecommendationResultCache")
struct RecommendationResultCacheTests {
    @Test("未命中返回 nil")
    func miss() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (cache, _) = makeCache(clock)
        #expect(cache.load(makeKey()) == nil)
    }

    @Test("写入后命中：结果一致、hitCount 递增、lastAccess 刷新")
    func hit() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let (cache, _) = makeCache(clock)
        let key = makeKey()
        let list = [makeCandidate("a"), makeCandidate("b")]
        #expect(cache.store(key, planSource: .rule, candidates: list))

        let first = cache.load(key)
        #expect(first?.candidates == list)
        #expect(first?.createdAt == start)
        #expect(first?.hitCount == 1)

        clock.now = start.addingTimeInterval(600)
        let second = cache.load(key)
        #expect(second?.hitCount == 2)
    }

    @Test("空结果不缓存")
    func emptyNotStored() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (cache, _) = makeCache(clock)
        let key = makeKey()
        #expect(cache.store(key, planSource: .rule, candidates: []) == false)
        #expect(cache.load(key) == nil)
        #expect(cache.entryCount() == 0)
    }

    @Test("TTL 24h 过期 → miss 且删除文件")
    func ttlExpiry() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let (cache, _) = makeCache(clock)
        let key = makeKey()
        #expect(cache.store(key, planSource: .rule, candidates: [makeCandidate("a")]))
        #expect(cache.entryCount() == 1)

        clock.now = start.addingTimeInterval(RecommendationResultCache.ttl + 1)
        #expect(cache.load(key) == nil)
        #expect(cache.entryCount() == 0)
    }

    @Test("LRU：写第 21 条时淘汰最久未访问")
    func lruEviction() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let (cache, _) = makeCache(clock)

        var keys: [RecommendationCacheKeyInput] = []
        for index in 0 ..< 21 {
            clock.now = start.addingTimeInterval(TimeInterval(index))
            let key = makeKey(rawText: "q\(index)")
            keys.append(key)
            #expect(cache.store(key, planSource: .rule, candidates: [makeCandidate("t\(index)")]))
        }
        #expect(cache.entryCount() == RecommendationResultCache.maxEntryCount)
        #expect(cache.load(keys[0]) == nil)
        #expect(cache.load(keys[1]) != nil)
        #expect(cache.load(keys[20]) != nil)
    }

    @Test("损坏 JSON → miss 且删除，不崩溃")
    func corruptFile() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (cache, directory) = makeCache(clock)
        let key = makeKey()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(key.sha256).json")
        try Data("not json".utf8).write(to: url)

        #expect(cache.load(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("schemaVersion 不匹配 → miss 且删除")
    func schemaMismatch() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (cache, directory) = makeCache(clock)
        let key = makeKey()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(key.sha256).json")
        let encoder = JSONEncoder()
        let entry = RecommendationCacheEntry(
            schemaVersion: RecommendationResultCache.schemaVersion + 1,
            createdAt: clock.now,
            lastAccessedAt: clock.now,
            hitCount: 0,
            planSource: .rule,
            keySummary: RecommendationCacheKeySummary(input: key),
            candidates: [makeCandidate("a")],
            requestedArtist: nil
        )
        try encoder.encode(entry).write(to: url)

        #expect(cache.load(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("手动刷新：invalidate 后同键 miss")
    func invalidate() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (cache, _) = makeCache(clock)
        let key = makeKey()
        #expect(cache.store(key, planSource: .rule, candidates: [makeCandidate("a")]))
        #expect(cache.load(key) != nil)
        cache.invalidate(key)
        #expect(cache.load(key) == nil)
    }

    @Test("手动刷新：invalidate 后重算覆盖，createdAt 更新")
    func refreshOverwrite() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let (cache, _) = makeCache(clock)
        let key = makeKey()
        #expect(cache.store(key, planSource: .rule, candidates: [makeCandidate("old")]))

        cache.invalidate(key)
        clock.now = start.addingTimeInterval(3600)
        #expect(cache.store(key, planSource: .rule, candidates: [makeCandidate("new")]))

        let hit = cache.load(key)
        #expect(hit?.candidates == [makeCandidate("new")])
        #expect(hit?.createdAt == start.addingTimeInterval(3600))
        #expect(cache.entryCount() == 1)
    }

    @Test("曲库指纹变化 → 同请求不同键 → miss")
    func fingerprintChange() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (cache, _) = makeCache(clock)
        let before = makeKey(library: "lib-before")
        let after = makeKey(library: "lib-after")
        #expect(cache.store(before, planSource: .rule, candidates: [makeCandidate("a")]))
        #expect(cache.load(after) == nil)
    }
}
