//
//  SyncChangeLogDeletionPolicy.swift
//  QQPlayer
//
//  局域网同步（S2, v2 语义修订）**删除不跨端传播**的单一事实源。
//
//  语义（docs/lan-sync-design.md §6.2 / §12b-7，2026-09-10 用户拍板）：
//  - 取消收藏 / 删歌单 / 移除歌单项等删除操作**只在本地生效**：本地业务行与本地
//    outbox 照常记录（本地事务完整、变更留痕），但 **delete 变更不上线**。
//  - 接收侧收到 delete（可能来自旧版本 peer 或历史 outbox）**一律忽略**：不本地化、
//    不挂起、不进 LWW、更不删本地业务行。
//
//  为什么单独抽一个纯逻辑入口：同一件事有四个消费点——发送侧过滤
//  （SyncChangeLogPeer.handlePull）、接收侧拦截（SyncChangeLogPeer.handlePush）、
//  应用层兜底（SyncChangeLogApplier.applyOne）、挂起重放防御
//  （SyncChangeLogReplay）。散落实现必然漂移（"修一处漏一处"，见
//  MEMORY 行为单一事实源纪律），故收口到本文件。
//
//  本文件刻意不 import GRDB / 不依赖 DatabaseManager，只对 op 字符串判定，
//  因此可直接进 scripts/run-local-sync-tests.sh 的无模拟器 harness 真跑断言。
//  op 常量与 SyncChangeOp.rawValue 的对齐由 QQPlayerTests 的契约用例兜底。
//

/// 删除不传播策略：所有"是否允许上线 / 是否忽略"的判断都走这里。
enum SyncChangeLogDeletionPolicy {
    /// 与 `SyncChangeOp.delete.rawValue` 对齐（契约测试兜底）。
    static let deleteOperation = "delete"

    /// 该 op 是否为删除。
    static func isDelete(op: String) -> Bool {
        op == deleteOperation
    }

    /// 发送侧：该变更是否允许上线传输。**delete 不上线**（本地 outbox 照记）。
    /// 未知 op 不误伤（只有 delete 被拦）。
    static func isTransmittable(op: String) -> Bool {
        !isDelete(op: op)
    }

    /// 接收侧：该远端变更是否一律忽略。**delete 一律忽略**
    /// （拦截必须发生在 localize 之前，否则会被判成"本地缺歌"挂起）。
    static func shouldIgnore(op: String) -> Bool {
        isDelete(op: op)
    }
}
