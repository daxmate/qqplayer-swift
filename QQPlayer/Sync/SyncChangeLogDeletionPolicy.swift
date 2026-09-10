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
//  为什么单独抽一个纯逻辑入口：同一件事有五个消费点——发送侧逐行过滤
//  （SyncChangeLogPeer.handlePull）、**发送侧批次抑制**（同一键在本批末尾是 delete 时，
//  其更早的 upsert 也不上线，见 `transmittableIndexes`）、接收侧拦截
//  （SyncChangeLogPeer.handlePush）、应用层兜底（SyncChangeLogApplier.applyOne）、
//  挂起重放防御（SyncChangeLogReplay）。散落实现必然漂移（"修一处漏一处"，见
//  MEMORY 行为单一事实源纪律），故收口到本文件。
//
//  本文件刻意不 import GRDB / 不依赖 DatabaseManager，只对 op 字符串判定，
//  因此可直接进 scripts/run-local-sync-tests.sh 的无模拟器 harness 真跑断言。
//  op 常量与 SyncChangeOp.rawValue 的对齐由 QQPlayerTests 的契约用例兜底。
//

/// 发送侧过滤用的一行 outbox 的最小视图（只取判定需要的三列，不依赖 GRDB 行类型）。
struct SyncChangeLogPolicyRow: Equatable {
    var entity: String
    var rowKey: String
    var op: String
}

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

    /// 发送侧：一批 outbox 行（**按 outbox id 升序**）里允许上线的下标。
    ///
    /// 两条规则（§6.2 / §12b-7 的必要推论）：
    /// 1. 自身是 delete 的行不上线；
    /// 2. 同一 (entity, rowKey) 在**本批最后一行是 delete** 时，其更早的 upsert 也不上线——
    ///    否则会在对端**复活**一个本端已删除的状态（幽灵收藏 / 幽灵歌单项），
    ///    而 delete 永不上线 → 该状态在对端永远无法被纠正。
    ///
    /// 键的末尾在批次之外时不适用规则 2（那批早已发出，无法撤回）——这是拉取游标的
    /// 天然边界，不是缺陷。
    static func transmittableIndexes(rows: [SyncChangeLogPolicyRow]) -> [Int] {
        var lastIndexByKey: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            lastIndexByKey[key(entity: row.entity, rowKey: row.rowKey)] = index
        }
        return rows.indices.filter { index in
            let row = rows[index]
            guard isTransmittable(op: row.op) else { return false }
            guard let lastIndex = lastIndexByKey[key(entity: row.entity, rowKey: row.rowKey)] else {
                return true
            }
            return isTransmittable(op: rows[lastIndex].op)
        }
    }

    /// 对账键：与业务侧 (entity, row_key) 同口径。
    private static func key(entity: String, rowKey: String) -> String {
        "\(entity)\u{1F}\(rowKey)"
    }

    /// 接收侧：该远端变更是否一律忽略。**delete 一律忽略**
    /// （拦截必须发生在 localize 之前，否则会被判成"本地缺歌"挂起）。
    static func shouldIgnore(op: String) -> Bool {
        isDelete(op: op)
    }
}
