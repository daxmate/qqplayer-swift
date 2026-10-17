//
//  PeerFileStateRow.swift
//  QQPlayer
//
//  同步覆盖确认台账行 `sync_peer_file_state` 的**唯一模型定义**（批 2 落存储层时从
//  判定器文件移来，避免两处手工维护同一语义）。
//
//  规格：`docs/lan-sync-design.md` §6.1（判定表 + 台账状态机）；契约 `docs/sync-contract.md`
//  §2 G；不变量 `docs/sync-invariants.md` §H INV-33。
//
//  为什么单独一个文件（而不是放存储层）：本文件**零 IO / 零 GRDB**，判定器
//  （`SyncFileOverwriteJudge`，纯逻辑，可进 `scripts/sync-harness` 直编）与存储层
//  （`PeerFileStateStore`，需真 GRDB）共用同一类型；GRDB 的 Record 一致性只在存储层补。
//
//  表结构（`DatabaseManager+Schema.swift` 建，CREATE TABLE IF NOT EXISTS 幂等）：
//      peer_id               TEXT    NOT NULL   -- 对端 DeviceID
//      relative_path         TEXT    NOT NULL   -- 对账键（POSIX，相对曲库根）
//      content_hash          TEXT    NOT NULL   -- 「上次达成一致时」的内容指纹
//      local_hash_at_decision TEXT               -- 决策时的本端指纹（approved / kept 都写）
//      state                 TEXT    NOT NULL   -- agreed | pending | approved | kept
//      updated_at_ms         INTEGER NOT NULL   -- 落库时刻（epoch 毫秒）
//      PRIMARY KEY (peer_id, relative_path)
//  判定 7 条不消费 `updated_at_ms`（时间戳不参与判据）；它只描述「这行多新」。

import Foundation

/// `sync_peer_file_state` 的一行（每条 `(peer_id, relative_path)` 唯一）。
struct PeerFileStateRow: Equatable, Sendable {
    /// 台账状态机（§6.1）：`pending` 判为冲突待确认 / `approved` 用户点了覆盖 /
    /// `kept` 用户选〔保持现状〕 / `agreed` 双方一致。
    enum State: String, Equatable, Sendable, CaseIterable {
        case agreed
        case pending
        case approved
        case kept
    }

    /// 对端 DeviceID（与 `sync_cursor` / `sync_push_cursor` 同口径）。
    var peerId: String
    /// 对账键（POSIX，相对曲库根）。
    var relativePath: String
    /// 「上次达成一致时」的内容指纹。
    var contentHash: String
    /// 状态机当前态。
    var state: State
    /// **决策时的本端指纹**（`approved` / `kept` 都写）—— 校验「决策后本端是否又变了」。
    var localHashAtDecision: String?

    init(
        peerId: String,
        relativePath: String,
        contentHash: String,
        state: State,
        localHashAtDecision: String? = nil
    ) {
        self.peerId = peerId
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.state = state
        self.localHashAtDecision = localHashAtDecision
    }
}
