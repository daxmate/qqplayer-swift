//
//  SyncChangeLogPeer.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）播放数据 changeLog 帧的会话层处理器：把对端推来的
//  change_log_pull / change_log_push 解码 → 接 LWW 对账逻辑 → 应用胜出条目。
//
//  协议语义（docs/lan-sync-design.md §6.2；v1 单 Host-单 Client）：
//  - change_log_pull(cursor)：对端请求本端 outbox 中 id > cursor 的增量。
//    应答 = change_log_push(entries, lastOutboxID)。处理 = 本端从 store 取
//    增量回推（自动应答）。
//  - change_log_push(entries, lastOutboxID)：对端推来一批 outbox 行。处理 =
//    逐键与本地 outbox 对账（SyncLWWReconcile：同键 updated_at 大者胜，
//    平局 delete 压 upsert）→ 胜出的远端行交 SyncChangeLogApplier 落本地业务表
//    → 把 lastOutboxID 记为本端对该 peer 的游标（sync_cursor）。
//  - 会话断连/关闭：清空进行中的拉取上下文（v1 拉取为一次性请求-应答，
//    无跨帧状态；仅需转发 onClosed 给调用方感知）。
//
//  与 SyncFileSender/Receiver 同构：链式挂接会话 onApplicationFrame /
//  onClosed（先己后彼），结束用 enabled 开关静默自己。本类持有 store 与
//  applier（都注入 DatabaseManager，测试用内存库）。
//
//  v1 范围：播放位置上下文（playback_position）本地载体非 DB 行，应用走
//  applier 的 playbackPositionSink（nil = 丢弃，M4-2 接本地存储）。端到端
//  "自动同步调度"（何时发起 pull）归 M4-2/UI，本类只做收到帧后的处理与
//  应答，可单测级验证。
//

import Foundation

final class SyncChangeLogPeer: @unchecked Sendable {
    /// 解析错误（帧载荷 JSON 非法）——调用方按协议违例处理。
    enum DecodeError: Error, Equatable {
        case invalidPayload(String)
    }

    private let session: SyncPeerSession
    private let store: SyncChangeLogStore
    private let applier: SyncChangeLogApplier
    /// 本端视角的对端 Device ID（sync_cursor.peer_id；推进游标用）。
    let peerID: String

    /// pull 请求处理结果（测试断言/诊断用；锁外触发）。
    var onPullHandled: ((SyncChangeLogPullRequest, Int) -> Void)?
    /// push 应用完成（applied 行数；锁外触发）。
    var onPushApplied: ((Int) -> Void)?
    /// 解码失败（载荷非法；锁外触发）。
    var onDecodeFailure: ((DecodeError) -> Void)?

    // 会话槽位链式挂接
    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var priorClosedHandler: ((SyncSessionCloseReason) -> Void)?
    private var forwardingEnabled = true

    init(
        session: SyncPeerSession,
        store: SyncChangeLogStore,
        applier: SyncChangeLogApplier,
        peerID: String
    ) {
        self.session = session
        self.store = store
        self.applier = applier
        self.peerID = peerID
        attachHandlers()
    }

    // MARK: 对外 API

    /// 主动发起增量拉取（v1 供测试/未来调度调用）：向对端发 change_log_pull，
    /// 携带本端记录的对端 outbox 游标。应答经 change_log_push 帧回来，由
    /// handleInboundFrame 处理。
    func sendPull() throws {
        let cursor = try store.cursor(forPeer: peerID)
        let request = SyncChangeLogPullRequest(cursor: cursor)
        let payload = try JSONEncoder().encode(request)
        try session.sendApplicationFrame(type: .changeLogPull, payload: payload)
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        switch frame.type {
        case .changeLogPull:
            handlePull(frame)
        case .changeLogPush:
            handlePush(frame)
        default:
            break // 其他业务帧（file_*）不归本类
        }
    }

    // MARK: 收帧处理

