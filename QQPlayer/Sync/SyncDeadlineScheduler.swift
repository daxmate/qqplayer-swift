//
//  SyncDeadlineScheduler.swift
//  QQPlayer
//
//  同步子系统「一次性截止时间」的**唯一调度入口**（ack 超时 / 握手超时）。
//
//  为什么收口（2026-09-20）：超时判定原先各自直接
//  `DispatchQueue.global(qos: .utility).asyncAfter(...)`，等于把「超时**何时**被判定」
//  交给了全局队列的线程池状态——池被占满时，工作项**过了 deadline 也拿不到线程执行**
//  （本机实测：占满池后 0.05s 的 deadline 在 11s 窗口内一次都没落地）。后果不是
//  「不超时」而是「超时时刻不可预期」：
//    - `SyncFileSender` ack 超时：2026-09-20 CI run 35478148288 假失败——注入 0.15s
//      的超时在 60s 轮询窗口内都没落地，把与它无关的 PR 卡红；
//    - `SyncPeerSession` 握手超时：更早（2026-09-09）该用例因「asyncAfter 从未触发」
//      被 `.disabled` 掉。
//
//  收口做法：调度入口**可注入**（协议 + 生产实现）。测试注入手动调度器**显式触发**
//  超时 —— 用例不再等待真实定时器，「超时之后该发生什么」与 runner 的调度延迟解耦；
//  生产路径逐字不变（仍是 GCD 全局 `.utility` 队列）。断言语义一条不减。
//
//  形状契约（禁止第二实现 / 禁止消费点直连）：`SyncDeadlineSchedulingContractTests`。
//

import Foundation

/// 已排定的一次性截止时间（可取消）。
protocol SyncScheduledDeadline: AnyObject, Sendable {
    /// 取消：尚未开始执行的工作项不再执行（已在执行中的不可撤回）。
    func cancel()
}

/// 一次性截止时间调度器（唯一入口；见文件头）。
/// - 生产：`DispatchSyncDeadlineScheduler`（GCD 全局 `.utility` 队列）
/// - 测试：手动调度器（只记录待触发动作，由用例显式触发，不依赖真实定时器）
protocol SyncDeadlineScheduling: Sendable {
    /// 排定一个「`delay` 秒后执行」的工作项。
    /// - Parameters:
    ///   - delay: 相对当前时刻的延迟（秒；调用方保证非负）
    ///   - action: 到点执行的工作（**不在**调用方线程执行）
    /// - Returns: 可取消句柄（由调用方持有并负责取消）
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> any SyncScheduledDeadline
}

/// 生产实现：GCD 全局 `.utility` 队列（与收口前逐字同路径，行为不变）。
final class DispatchSyncDeadlineScheduler: SyncDeadlineScheduling {
    /// 共享实例（无状态、可跨线程使用）。
    static let shared = DispatchSyncDeadlineScheduler()

    private let queue: DispatchQueue

    init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> any SyncScheduledDeadline {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchSyncScheduledDeadline(item: item)
    }
}

/// `DispatchWorkItem` 的取消句柄（`cancel()` 幂等）。
private final class DispatchSyncScheduledDeadline: SyncScheduledDeadline, @unchecked Sendable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}
