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
//  2026-09-19 去掉全部墙钟断言：超时兜底的计时改由注入式假钟（IndexingWaitSleeping）
//  驱动。原因：本文件原用 `elapsed < 60` 兼容 CI 模拟器的定时器节流（放宽过两次：
//  549f1bb / d1ac406），run 35334674871 实测 69.03s 仍被击穿；既然墙钟只反映 runner
//  饿不饿，就不该当断言依据（同族先例：50cf089「T9 超时用例去掉墙钟阈值断言」）。
//

import Combine
import Foundation
import Testing

@testable import QQPlayer

/// 假状态源：不触碰 DatabaseManager 单例
@MainActor
private final class FakeIndexingSource: IndexingStateProviding {
    @Published var isIndexing: Bool
    /// 曲库索引终态事实（默认 false = 与生产同一 fail-closed 口径）
    @Published var hasReachedIndexingTerminalState: Bool

    init(isIndexing: Bool, hasReachedIndexingTerminalState: Bool = false) {
        self.isIndexing = isIndexing
        self.hasReachedIndexingTerminalState = hasReachedIndexingTerminalState
    }

    var isIndexingPublisher: AnyPublisher<Bool, Never> {
        $isIndexing.eraseToAnyPublisher()
    }

    var indexingTerminalStatePublisher: AnyPublisher<Void, Never> {
        $hasReachedIndexingTerminalState.map { _ in () }.eraseToAnyPublisher()
    }
}

// MARK: - 假「睡」（测试 seam，取代墙钟）

/// 立即到点：等价于「policy 超时时间已到」，与本机耗时无关。
private struct ImmediateSleeper: IndexingWaitSleeping {
    func sleep(nanoseconds: UInt64) async {}
}

/// 永不到点：等价于「超时永远不触发」，于是唯一能放行的只有状态翻转。
/// 用 24h 而不是永久挂起的 continuation：不泄 continuation，且可被取消。
private struct NeverSleeper: IndexingWaitSleeping {
    func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: 86_400_000_000_000) // 24h
    }
}

/// 记录「被要求睡多久」的假钟（不真睡）：锁「超时兜底用的是 policy 的纳秒值」这条接线。
/// 用 actor 而非 NSLock：Swift 6 禁止在 async 上下文调 `NSLock.lock/unlock`。
private actor RecordingSleeper: IndexingWaitSleeping {
    private var recorded: [UInt64] = []

    func sleep(nanoseconds: UInt64) async {
        recorded.append(nanoseconds)
    }

    var requested: [UInt64] { recorded }
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

    // MARK: - changeLog 同步前置门（唯一判定）

    @Test("前置门：曲库索引未到终态 → 不放行（安装后第一次冷启动，track 表还空着）")
    func gateBlocksWithoutTerminalState() {
        let source = FakeIndexingSource(isIndexing: false, hasReachedIndexingTerminalState: false)
        #expect(IndexingGate.isReadyForChangeLogSync(source) == false)
    }

    @Test("前置门：索引在跑 → 不放行（哪怕终态事实已成立，重扫中途也不放）")
    func gateBlocksWhileIndexing() {
        let source = FakeIndexingSource(isIndexing: true, hasReachedIndexingTerminalState: true)
        #expect(IndexingGate.isReadyForChangeLogSync(source) == false)
    }

    @Test("前置门：终态成立且不在跑 → 放行")
    func gateOpensWhenTerminalAndIdle() {
        let source = FakeIndexingSource(isIndexing: false, hasReachedIndexingTerminalState: true)
        #expect(IndexingGate.isReadyForChangeLogSync(source) == true)
    }

    // MARK: - 等待

    @Test("索引没在跑 → 立即返回 alreadyIdle")
    func alreadyIdleReturnsImmediately() async {
        let source = FakeIndexingSource(isIndexing: false)
        let outcome = await IndexingGate.waitUntilIdle(
            source,
            policy: IndexingWaitPolicy(timeout: 5),
            sleeper: ImmediateSleeper()
        )
        #expect(outcome == .alreadyIdle)
    }

    @Test("索引正常结束 → finished（由状态翻转发起，非超时）")
    func finishesWhenIndexingStops() async {
        let source = FakeIndexingSource(isIndexing: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            source.isIndexing = false
        }
        // 假钟永不到点 → 唯一放行来源是状态翻转：即使 CI 把 30ms 拉长到几十秒，
        // 结果也必是 .finished（不会再出现「超时抢在翻转前放行」的同族 flake）。
        let outcome = await IndexingGate.waitUntilIdle(
            source,
            policy: IndexingWaitPolicy(timeout: 5),
            sleeper: NeverSleeper()
        )
        #expect(outcome == .finished)
    }

    @Test("索引永不回落 → 超时放行 timedOut（修复前会永久挂起/忙等）")
    func timesOutWhenIndexingNeverEnds() async {
        let source = FakeIndexingSource(isIndexing: true)
        // 假钟立即到点 = policy 超时时间已到；断言只锁结果，不锁墙钟。
        let outcome = await IndexingGate.waitUntilIdle(
            source,
            policy: IndexingWaitPolicy(timeout: 0.2),
            sleeper: ImmediateSleeper()
        )
        #expect(outcome == .timedOut)
    }

    @Test("超时兜底用的是 policy 的纳秒值（接线契约，不靠墙钟）")
    func timeoutUsesPolicyNanoseconds() async {
        let source = FakeIndexingSource(isIndexing: true)
        let sleeper = RecordingSleeper()
        let outcome = await IndexingGate.waitUntilIdle(
            source,
            policy: IndexingWaitPolicy(timeout: 0.2),
            sleeper: sleeper
        )
        #expect(outcome == .timedOut)
        let requested = await sleeper.requested
        #expect(requested == [200_000_000])
    }

    @Test("超时后索引才回落也不再重复唤醒（resume 只发生一次）")
    func resumeHappensOnce() async {
        let source = FakeIndexingSource(isIndexing: true)
        let outcome = await IndexingGate.waitUntilIdle(
            source,
            policy: IndexingWaitPolicy(timeout: 0.05),
            sleeper: ImmediateSleeper()
        )
        #expect(outcome == .timedOut)

        // 迟到的状态翻转不应再触发第二次 resume（否则 CheckedContinuation 会崩）
        source.isIndexing = false
        source.isIndexing = true
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(source.isIndexing == true)
    }
}
