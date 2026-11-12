//
//  RecommendationCacheFlowTests.swift
//  QQPlayerTests
//
//  推荐缓存编排（stale 优先 / 后台重算 / 手动刷新）单测：
//  「模型层」的时序逻辑放在共享的 RecommendationCacheFlow 里，这里直接测它，
//  Mac 模型只负责把回调结果映射到 UI 状态（无 Mac 测试 target，故不上移到模型类）。
//
//  全部注入临时目录 + 可注入时钟，不碰真实 App Support / 曲库。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

private final class FlowClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func read() -> Date {
        now
    }
}

private func flowKey(
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

private func flowCandidate(_ title: String) -> RecommendedCandidate {
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

@MainActor
private func makeFlow(
    _ clock: FlowClock
) -> (flow: RecommendationCacheFlow, cache: RecommendationResultCache) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("recommendation-flow-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = RecommendationResultCache(directory: directory, clock: clock.read)
    let flow = RecommendationCacheFlow(cache: cache, clock: clock.read)
    return (flow, cache)
}

/// 让后台重算「停在半路」，用来观察重算期间的可见状态。
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func open() {
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, attempts: Int = 400) async {
    for _ in 0 ..< attempts where !condition() {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

// MARK: - 编排

@MainActor
@Suite("推荐缓存编排")
struct RecommendationCacheFlowTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("曲库指纹变化 → exact miss、stale hit，返回旧候选")
    func staleHitAfterFingerprintChange() {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        let old = flowKey(library: "lib-before")
        #expect(cache.store(old, planSource: .rule, candidates: [flowCandidate("old")]))

        let new = flowKey(library: "lib-after")
        guard case let .stale(hit) = flow.lookup(new, bypassCache: false) else {
            Issue.record("指纹变化后应命中 stale")
            return
        }
        #expect(hit.isStale)
        #expect(hit.candidates.map(\.title) == ["old"])
        #expect(hit.createdAt == start)
    }

    @Test("exact 命中优先于 stale")
    func exactBeatsStale() {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        let key = flowKey()
        #expect(cache.store(key, planSource: .rule, candidates: [flowCandidate("exact")]))

        // 再写一条同 baseKey 的更老条目，确保 exact 仍然优先
        clock.now = start.addingTimeInterval(60)
        #expect(cache.store(flowKey(profile: "older"), planSource: .rule, candidates: [flowCandidate("stale")]))

        guard case let .exact(hit) = flow.lookup(key, bypassCache: false) else {
            Issue.record("同键应 exact 命中")
            return
        }
        #expect(hit.candidates.map(\.title) == ["exact"])
        #expect(hit.isStale == false)
    }

    @Test("手动刷新（bypass）不读 stale，并清掉同 baseKey 的旧条目")
    func bypassSkipsStale() {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        #expect(cache.store(flowKey(library: "lib-before"), planSource: .rule, candidates: [flowCandidate("old")]))

        let key = flowKey(library: "lib-after")
        #expect(flow.lookup(key, bypassCache: true) == .miss)
        #expect(cache.loadStale(baseKey: key.baseKey, now: clock.now) == nil)
    }

    @Test("stale 超过 7 天 → miss")
    func staleExpired() {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        #expect(cache.store(flowKey(library: "lib-before"), planSource: .rule, candidates: [flowCandidate("old")]))

        clock.now = start.addingTimeInterval(RecommendationResultCache.staleMaxAge + 1)
        let key = flowKey(library: "lib-after")
        #expect(flow.lookup(key, bypassCache: false) == .miss)
    }

    @Test("后台重算完成 → 候选替换 + 写回新精确键")
    func backgroundRefreshReplacesCandidates() async {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        let oldKey = flowKey(library: "lib-before")
        #expect(cache.store(oldKey, planSource: .rule, candidates: [flowCandidate("old")]))

        let key = flowKey(library: "lib-after")
        guard case let .stale(stale) = flow.lookup(key, bypassCache: false) else {
            Issue.record("应命中 stale")
            return
        }

        let gate = Gate()
        var applied: RecommendationRecompute?
        var appliedChanged: Bool?
        flow.startBackgroundRefresh(
            token: flow.beginRequest(),
            key: key,
            currentCandidates: stale.candidates
        ) {
            await gate.wait()
            return RecommendationRecompute(
                candidates: [flowCandidate("new")],
                planSource: .rule,
                requestedArtist: nil
            )
        } apply: { recompute, changed in
            applied = recompute
            appliedChanged = changed
        }

        await waitUntil { gate.isWaiting }
        #expect(applied == nil) // 重算期间不替换：旧候选仍可见

        gate.open()
        await waitUntil { applied != nil }
        #expect(applied?.candidates.map(\.title) == ["new"])
        #expect(appliedChanged == true)
        #expect(cache.load(key)?.candidates.map(\.title) == ["new"])
    }

    @Test("结果与当前展示一致 → changed = false（不抖 UI）")
    func unchangedResultMarksNotChanged() async {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        #expect(cache.store(flowKey(library: "lib-before"), planSource: .rule, candidates: [flowCandidate("same")]))

        let key = flowKey(library: "lib-after")
        guard case let .stale(stale) = flow.lookup(key, bypassCache: false) else {
            Issue.record("应命中 stale")
            return
        }

        let gate = Gate()
        var appliedChanged: Bool?
        flow.startBackgroundRefresh(
            token: flow.beginRequest(),
            key: key,
            currentCandidates: stale.candidates
        ) {
            await gate.wait()
            return RecommendationRecompute(
                candidates: [flowCandidate("same")],
                planSource: .rule,
                requestedArtist: nil
            )
        } apply: { _, changed in
            appliedChanged = changed
        }

        await waitUntil { gate.isWaiting }
        gate.open()
        await waitUntil { appliedChanged != nil }
        #expect(appliedChanged == false)
        // 相同序列也要写回新键（下一次请求精确命中）
        #expect(cache.load(key) != nil)
    }

    @Test("新请求作废旧后台任务：旧结果不回写、不覆盖新结果")
    func staleBackgroundDiscarded() async {
        let clock = FlowClock(start)
        let (flow, cache) = makeFlow(clock)
        #expect(cache.store(flowKey(library: "lib-before"), planSource: .rule, candidates: [flowCandidate("old")]))

        let key = flowKey(library: "lib-after")
        guard case let .stale(stale) = flow.lookup(key, bypassCache: false) else {
            Issue.record("应命中 stale")
            return
        }

        let gate = Gate()
        var applied = false
        flow.startBackgroundRefresh(
            token: flow.beginRequest(),
            key: key,
            currentCandidates: stale.candidates
        ) {
            await gate.wait()
            return RecommendationRecompute(
                candidates: [flowCandidate("stale-task")],
                planSource: .rule,
                requestedArtist: nil
            )
        } apply: { _, _ in
            applied = true
        }

        await waitUntil { gate.isWaiting }
        _ = flow.beginRequest() // 新请求到来：旧任务作废
        gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(applied == false)
        #expect(cache.load(key) == nil)
    }
}
