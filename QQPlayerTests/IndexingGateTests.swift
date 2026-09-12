//
//  IndexingGateTests.swift
//  QQPlayerTests
//
//  审计 B5 · 🟡-2 / 🟡-3 回归：
//   - 等索引结束只有一套实现（IndexingGate），无 while+sleep 忙等
//   - 等待必须带超时兜底：索引异常时同步流程照常放行，而不是永久挂起
//
//  修复前必红的原因：修复前不存在 IndexingGate（ContentView 忙等、
//  LibraryView 裸 continuation 各自为政），本文件无法编译；此外"超时后放行"
//  在裸 continuation 实现下根本不存在——旧实现里 isIndexing 不回落就永不 resume。
//

import Combine
import Foundation
import Testing

@testable import QQPlayer

/// 假状态源：不触碰 DatabaseManager 单例
@MainActor
private final class FakeIndexingSource: IndexingStateProviding {
    @Published var isIndexing: Bool

    init(isIndexing: Bool) {
        self.isIndexing = isIndexing
    }

    var isIndexingPublisher: AnyPublisher<Bool, Never> {
        $isIndexing.eraseToAnyPublisher()
    }
}

@MainActor
struct IndexingGateTests {
    // MARK: - 策略（纯逻辑）

    @Test("策略：未到上限继续等待")
    func policyKeepsWaitingBeforeTimeout() {
        let policy = IndexingWaitPolicy(timeout: 10)
        #expect(policy.shouldStopWaiting(elapsed: 9.99) == false)
    }

    @Test("策略：到达上限即放行（边界 >=）")
    func policyStopsAtTimeout() {
        let policy = IndexingWaitPolicy(timeout: 10)
        #expect(policy.shouldStopWaiting(elapsed: 10) == true)
        #expect(policy.shouldStopWaiting(elapsed: 11) == true)
    }

    @Test("策略：默认 300s；纳秒换算正确")
    func policyDefaults() {
        #expect(IndexingWaitPolicy.standard.timeout == 300)
        #expect(IndexingWaitPolicy(timeout: 1.5).timeoutNanoseconds == 1_500_000_000)
        #expect(IndexingWaitPolicy(timeout: 0).timeoutNanoseconds == 0)
        #expect(IndexingWaitPolicy(timeout: -5).timeoutNanoseconds == 0)
    }

    // MARK: - 等待

    @Test("索引没在跑 → 立即返回 alreadyIdle")
    func alreadyIdleReturnsImmediately() async {
        let source = FakeIndexingSource(isIndexing: false)
        let outcome = await IndexingGate.waitUntilIdle(source, policy: IndexingWaitPolicy(timeout: 5))
        #expect(outcome == .alreadyIdle)
    }

    @Test("索引正常结束 → finished（由状态翻转发起，非超时）")
    func finishesWhenIndexingStops() async {
        let source = FakeIndexingSource(isIndexing: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            source.isIndexing = false
        }
        let outcome = await IndexingGate.waitUntilIdle(source, policy: IndexingWaitPolicy(timeout: 5))
        #expect(outcome == .finished)
    }

    @Test("索引永不回落 → 超时放行 timedOut（修复前会永久挂起/忙等）")
    func timesOutWhenIndexingNeverEnds() async {
        let source = FakeIndexingSource(isIndexing: true)
        let started = Date()
        let outcome = await IndexingGate.waitUntilIdle(source, policy: IndexingWaitPolicy(timeout: 0.2))
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome == .timedOut)
        #expect(elapsed >= 0.15)
        #expect(elapsed < 5)
    }

    @Test("超时后索引才回落也不再重复唤醒（resume 只发生一次）")
    func resumeHappensOnce() async {
        let source = FakeIndexingSource(isIndexing: true)
        let outcome = await IndexingGate.waitUntilIdle(source, policy: IndexingWaitPolicy(timeout: 0.05))
        #expect(outcome == .timedOut)

        // 迟到的状态翻转不应再触发第二次 resume（否则 CheckedContinuation 会崩）
        source.isIndexing = false
        source.isIndexing = true
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(source.isIndexing == true)
    }
}
