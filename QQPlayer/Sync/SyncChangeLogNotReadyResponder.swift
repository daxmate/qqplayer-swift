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
    /// 本类装配时的槽位代次（见 `SyncPeerSession.applicationFrameSlotGeneration`）。
    /// `deactivate()` 用相等性判断「槽位里是否仍是**我**装的那一层」，不等就不还原。
    private var installedAppGeneration: UInt64?
    private var installedClosedGeneration: UInt64?
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

    /// 停用：本类不再应答（门开 → 真实应答端接管），并把槽位还原成 `prior`。
    ///
    /// 2026-11-12 真机 bug：此前只翻 `forwardingEnabled`、**不还槽位**；调用方随后
    /// `dataSyncNotReadyResponder = nil` 释放本类，槽位里只剩一个 `self == nil` 的闭包，
    /// 而旧闭包写的是 `self?.priorAppHandler?(frame)` —— self 为 nil 时既不转发也不报错，
    /// 整条转发链被剪断（此后所有 manifest / 文件帧在 iPhone 端静默消失）。
    ///
    /// 还原口径：只有「槽位代次仍是本类装配时那一次」才还原，说明槽位里还是**我装的**那一层。
    /// 若代次已变（后装的包装层 / 分发链落在我们上面），**不动槽位**——那会拆掉别人的链；
    /// 此时本类闭包已改成「永远转发 prior」，即使被释放也不会再断链。
    func deactivate() {
        lock.lock()
        forwardingEnabled = false
        let appGeneration = installedAppGeneration
        let closedGeneration = installedClosedGeneration
        installedAppGeneration = nil
        installedClosedGeneration = nil
        lock.unlock()

        if let appGeneration, session.applicationFrameSlotGeneration == appGeneration {
            session.onApplicationFrame = priorAppHandler
        }
        if let closedGeneration, session.closedSlotGeneration == closedGeneration {
            session.onClosed = priorClosedHandler
        }
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
        // ⚠️ `prior` 必须**强捕获**（局部常量），不能经 `self?.priorAppHandler` 取：
        // 本类被释放后 self == nil，旧写法既不转发也不报错 → 整条链静默断掉
        // （2026-11-12 真机：iPhone 端 manifest 帧全部消失）。只强捕获 prior，不强捕获 self。
        let priorApp = session.onApplicationFrame
        let priorClosed = session.onClosed
        priorAppHandler = priorApp
        priorClosedHandler = priorClosed
        session.onApplicationFrame = { [weak self] frame in
            if let self {
                if self.forwardingEnabled {
                    self.handleInboundFrame(frame)
                }
            } else {
                AppLog.debug(.sync, "🧩 NotReadyResponder 包装层已释放，仅转发 type=\(frame.type)")
            }
            priorApp?(frame)
        }
        installedAppGeneration = session.applicationFrameSlotGeneration
        // 本类对关闭事件无自有处理（原实现只是转发）→ 直接转发，不捕获 self。
        session.onClosed = { reason in
            priorClosed?(reason)
        }
        installedClosedGeneration = session.closedSlotGeneration
    }
}
