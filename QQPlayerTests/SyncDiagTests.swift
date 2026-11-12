//
//  SyncDiagTests.swift
//  QQPlayerTests
//
//  V1 同步诊断打点（`SyncDiagAttempt` / `SyncDiagStage` / NWError 映射）的契约测试：
//   - 阶段推进：假时钟下六段耗时**精确**落账
//   - 首个失败阶段锁定：后续阶段的 begin/end 不改判 failStage，且不再计时（-1）
//   - `NWError` → (failStage, domain, code) 映射：timeout / refused / dns / cancelled
//   - golden：汇总行字段顺序稳定、值内无空格、六段齐全（跳过也出现）
//   - 幂等：`finish()` 调 3 次只输出 1 行
//
//  时钟 / 出口都注入（`now` / `emit`），不用真实时间、不落盘，断言确定性。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("SyncDiag 一次尝试的量化诊断")
struct SyncDiagTests {
    // MARK: 载荷

    /// 阶段推进：假时钟下六段耗时精确匹配。
    @Test func 六段耗时按注入时钟精确落账() throws {
        let clock = FakeClock(1_000)
        let sink = LineSink()
        let attempt = makeAttempt(clock: clock, sink: sink, kind: .conn, candidates: 3)

        attempt.begin(.discover)
        clock.advance(12)
        attempt.end(.discover)
        attempt.begin(.dial)
        clock.advance(1_040)
        attempt.end(.dial)
        attempt.begin(.handshake)
        clock.advance(88)
        attempt.end(.handshake)
        attempt.begin(.negotiate)
        clock.advance(4)
        attempt.end(.negotiate)
        attempt.finish()

        let line = try #require(sink.lines.first)
        #expect(line.contains("d_discover=12"))
        #expect(line.contains("d_dial=1040"))
        #expect(line.contains("d_handshake=88"))
        #expect(line.contains("d_negotiate=4"))
        #expect(line.contains("d_transfer=-1"))
        #expect(line.contains("d_settle=-1"))
        #expect(line.contains("total=1144"))
        #expect(line.contains("ok=1"))
        #expect(line.contains("fail=none"))
    }

    /// 首个失败阶段锁定 + 后续阶段 skipped。
    @Test func 首个失败阶段锁定且后续阶段不再计时() throws {
        let clock = FakeClock(0)
        let sink = LineSink()
        let attempt = makeAttempt(clock: clock, sink: sink, kind: .conn)

        attempt.begin(.dial)
        clock.advance(30)
        attempt.fail(.dial, error: .posix(ECONNREFUSED))
        attempt.end(.dial)
        // 失败之后即便有事件推进，也不得改判失败阶段
        attempt.fail(.handshake, domain: "session", code: 4)
        attempt.begin(.handshake)
        clock.advance(5)
        attempt.end(.handshake)
        attempt.finish()

        let line = try #require(sink.lines.first)
        #expect(line.contains("ok=0"))
        #expect(line.contains("fail=dial"))
        #expect(line.contains("faildom=posix"))
        #expect(line.contains("failcode=61"))
        #expect(line.contains("d_dial=30"))
    }

    /// `NWError` → (阶段, domain, code)：timeout / refused / dns / cancelled。
    @Test func 传输层错误按原因归一到domain与code() throws {
        #expect(SyncDiagTransportError.posix(ETIMEDOUT).reason == "timeout")
        #expect(SyncDiagTransportError.posix(ECONNREFUSED).reason == "refused")
        #expect(SyncDiagTransportError.posix(ECANCELED).reason == "cancelled")
        #expect(SyncDiagTransportError.dns(-65554).reason == "dns")
        #expect(SyncDiagTransportError.tls(-9808).reason == "tls")
        #expect(SyncDiagTransportError.posix(9).reason == "other")

        let clock = FakeClock(0)
        let sink = LineSink()
        let dialFail = makeAttempt(clock: clock, sink: sink, kind: .conn)
        dialFail.fail(.dial, error: .dns(-65554))
        dialFail.finish()
        let dialLine = try #require(sink.lines.first)
        #expect(dialLine.contains("fail=dial"))
        #expect(dialLine.contains("faildom=dns"))
        #expect(dialLine.contains("failcode=-65554"))
    }