    private func handlePull(_ frame: SyncFrame) {
        let request: SyncChangeLogPullRequest
        do {
            request = try JSONDecoder().decode(SyncChangeLogPullRequest.self, from: frame.payload)
        } catch {
            onDecodeFailure?(.invalidPayload("change_log_pull 解码失败：\(error)"))
            return
        }
        do {
            let entries = try store.entries(after: request.cursor)
            let lastID = try store.maxOutboxID()
            let wireEntries = entries.map {
                SyncChangeLogWireEntry(
                    id: $0.id ?? 0,
                    entity: $0.entity,
                    rowKey: $0.rowKey,
                    op: $0.op,
                    updatedAtMs: $0.updatedAtMs,
                    contentHash: nil, // M3-1 未合入；M4-2 收口 content_hash 映射
                    payloadJSON: $0.payloadJSON
                )
            }
            let response = SyncChangeLogPushPayload(entries: wireEntries, lastOutboxID: lastID)
            try session.sendApplicationFrame(type: .changeLogPush, payload: JSONEncoder().encode(response))
            onPullHandled?(request, entries.count)
        } catch {
            onDecodeFailure?(.invalidPayload("change_log_pull 应答失败：\(error)"))
        }
    }

    private func handlePush(_ frame: SyncFrame) {
        let payload: SyncChangeLogPushPayload
        do {
            payload = try JSONDecoder().decode(SyncChangeLogPushPayload.self, from: frame.payload)
        } catch {
            onDecodeFailure?(.invalidPayload("change_log_push 解码失败：\(error)"))
            return
        }
        do {
            // 远端批 → SyncChangeLogRow（wire entry 无本地 id，转成 id=nil 行供对账）
            let remoteRows = payload.entries.map {
                SyncChangeLogRow(
                    id: nil,
                    entity: SyncChangeEntity(rawValue: $0.entity) ?? .favorite,
                    rowKey: $0.rowKey,
                    op: SyncChangeOp(rawValue: $0.op) ?? .upsert,
                    updatedAtMs: $0.updatedAtMs,
                    payloadJSON: $0.payloadJSON
                )
            }
            // 本地批：逐键取本端该键最新一行（对账代表本端事实）
            var localRows: [SyncChangeLogRow] = []
            for row in remoteRows {
                guard let entity = SyncChangeEntity(rawValue: row.entity) else { continue }
                if let local = try store.latestRow(entity: entity, rowKey: row.rowKey) {
                    localRows.append(local)
                }
            }
            // LWW 合并 → 应用远端胜出行
            let mergeResult = SyncLWWReconcile.merge(localRows: localRows, remoteRows: remoteRows)
            let applied = try applier.apply(mergeResult.applyRemote)
            // 推进本端对该 peer 的游标
            try store.setCursor(forPeer: peerID, lastOutboxID: payload.lastOutboxID)
            onPushApplied?(applied)
        } catch {
            onDecodeFailure?(.invalidPayload("change_log_push 应用失败：\(error)"))
        }
    }

    // MARK: 会话断连

    private func handleSessionClosed(_ reason: SyncSessionCloseReason) {
        // v1：拉取为一次性请求-应答，无跨帧状态需清理。预留：未来分页拉取
        // 的进行中上下文在此中止。
    }

    // MARK: 会话槽位挂接（链式：先己后彼；结束用开关静默，不拆链）

    private func attachHandlers() {
        priorAppHandler = session.onApplicationFrame
        priorClosedHandler = session.onClosed
        session.onApplicationFrame = { [weak self] frame in
            guard let self, self.forwardingEnabled else {
                self?.priorAppHandler?(frame)
                return
            }
            self.handleInboundFrame(frame)
            self.priorAppHandler?(frame)
        }
        session.onClosed = { [weak self] reason in
            guard let self, self.forwardingEnabled else {
                self?.priorClosedHandler?(reason)
                return
            }
            self.handleSessionClosed(reason)
            self.priorClosedHandler?(reason)
        }
    }
}
