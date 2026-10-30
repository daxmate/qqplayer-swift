//
//  SyncPairingCodeTests.swift
//  QQPlayerTests
//
//  批 1（2026-10-30）6 位配对码纯逻辑：生成 / 校验 / 过期 / 重放 / 限速 / 比较。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncPairingCodeTests {
    /// 按序吐码的生成器（线程安全；只用于测试）
    final class CodeSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [String]

        init(values: [String]) {
            remaining = values
        }

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            return remaining.isEmpty ? "000000" : remaining.removeFirst()
        }
    }

    /// 可注入时钟（纯逻辑测试不碰真实时间）
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.now = now
        }
    }

    private func makeStore(
        clock: Clock,
        generator: @escaping @Sendable () -> String = { "123456" }
    ) -> SyncPairingCodeStore {
        SyncPairingCodeStore(now: { clock.now }, codeGenerator: generator)
    }

    // MARK: 生成

    @Test("生成：6 位数字、保留前导零、nonce 16B")
    func generateFormat() {
        let clock = Clock()
        let store = makeStore(clock: clock, generator: { "000123" })
        let issue = store.generate()
        #expect(issue.code == "000123")
        #expect(issue.nonce.count == 16)
        #expect(issue.expiresAt.timeIntervalSince(issue.issuedAt) == SyncPairingCodeStore.defaultTTL)
        #expect(store.activeCode == "000123")
    }

    @Test("生成：注入非法生成值 → 兜底为合法 6 位数字")
    func generateFallsBackOnBadGenerator() {
        let clock = Clock()
        let store = makeStore(clock: clock, generator: { "abc" })
        let issue = store.generate()
        #expect(issue.code.count == 6)
        #expect(issue.code.allSatisfy { $0.isNumber })
    }

    @Test("生成新码即作废旧码（同一时刻只有一张有效码）")
    func regenerateInvalidatesOldCode() {
        let clock = Clock()
        // 码生成器按序产出两张不同的码（固定生成器会让新旧码文本相同，测不出「旧码失效」）
        let codes = CodeSequence(values: ["111111", "222222"])
        let store = makeStore(clock: clock, generator: { codes.next() })
        let first = store.generate()
        let second = store.generate()
        #expect(first.code != second.code || first.nonce != second.nonce)
        #expect(store.activeCode == second.code)
        if case let .failure(failure) = store.verify(code: first.code, peerID: "PEER") {
            #expect(failure == .mismatch)
        } else {
            Issue.record("旧码应失效")
        }
    }

    // MARK: 校验

    @Test("校验：正确码返回关联 nonce，且单次使用（重放 → alreadyUsed）")
    func verifySuccessIsSingleUse() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        let issue = store.generate()
        switch store.verify(code: issue.code, peerID: "PEER") {
        case let .success(nonce):
            #expect(nonce == issue.nonce)
        case let .failure(failure):
            Issue.record("应通过，实际 \(failure)")
        }
        if case let .failure(failure) = store.verify(code: issue.code, peerID: "PEER") {
            #expect(failure == .alreadyUsed)
        } else {
            Issue.record("重放应被拒")
        }
    }

    @Test("校验：错误码 → mismatch，并累计失败次数")
    func verifyMismatchRecordsFailure() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        _ = store.generate()
        if case let .failure(failure) = store.verify(code: "654321", peerID: "PEER") {
            #expect(failure == .mismatch)
        } else {
            Issue.record("错码应被拒")
        }
        #expect(store.failureCount(peerID: "PEER") == 1)
        // 成功之后清空该对端失败计数
        _ = store.verify(code: "123456", peerID: "PEER")
        #expect(store.failureCount(peerID: "PEER") == 0)
    }

    @Test("校验：从未生成 → noActiveCode；过期 → expired")
    func verifyNoActiveVsExpired() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        if case let .failure(failure) = store.verify(code: "123456", peerID: "PEER") {
            #expect(failure == .noActiveCode)
        } else {
            Issue.record("无码应被拒")
        }
        _ = store.generate()
        clock.now = clock.now.addingTimeInterval(SyncPairingCodeStore.defaultTTL + 1)
        #expect(store.activeCode == nil)
        if case let .failure(failure) = store.verify(code: "123456", peerID: "PEER") {
            #expect(failure == .expired)
        } else {
            Issue.record("过期码应被拒")
        }
    }

    @Test("校验：输入容忍空白 / 分隔符（123 456 → 123456）")
    func verifyAcceptsFormattedInput() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        _ = store.generate()
        if case .failure(let failure) = store.verify(code: "123 456", peerID: "PEER") {
            Issue.record("应通过，实际 \(failure)")
        }
    }

    // MARK: 限速

    @Test("限速：同对端 5 次失败后，正确码也拒绝；窗口过后恢复")
    func rateLimitPerPeer() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        _ = store.generate()
        for _ in 0 ..< SyncPairingCodeStore.defaultMaxFailures {
            _ = store.verify(code: "000000", peerID: "PEER")
        }
        if case let .failure(failure) = store.verify(code: "123456", peerID: "PEER") {
            #expect(failure == .rateLimited)
        } else {
            Issue.record("超限应被拒")
        }
        // 另一个对端不受影响
        if case let .failure(failure) = store.verify(code: "123456", peerID: "OTHER") {
            Issue.record("其它对端不应被限速，实际 \(failure)")
        }
        // 窗口过后恢复（换一张新码，避开「已用」）
        clock.now = clock.now.addingTimeInterval(SyncPairingCodeStore.defaultFailureWindow + 1)
        _ = store.generate()
        if case let .failure(failure) = store.verify(code: "123456", peerID: "PEER") {
            Issue.record("窗口过后应恢复，实际 \(failure)")
        }
    }

    @Test("作废：cancel 后既无 activeCode 也按 noActiveCode 拒绝")
    func cancelClearsCode() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        _ = store.generate()
        store.cancel()
        #expect(store.activeCode == nil)
        #expect(store.activeExpiry == nil)
        if case let .failure(failure) = store.verify(code: "123456", peerID: "PEER") {
            #expect(failure == .noActiveCode)
        } else {
            Issue.record("作废后应被拒")
        }
    }

    // MARK: 纯工具

    @Test("常量时间比较：等长才可能相等，且逐字节判定")
    func constantTimeEquals() {
        #expect(SyncPairingCodeStore.constantTimeEquals("123456", "123456"))
        #expect(!SyncPairingCodeStore.constantTimeEquals("123456", "123457"))
        #expect(!SyncPairingCodeStore.constantTimeEquals("12345", "123456"))
        #expect(!SyncPairingCodeStore.constantTimeEquals("", "0"))
    }

    @Test("展示与归一：分组展示 / 非法输入返回 nil")
    func formattingAndNormalization() {
        #expect(SyncPairingCodeStore.formatted("123456") == "123 456")
        #expect(SyncPairingCodeStore.formatted("12345") == "12345")
        #expect(SyncPairingCodeStore.normalizedInput(" 123-456 ") == "123456")
        #expect(SyncPairingCodeStore.normalizedInput("12345") == nil)
        #expect(SyncPairingCodeStore.normalizedInput("12345a") == nil)
    }
}