    /// 会话阶段 → 失败阶段归因（就绪前关闭才算连接失败）。
    @Test func 会话阶段归因只覆盖就绪前() {
        #expect(SyncPeerSession.diagStage(for: .idle) == .dial)
        #expect(SyncPeerSession.diagStage(for: .waitingForPeerHello) == .handshake)
        #expect(SyncPeerSession.diagStage(for: .waitingForPairRequest) == .negotiate)
        #expect(SyncPeerSession.diagStage(for: .waitingForPairApproval) == .negotiate)
        #expect(SyncPeerSession.diagStage(for: .waitingForPairResponse) == .negotiate)
        #expect(SyncPeerSession.diagStage(for: .ready) == nil)
        #expect(SyncPeerSession.diagStage(for: .closed) == nil)

        // 关闭原因码稳定（跨版本只增不改）
        #expect(SyncPeerSession.diagCloseCode(.userCancelled) == 1)
        #expect(SyncPeerSession.diagCloseCode(.handshakeTimeout) == 4)
        #expect(SyncPeerSession.diagCloseCode(.transportError) == 10)
    }

    /// golden：字段顺序固定、值内无空格、六段齐全。
    @Test func 汇总行字段顺序与形状稳定() throws {
        let clock = FakeClock(5_000)
        let sink = LineSink()
        let attempt = SyncDiagAttempt(
            attemptId: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!,
            kind: .run,
            role: "host",
            channel: .session,
            candidates: 0,
            peerDeviceID: "ABCDEFGHIJ",
            now: { clock.now() },
            emit: { sink.append($0) }
        )
        clock.advance(1_000)
        attempt.begin(.transfer)
        clock.advance(240)
        attempt.end(.transfer)
        attempt.begin(.settle)
        clock.advance(6)
        attempt.record(files: 2, bytes: 4_096)
        attempt.end(.settle)
        attempt.finish()

        let line = try #require(sink.lines.first)
        let expected = "SYNCDIAG v=1 kind=run id=00000000 role=host chan=session cand=0 "
            + "peer=ABCDEFGH ok=1 fail=none faildom=- failcode=0 "
            + "d_discover=-1 d_dial=-1 d_handshake=-1 d_negotiate=-1 d_transfer=240 d_settle=6 "
            + "total=1246 bytes=4096 files=2 "
            // INV-37（2026-11-12 T1）：链路事实 8 字段固定在行尾；未实测 = -1 / unknown。
            + "addr=-1 if=-1 link=unknown importing=0 pullSent=-1 pullRecv=-1 pullLate=-1 probeMBps=-1"
        #expect(line == expected)

        // 值内不得含空格：按空格切后每段要么是前缀，要么是 k=v 形式。
        let tokens = line.split(separator: " ")
        #expect(tokens.first == "SYNCDIAG")
        #expect(tokens.dropFirst().allSatisfy { $0.contains("=") })
        // 六段齐全（跳过也出现）
        for stage in SyncDiagStage.timed {
            #expect(tokens.contains { $0.hasPrefix("d_\(stage.rawValue)=") })
        }
    }

    /// 幂等：finish() 调 3 次只输出 1 行。
    @Test func finish幂等只输出一行() {
        let clock = FakeClock(0)
        let sink = LineSink()
        let attempt = makeAttempt(clock: clock, sink: sink, kind: .conn)
        attempt.begin(.dial)
        clock.advance(1)
        attempt.end(.dial)
        attempt.finish()
        attempt.finish()
        attempt.finish()
        #expect(sink.lines.count == 1)
    }

    /// 值净化：空白折成下划线（保证汇总行可切分）。
    @Test func 空白值折成下划线() {
        #expect(SyncDiagAttempt.token("hello world") == "hello_world")
        #expect(SyncDiagAttempt.token("a\tb\nc") == "a_b_c")
        #expect(SyncDiagAttempt.token("") == "-")
    }

    // MARK: 夹具

    private func makeAttempt(
        clock: FakeClock,
        sink: LineSink,
        kind: SyncDiagKind,
        candidates: Int = -1
    ) -> SyncDiagAttempt {
        SyncDiagAttempt(
            attemptId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: kind,
            role: "client",
            channel: .bonjour,
            candidates: candidates,
            now: { clock.now() },
            emit: { sink.append($0) }
        )
    }
}

/// 假时钟（毫秒）：测试里手动推进，断言精确耗时。
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) {
        self.value = start
    }

    func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ delta: Int64) {
        lock.lock()
        value += delta
        lock.unlock()
    }
}

/// 汇总行收集盒（避免在 @Sendable 出口里捕获可变局部变量）。
private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
