//
//  CloudFailureDetectorTests.swift
//  QQPlayerTests
//
//  CloudFailureDetector 防回归测试（iCloud 下载系统性失败判定纯逻辑）。
//
//  背景：原判定逻辑内联在 CloudDownloadManager（@MainActor ObservableObject，耦合
//  NSMetadataQuery/AppCoordinator 不可测）；2026-09-07 上收为纯逻辑并锁定语义：
//  同文件窗口内重复失败只算一次（大文件反复超时不能误触离线模式）、不同文件累计达
//  3 次触发、窗口超时清零重计、recordSuccess 保留 systematic 标志 / reset 全清。
//

import Foundation
import Testing

@testable import QQPlayer

private let urlA = URL(string: "file:///a/large-file.mp3")!
private let urlB = URL(string: "file:///b/other-file.flac")!

struct CloudFailureDetectorTests {
    @Test("初始态：零失败、未判定系统性失败")
    func initialState() {
        let detector = CloudFailureDetector()
        #expect(detector.consecutiveFailures == 0)
        #expect(!detector.hasDetectedSystematicFailure)
    }

    @Test("不同文件累计：3 个不同 URL 第三次触发系统性失败")
    func threeDistinctFailuresTrigger() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        let first = detector.recordFailure(url: urlA, now: t0)
        #expect(!first)
        #expect(detector.consecutiveFailures == 1)
        let second = detector.recordFailure(url: urlB, now: t0 + 1)
        #expect(!second)
        #expect(detector.consecutiveFailures == 2)
        let urlC = URL(string: "file:///c/third.mp3")!
        let triggered = detector.recordFailure(url: urlC, now: t0 + 2)
        #expect(triggered)
        #expect(detector.consecutiveFailures == 3)
        #expect(detector.hasDetectedSystematicFailure)
    }

    @Test("同文件窗口内重复失败去重：只刷新时间不计数")
    func sameFileDedup() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: urlA, now: t0)
        let again = detector.recordFailure(url: urlA, now: t0 + 10)
        #expect(!again)
        #expect(detector.consecutiveFailures == 1)
        #expect(!detector.hasDetectedSystematicFailure)
    }

    @Test("同文件一直失败不会触发（须不同文件累计）")
    func sameFileNeverTriggers() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0 ..< 10 {
            _ = detector.recordFailure(url: urlA, now: t0 + Double(i))
        }
        #expect(detector.consecutiveFailures == 1)
        #expect(!detector.hasDetectedSystematicFailure)
    }

    @Test("nil URL（外部上报无文件上下文）恒计数")
    func nilURLAlwaysCounts() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: nil, now: t0)
        _ = detector.recordFailure(url: nil, now: t0 + 1)
        let triggered = detector.recordFailure(url: nil, now: t0 + 2)
        #expect(triggered)
        #expect(detector.consecutiveFailures == 3)
    }

    @Test("窗口超时清零重计：超过 failureResetWindow 后旧计数作废")
    func windowExpiryResets() {
        var detector = CloudFailureDetector(failureResetWindow: 300)
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: urlA, now: t0)
        _ = detector.recordFailure(url: urlB, now: t0 + 1)
        #expect(detector.consecutiveFailures == 2)
        // 301 秒后：窗口过期 → 清零 → 新失败从 1 计
        _ = detector.recordFailure(url: urlA, now: t0 + 302)
        #expect(detector.consecutiveFailures == 1)
        #expect(!detector.hasDetectedSystematicFailure)
    }

    @Test("窗口过期后同文件可再次计数（lastFailureURL 已清）")
    func windowExpiryAllowsSameFileAgain() {
        var detector = CloudFailureDetector(failureResetWindow: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: urlA, now: t0)
        #expect(detector.consecutiveFailures == 1)
        // 61 秒后同一文件再失败：窗口已重置 → 重新计数（不再是去重）
        let triggered = detector.recordFailure(url: urlA, now: t0 + 61)
        _ = detector.recordFailure(url: urlB, now: t0 + 62)
        let third = detector.recordFailure(url: urlA, now: t0 + 63)
        #expect(detector.consecutiveFailures == 3)
        #expect(triggered || third) // 累计到 3 会触发
        #expect(detector.hasDetectedSystematicFailure)
    }

    @Test("触发后不再重复触发（hasDetectedSystematicFailure 已置位）")
    func triggerOnlyOnce() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: urlA, now: t0)
        _ = detector.recordFailure(url: urlB, now: t0 + 1)
        let first = detector.recordFailure(url: nil, now: t0 + 2)
        #expect(first)
        // 继续失败不再返回 true（已在离线模式）
        let again = detector.recordFailure(url: nil, now: t0 + 3)
        #expect(!again)
        #expect(detector.consecutiveFailures == 4)
    }

    @Test("recordSuccess：清计数但保留 systematic 标志（resetFailureCount 语义）")
    func recordSuccessKeepsSystematicFlag() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: urlA, now: t0)
        _ = detector.recordFailure(url: urlB, now: t0 + 1)
        _ = detector.recordFailure(url: nil, now: t0 + 2)
        #expect(detector.hasDetectedSystematicFailure)

        detector.recordSuccess()
        #expect(detector.consecutiveFailures == 0)
        #expect(detector.hasDetectedSystematicFailure) // 标志保留
        // 清后新失败从 1 计
        _ = detector.recordFailure(url: urlA, now: t0 + 100)
        #expect(detector.consecutiveFailures == 1)
    }

    @Test("reset：全清（attemptRecovery 语义）")
    func resetClearsEverything() {
        var detector = CloudFailureDetector()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = detector.recordFailure(url: urlA, now: t0)
        _ = detector.recordFailure(url: urlB, now: t0 + 1)
        _ = detector.recordFailure(url: nil, now: t0 + 2)
        #expect(detector.hasDetectedSystematicFailure)

        detector.reset()
        #expect(detector.consecutiveFailures == 0)
        #expect(!detector.hasDetectedSystematicFailure)
    }
}
