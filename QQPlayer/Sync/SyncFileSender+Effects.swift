//
//  SyncFileSender+Effects.swift
//  QQPlayer
//
//  发送端「效果执行」层（2026-11-13 从 SyncFileSender 拆出）：状态机在锁内只产出
//  Action，所有发帧 / 落盘 / 用户回调都在锁外执行（同步回环下 ack 会重入，锁内回调必死锁）。
//
//  为什么单独一文件：主文件行数已顶到结构预算棘轮上限（> 600 行即被 CI 拦），
//  这三个成员不碰状态机，拆出来零风险（与 +Active / +Metrics 同一口径）。
//

import Foundation

extension SyncFileSender {
    /// 锁内状态机产出的效果（锁外执行）。
    enum Action {
        case log(SyncTransferMetrics)
        case finish(Outcome)
    }

    /// 锁内跑状态机，锁外执行效果（发块 / 日志 / 用户回调）。
    func runLocked(_ body: () -> [Action]) {
        lock.lock()
        let actions = body()
        lock.unlock()
        perform(actions)
    }

    /// 执行效果（锁外；顺序 = 生产顺序：先记日志，再用户回调）。
    func perform(_ actions: [Action]) {
        // 诊断：先把上个状态机步骤攒下的「每块往返」落盘（不做任何状态变更）。
        flushChunkRoundTripDiag()
        for action in actions {
            switch action {
            case let .log(metrics):
                SyncConnectDiag.log(metrics.logLine)
            case let .finish(outcome):
                onCompletion?(outcome)
            }
        }
    }
}
