//
//  SyncChangeLogNotReadyResponder.swift
//  QQPlayer
//
//  门控期的「轻量应答端」（2026-11-03）：曲库索引未到终态时，iOS 不装配完整的数据同步端
//  （SyncChangeLogPeer），但**不能沉默**——沉默会让 Mac 端每轮都等满 20s 应答窗口，
//  最后报「对端无应答」，真实原因（对端正在整理曲库）完全不可见。
//
//  本类只做两件事：
//  ① 收到 change_log_pull → 回一条 notReady 空批（entries 空、lastOutboxID = 请求里的
//     cursor，**绝不推进游标**），让对端立刻知道「我还没准备好，等会儿再来」；
//  ② 收到 change_log_push → 门控期不应用，记一行日志（曲库行正在重建，落库只会制造脏数据）。
//
//  门开后由 IOSPassiveSyncCenter 的 refreshDataSyncAttachment 装配真实应答端：先
//  deactivate() 本类（帧继续向下转发，不拆链），再由 SyncChangeLogPeer 接管帧 8/9。
//

import Foundation

final class SyncChangeLogNotReadyResponder: @unchecked Sendable {
    private let session: SyncPeerSession
    private let lock = NSLock()
    private var forwardingEnabled = true
    private var priorAppHandler: (@Sendable (SyncFrame) -> Void)?
    private var priorClosedHandler: (@Sendable (SyncSessionCloseReason) -> Void)?
    /// 已回过多少次 notReady（诊断 / 单测断言）。
    private var answeredPulls = 0
    /// 本次 notReady 的原因（导入中 / 曲库整理）；默认「曲库整理」= 门控期最保守说法。
    /// 非 Sendable：调用方（IOSPassiveSyncCenter，@MainActor）在装配时捕获索引状态源；
    /// 本类虽然标 @unchecked Sendable，但应答只在会话线程同步调用一次，只读 Bool。
    private let reasonProvider: () -> SyncChangeLogNotReadyReason

    init(
        session: SyncPeerSession,
        reasonProvider: @escaping () -> SyncChangeLogNotReadyReason = { .tidying }
    ) {
        self.session = session
        self.reasonProvider = reasonProvider
        attachHandlers()
    }

    /// 已回过 notReady 的次数。
    var notReadyAnswers: Int {
        lock.lock()
        defer { lock.unlock() }
        return answeredPulls
    }

    /// 停用：帧继续向下转发（链不拆），本类不再应答（门开 → 真实应答端接管）。
    func deactivate() {
        lock.lock()
        forwardingEnabled = false
        lock.unlock()
    }

    // MARK: 帧入口

    func handleInboundFrame(_ frame: SyncFrame) {
        switch frame.type {
        case .changeLogPull:
            answerNotReady(frame)
        case .changeLogPush:
            AppLog.info(
                .sync,
                "ℹ️ SyncChangeLogNotReadyResponder: 门控期收到 change_log_push，忽略（曲库索引未到终态）"
            )
        default:
            break
        }
    }

    private func answerNotReady(_ frame: SyncFrame) {
        let request = try? JSONDecoder().decode(SyncChangeLogPullRequest.self, from: frame.payload)
        let cursor = request?.cursor ?? 0
        let reason = reasonProvider()
        let payload = SyncChangeLogPushPayload(
            entries: [],
            lastOutboxID: cursor,
            notReady: true,
            notReadyReason: reason.rawValue,
            requestID: request?.requestID
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try session.sendApplicationFrame(type: .changeLogPush, payload: data)
            lock.lock()
            answeredPulls += 1
            lock.unlock()
            AppLog.info(
                .sync,
                "ℹ️ SyncChangeLogNotReadyResponder: 回 notReady（cursor=\(cursor)，不推进游标）"
            )
        } catch {
            AppLog.warn(.sync, "⚠️ SyncChangeLogNotReadyResponder: notReady 应答失败 \(error)")
        }
    }

    // MARK: 会话槽位挂接（链式：先己后彼；停用用开关静默，不拆链）

    private func attachHandlers() {
        priorAppHandler = session.onApplicationFrame
        priorClosedHandler = session.onClosed
        session.onApplicationFrame = { [weak self] frame in
            guard let self, forwardingEnabled else {
                self?.priorAppHandler?(frame)
                return
            }
            self.handleInboundFrame(frame)
            self.priorAppHandler?(frame)
        }
        session.onClosed = { [weak self] reason in
            guard let self, forwardingEnabled else {
                self?.priorClosedHandler?(reason)
                return
            }
            self.priorClosedHandler?(reason)
        }
    }
}
