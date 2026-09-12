//
//  SyncChangeLogPeer.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）播放数据 changeLog 帧的会话层处理器：把对端推来的
//  change_log_pull / change_log_push 解码 → 接 LWW 对账逻辑 → 应用胜出条目。
//
//  ⚠️ v2 语义修订（2026-09-10 用户拍板，docs/lan-sync-design.md §6.2 / §12b-7）：
//  **不再有删除传播**——本地 outbox 照常记录 delete（本地事务完整），但
//  ① 发送侧：delete 变更不上线（应答 pull 前过滤）；同一键在本批末尾是 delete 时，
//    其更早的 upsert 也不上线（否则对端会复活一个本端已删除的状态，且永无纠正机会）；
//  ② 接收侧：收到 delete（可能来自旧 peer）一律忽略，拦截在 localize **之前**
//     （delete 行没有歌曲载荷，若先进 localize 会被判成"本地缺歌"挂起，永远等不到
//     歌到位 → 垃圾数据 + 语义错乱），不进 localize / pendingStore / LWW，也不删本地行。
//  删除判定集中在 SyncChangeLogDeletionPolicy.swift（纯逻辑单一事实源）。
//
//  协议语义（docs/lan-sync-design.md §6.2；v1 单 Host-单 Client）：
//  - change_log_pull(cursor)：对端请求本端 outbox 中 id > cursor 的增量。
//    应答 = change_log_push(entries, lastOutboxID)。处理 = 本端从 store 取
//    增量回推（自动应答）。
//    ⚠️ v3 口径修订（2026-09-12 审计 S1）：`lastOutboxID` = **本批实际发出去的最后
//    一行 id**（与取批同一读事务内取值，见 `SyncChangeLogStore.page`），不再 = outbox
//    全局末尾——后者在 limit 分页下会把本批没发出的行永久越过（第 501 行起不再同步）。
//    被本批过滤的 delete 行算在本批内：它们永不上线，允许被越过。
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
    /// 跨端歌曲引用映射（发送侧填 contentHash / 接收侧本地化，M4-2a）。
    private let mapper: SyncChangeLogMapper
    /// 本地还没有该歌时挂起远端变更，歌到后由 SyncChangeLogReplay 重放。
    private let pendingStore: SyncChangeLogPendingStore
    /// 本端视角的对端 Device ID（sync_cursor.peer_id；推进游标用）。
    let peerID: String

    /// pull 请求处理结果（测试断言/诊断用；锁外触发）。
    var onPullHandled: ((SyncChangeLogPullRequest, Int) -> Void)?
    /// push 应用完成（applied 行数；锁外触发）。
    var onPushApplied: ((Int) -> Void)?
    /// push 中因本地缺歌而挂起的行数（锁外触发；0 = 无挂起）。
    var onPushSuspended: ((Int) -> Void)?
    /// push 中被忽略的 delete 行数（v2 删除不传播；锁外触发；0 = 无忽略）。
    var onPushIgnoredDeletes: ((Int) -> Void)?
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
        self.mapper = SyncChangeLogMapper(database: applier.database)
        self.pendingStore = SyncChangeLogPendingStore(database: applier.database)
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
            // S1（2026-09-12 审计修复）：取批与「本批末行 id」必须在**同一读事务**内取值
            // （`store.page`），且游标口径 = **本批实际发出去的最后一行 id**——不再用
            // outbox 全局末尾：limit 分页下全局末尾会把本批没发出的行（第 501 行起）
            // 越过去，游标一旦推过去永不回头 → 那些行永久不再同步。
            let page = try store.page(after: request.cursor)
            let entries = page.rows
            // v2（§12b-7）：删除不跨端传播——本地 outbox 照记 delete（本地事务完整），
            // 但 delete 不上线；且同一键在本批末尾是 delete 时，其更早的 upsert 也不上线
            // （否则会在对端复活一个本端已删除的状态，而 delete 永不上线 → 无法纠正）。
            // 判定集中在 SyncChangeLogDeletionPolicy（纯逻辑单一事实源）。
            let transmittable = SyncChangeLogDeletionPolicy
                .transmittableIndexes(rows: entries.map {
                    SyncChangeLogPolicyRow(entity: $0.entity, rowKey: $0.rowKey, op: $0.op)
                })
                .map { entries[$0] }
            // M4-2a: 逐行按歌曲引用查 track 取 content_hash 填进 wire（查不到 = nil）。
            let wireEntries = try mapper.wireEntries(transmittable)
            // 游标 = **本批实际末行 id**（含被本批过滤的 delete 行）：被过滤的行永不重发、
            // 允许被越过；批外的行（任何 upsert）一律不被越过（下一轮继续发）。
            let response = SyncChangeLogPushPayload(entries: wireEntries, lastOutboxID: page.lastOutboxID)
            try session.sendApplicationFrame(type: .changeLogPush, payload: JSONEncoder().encode(response))
            // 计数语义保持不变 = "本端 outbox 增量行数"（含被过滤的 delete），与 wire 条目数无关。
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
            // 远端批 → 本地行（保留远端 outbox id：merge 排序键 (updated_at, id)
            // 需要它来保证同 ms 多行按远端落库序确定性排序——playlist upsert 先于
            // 其 playlist_item 应用，否则 item 因歌单未到被静默跳过。wire id 0（本无
            // id）转 nil）。
            // M4-2a：先按 content_hash 把歌曲引用本地化（row_key/payload 换成
            // 本端 stableId）再对账——LWW 键 = (entity, row_key)，两端 stableId
            // 不同，不本地化就对不上键；本地还没这首歌的行挂起，不丢。
            var remoteRows: [SyncChangeLogRow] = []
            var suspended = 0
            var ignoredDeletes = 0
            for entry in payload.entries {
                // v2（§12b-7）：删除不传播——收到 delete 一律忽略，且必须在 localize
                // 之前拦截（见文件头注释：否则会被误判为"本地缺歌"挂起）。
                if SyncChangeLogDeletionPolicy.shouldIgnore(op: entry.op) {
                    ignoredDeletes += 1
                    print("ℹ️ SyncChangeLogPeer: 忽略远端删除（删除不跨端传播）entity=\(entry.entity) rowKey=\(entry.rowKey)")
                    continue
                }
                switch try mapper.localize(entry) {
                case .mapped(let row), .passThrough(let row):
                    remoteRows.append(row)
                case .suspended(let contentHash, let remoteRow):
                    try pendingStore.suspend(remoteRow, contentHash: contentHash)
                    suspended += 1
                }
            }
            // 本地批：按 (entity, row_key) **一次取齐**本端该键最新行（对账代表本端事实）。
            // S4（2026-09-12 审计）：原先逐行调 `latestRow` 是 N+1（每行一次查询）；
            // 改为按 entity 分组的批量查询，键集合 = 远端批本地化后的键集合，口径不变。
            var localRefs: [SyncChangeLogRef] = []
            var localRefSet = Set<SyncChangeLogRef>()
            for row in remoteRows {
                guard let entity = SyncChangeEntity(rawValue: row.entity) else { continue }
                let ref = SyncChangeLogRef(entity: entity, rowKey: row.rowKey)
                if localRefSet.insert(ref).inserted { localRefs.append(ref) }
            }
            let latestByRef = try store.latestRows(for: localRefs)
            var localRows: [SyncChangeLogRow] = []
            for row in remoteRows {
                guard let entity = SyncChangeEntity(rawValue: row.entity) else { continue }
                if let local = latestByRef[SyncChangeLogRef(entity: entity, rowKey: row.rowKey)] {
                    localRows.append(local)
                }
            }
            // LWW 合并 → 应用远端胜出行
            let mergeResult = SyncLWWReconcile.merge(localRows: localRows, remoteRows: remoteRows)
            let applied = try applier.apply(mergeResult.applyRemote)
            // 推进本端对该 peer 的游标（挂起行已持久化，游标可安全推进：数据不丢）
            try store.setCursor(forPeer: peerID, lastOutboxID: payload.lastOutboxID)
            onPushApplied?(applied)
            onPushSuspended?(suspended)
            onPushIgnoredDeletes?(ignoredDeletes)
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
