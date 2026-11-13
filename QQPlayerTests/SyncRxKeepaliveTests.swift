//
//  SyncRxKeepaliveTests.swift
//  QQPlayerTests
//
//  接收端上行 keep-alive 的判据单测（Sync/SyncRxKeepalive.swift）。
//  只测纯函数与「启停状态」——真实 30ms 节奏涉及定时器时序，不在单测里等墙上时间
//  （会变成 flaky；节奏与停机的真实验证走真机日志 keepalive start/stop 两行）。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncRxKeepaliveTests {
    // MARK: shouldPing

    @Test func shouldPingWaitsForInterval() {
        // 刚 ping 过 5ms：不到间隔 → 不发
        #expect(!SyncRxKeepalive.shouldPing(now: 10.005, lastChunkAt: 9.0,
                                            lastPingAt: 10.0, interval: 0.03))
    }

    @Test func shouldPingFiresWhenIntervalElapsed() {
        // 距上次 ping 满一个间隔、且最近也没在收块 → 发。
        // ⚠️ 取样点**不能**取 10.0 + 0.03：0.03 不是二进制可表示数，10.03 - 10.0 =
        // 0.0299999…（< 0.03）——那是在测浮点而不是测判据（本地 harness 已因此红过一次）。
        // 边界两侧各取一点：0.029 不发、0.031 发。
        #expect(SyncRxKeepalive.shouldPing(now: 10.031, lastChunkAt: 9.0,
                                           lastPingAt: 10.0, interval: 0.03))
        #expect(!SyncRxKeepalive.shouldPing(now: 10.029, lastChunkAt: 9.0,
                                            lastPingAt: 10.0, interval: 0.03))
    }

    @Test func shouldPingSkipsWhileChunksAreFlowing() {
        // 数据本身刚来过（5ms 前）→ 无线已被数据帧唤醒，补 ping 是纯开销
        #expect(!SyncRxKeepalive.shouldPing(now: 10.03, lastChunkAt: 10.025,
                                            lastPingAt: 9.0, interval: 0.03))
    }

    @Test func shouldPingNeverSpinsWhenIntervalIsZero() {
        // 间隔 <= 0 = 坏参数：绝不允许变成忙等
        #expect(!SyncRxKeepalive.shouldPing(now: 10.0, lastChunkAt: 0, lastPingAt: 0, interval: 0))
    }

    // MARK: shouldStop

    @Test func shouldStopOnlyAfterIdleTimeout() {
        #expect(!SyncRxKeepalive.shouldStop(idleFor: 0.499, idleTimeout: 0.5))
        #expect(SyncRxKeepalive.shouldStop(idleFor: 0.5, idleTimeout: 0.5))
        #expect(SyncRxKeepalive.shouldStop(idleFor: 3.0, idleTimeout: 0.5))
    }

    // MARK: 常量（任务包定案值，改动必须同步改这里）

    @Test func constantsMatchAgreedCadence() {
        #expect(SyncRxKeepalive.isEnabled)
        #expect(SyncRxKeepalive.interval == 0.010)
        #expect(SyncRxKeepalive.prewarmCount == 12)
        #expect(SyncRxKeepalive.prewarmInterval == 0.004)
        #expect(SyncRxKeepalive.idleTimeout == 0.5)
        #expect(SyncRxKeepalive.maxLifetime == 120)
        // 单帧 38B（10B 帧头 + nonce 12 + tag 16）
        #expect(SyncRxKeepalivePacer.pingFrameBytes == 38)
    }

    // MARK: pacer 启停（无墙上时间等待）

    @Test func pacerRunsWithSerialQueue() {
        let pacer = SyncRxKeepalivePacer(
            queueProvider: { DispatchQueue(label: "qqplayer.test.rx-keepalive") },
            sendPing: {}
        )
        #expect(!pacer.isRunning)
        pacer.start(fileID: "f-start")
        #expect(pacer.isRunning)
        // 幂等：并发收第二个文件不会起第二个定时器（也不会重置已发计数）
        pacer.start(fileID: "f-second")
        #expect(pacer.isRunning)
        pacer.stop(reason: .done)
        #expect(!pacer.isRunning)
        pacer.stop(reason: .idle) // 二次 stop 幂等，不抛不炸
        #expect(!pacer.isRunning)
    }

    // MARK: 预热节奏（纯函数 plan()）

    @Test func prewarmSendsFramesEvenRightAfterChunk() {
        // 预热期不看 chunk 时刻：刚有数据也要发（预热就是为「文件还没来」的窗口服务的）
        let plan = SyncRxKeepalive.plan(now: 100, lastChunkAt: 100, lastPingAt: 100,
                                        prewarmRemaining: 3)
        #expect(plan.sendPing)
        #expect(plan.prewarmRemaining == 2)
        #expect(plan.nextInterval == 0.004)
    }

    @Test func prewarmSwitchesBackToSteadyIntervalOnLastFrame() {
        let plan = SyncRxKeepalive.plan(now: 100, lastChunkAt: 100, lastPingAt: 100,
                                        prewarmRemaining: 1)
        #expect(plan.sendPing)
        #expect(plan.prewarmRemaining == 0)
        #expect(plan.nextInterval == SyncRxKeepalive.interval)
    }

    @Test func steadyStateUsesTenMillisecondCadence() {
        #expect(!SyncRxKeepalive.plan(now: 10.005, lastChunkAt: 9.0, lastPingAt: 10.0,
                                      prewarmRemaining: 0).sendPing)
        #expect(SyncRxKeepalive.plan(now: 10.011, lastChunkAt: 9.0, lastPingAt: 10.0,
                                     prewarmRemaining: 0).sendPing)
    }

    @Test func badPrewarmIntervalDoesNotSpin() {
        let plan = SyncRxKeepalive.plan(now: 10, lastChunkAt: 10, lastPingAt: 10,
                                        prewarmRemaining: 2, prewarmInterval: 0)
        #expect(plan.nextInterval == SyncRxKeepalive.interval)
    }

    // MARK: 启动信号（只认推送声明）

    @Test func onlyPushAnnounceStartsEarly() {
        #expect(SyncRxKeepalive.startReason(for: .libraryPushAnnounce) == .pushAnnounce)
        #expect(SyncRxKeepalive.startReason(for: .ping) == nil)
        #expect(SyncRxKeepalive.startReason(for: .manifestRequest) == nil)
        #expect(SyncRxKeepalive.startReason(for: .manifestResponse) == nil)
        #expect(SyncRxKeepalive.startReason(for: .fileChunk) == nil)
    }

    @Test func disabledPacerDoesNotStart() {
        let pacer = SyncRxKeepalivePacer(
            queueProvider: { DispatchQueue(label: "qqplayer.test.rx-keepalive.off") },
            sendPing: {},
            enabled: false
        )
        pacer.start(fileID: "f-off")
        #expect(!pacer.isRunning)
        #expect(pacer.pingCount == 0)
    }

    @Test func pacerInertWithoutSerialQueue() {
        // 内存回环 / 测试通道没有会话串行队列 ⇒ 不启用（既有测试逐帧断言不受影响）
        let pacer = SyncRxKeepalivePacer(queueProvider: { nil }, sendPing: {})
        pacer.start(fileID: "f-noqueue")
        #expect(!pacer.isRunning)
        #expect(pacer.pingCount == 0)
    }
}
