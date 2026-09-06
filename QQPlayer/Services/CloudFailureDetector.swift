//
//  CloudFailureDetector.swift
//  QQPlayer
//
//  iCloud 下载系统性失败检测的纯逻辑（CloudDownloadManager 决策上收）。
//
//  语义照抄原 detectSystematicFailure 实现（2026-09-07 测试补写上收，行为零变化）：
//  - 距上次失败超过 failureResetWindow → 计数清零重计
//  - 同一 URL 在窗口内重复失败只刷新时间不计数（一个大文件反复超时算一次失败，
//    只有不同文件才累计）；nil URL（无文件上下文的外部上报）恒计数
//  - 不同 URL 累计达 maxConsecutiveFailures → 判定系统性失败（首次触发返回 true，
//    由调用方执行切离线等副作用）
//
//  测试注：时间一律 now 注入（纯函数可测）；CloudDownloadManager 传 Date()。
//

import Foundation

struct CloudFailureDetector: Equatable, Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var hasDetectedSystematicFailure = false
    private var lastFailureTime: Date?
    private var lastFailureURL: URL?

    /// 失败窗口：距上次失败超过该时长后重新计数
    let failureResetWindow: TimeInterval
    /// 窗口内累计失败次数阈值（默认 3，原 maxConsecutiveFailures）
    let maxConsecutiveFailures: Int

    init(failureResetWindow: TimeInterval = 300, maxConsecutiveFailures: Int = 3) {
        self.failureResetWindow = failureResetWindow
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    /// 记录一次失败。返回 true = 本次首次达到阈值判定系统性失败（此前未触发过）。
    @discardableResult
    mutating func recordFailure(url: URL?, now: Date) -> Bool {
        // 窗口已过 → 清零重计
        if let last = lastFailureTime, now.timeIntervalSince(last) > failureResetWindow {
            consecutiveFailures = 0
            lastFailureURL = nil
        }
        // 同一文件重复失败去重（只刷新时间，不计数）
        if let url, url == lastFailureURL {
            lastFailureTime = now
            return false
        }
        consecutiveFailures += 1
        lastFailureTime = now
        lastFailureURL = url
        if consecutiveFailures >= maxConsecutiveFailures, !hasDetectedSystematicFailure {
            hasDetectedSystematicFailure = true
            return true
        }
        return false
    }

    /// 成功操作后清计数（保留 systematic 标志；对应原 resetFailureCount 语义）
    mutating func recordSuccess() {
        if consecutiveFailures > 0 { consecutiveFailures = 0 }
        lastFailureTime = nil
        lastFailureURL = nil
    }

    /// 全清（对应原 attemptRecovery 语义：退出离线模式）
    mutating func reset() {
        consecutiveFailures = 0
        hasDetectedSystematicFailure = false
        lastFailureTime = nil
        lastFailureURL = nil
    }
}
