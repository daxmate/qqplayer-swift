//
//  SyncPullRetryPolicy.swift
//  QQPlayer
//
//  pull 应答等待的重试策略（纯逻辑，不碰会话 / 数据库；单测直接断言次数与间隔）。
//  2026-11-03：对端「正在整理曲库 / 处理上一批数据」时一次 20s 无应答就判失败会把
//  「慢」当成「死」；重发只重发 change_log_pull，不重放 push。
//

import Foundation

/// pull 应答等待的重试策略（纯逻辑：次数 / 间隔 / 总窗口，可单测）。
///
/// 为什么需要：对端可能正在整理曲库或处理上一批数据，**一次** 20s 无应答就判失败会把
/// 「慢」当成「死」。重发只重发 pull，不重放 push（推送是幂等的增量，重发无收益）。
struct SyncPullRetryPolicy: Equatable, Sendable {
    /// 「无应答」的总尝试次数（含首次）。
    var maxAttempts: Int
    /// 「无应答」两次尝试之间的间隔（第 1→2 次、第 2→3 次…）。
    var noAnswerDelays: [TimeInterval]
    /// 「对端未就绪（notReady）」的总尝试次数（含首次）。
    var notReadyMaxAttempts: Int
    /// 「对端未就绪」的退避间隔（默认 2s / 5s / 10s）。
    var notReadyDelays: [TimeInterval]
    /// 「对端未就绪」的总窗口上限（秒，从首次发 pull 起算，超了不再等）。
    var notReadyWindow: TimeInterval

    /// 生产默认：无应答 3 次（间隔 2s / 5s）；notReady 最多 4 次，退避 2s / 5s / 10s，窗口 60s。
    static let standard = SyncPullRetryPolicy(
        maxAttempts: 3,
        noAnswerDelays: [2, 5],
        notReadyMaxAttempts: 4,
        notReadyDelays: [2, 5, 10],
        notReadyWindow: 60
    )

    /// 第 attempt 次（1-based）尝试**无应答**后：要重发 → 返回等待间隔；nil = 次数用尽。
    func noAnswerRetryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt < maxAttempts, attempt - 1 < noAnswerDelays.count else {
            return nil
        }
        return noAnswerDelays[attempt - 1]
    }

    /// 第 attempt 次尝试收到 **notReady** 后：要重发 → 返回退避间隔；nil = 次数用尽 / 窗口已超。
    func notReadyRetryDelay(afterAttempt attempt: Int, elapsed: TimeInterval) -> TimeInterval? {
        guard attempt >= 1, attempt < notReadyMaxAttempts, attempt - 1 < notReadyDelays.count else {
            return nil
        }
        let delay = notReadyDelays[attempt - 1]
        guard elapsed + delay <= notReadyWindow else { return nil }
        return delay
    }
}

/// 本类失败 / 等待文案的本地化 key（UI 侧按 key 取文案，不在协调器里硬编码中文）。
enum SyncDataSyncMessageKey {
    /// 等待对端整理曲库（notReady 退避中）
    static let peerPreparing = "sync_data_pull_peer_preparing"
    /// 对端无应答，同轮内重发中
    static let retryingNoAnswer = "sync_data_pull_retrying_no_answer"
    /// 多次无应答后失败
    static let noAnswerTimeout = "sync_data_pull_no_answer_timeout"
    /// 对端持续 notReady（窗口耗尽）后失败
    static let notReadyTimeout = "sync_data_pull_not_ready_timeout"
}
