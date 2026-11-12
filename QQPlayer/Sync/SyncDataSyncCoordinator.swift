//
//  SyncDataSyncCoordinator.swift
//  QQPlayer
//
//  S2-T12（2026-09-13）独立「同步数据」编排：一次动作 = **推本端增量 + 拉对端增量**
//  （帧 8/9 既有原语），与文件传输**完全解耦**（不碰 file_* / manifest / 选择集）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  和 SyncCollectionSyncCoordinator 的分工
//  ════════════════════════════════════════════════════════════════════════════
//  - `SyncCollectionSyncCoordinator` = 「选中集合的**文件**补齐编排」（传歌传歌词）。
//  - 本类 = 「**播放数据**（收藏 / 播放历史 / 歌单结构）changeLog 增量同步」：
//    不依赖任何文件传输，也不依赖选择集，两端都能独立发起一次。
//
//  ⚠️ 本包只做**核心层**（平台无关、可单测、不直连 `.shared`）：iOS/Mac 的装配
//  （面板按钮、会话建立后自动跑、与文件编排的先后）不在本包范围。
//
//  ════════════════════════════════════════════════════════════════════════════
//  一次编排
//  ════════════════════════════════════════════════════════════════════════════
//    ① pushing：`SyncChangeLogPeer.sendIncrement`（帧 9）——把本端 outbox 中
//       id > **sync_push_cursor(peerID)** 的增量分批推给对端（每批末行 id 作游标，
//       delete 不上线；正是 S1 审计修出的口径）。
//    ② pulling：`SyncChangeLogPeer.sendPull`（帧 8）——请求对端把它 outbox 中
//       > 本端游标（sync_cursor）的增量回推。应答帧 9 由**本类持有的**
//       `SyncChangeLogPeer` 按既有本地化 → LWW → 落库（本地缺歌挂起）路径处理。
//    ③ finished：账目（pushed/applied/suspended/ignoredDeletes）见 `report`；
//       超时未收到应答 → finished + `failureMessage`（不静默挂死）。
//
//  ⚠️ 结果账目（2026-09-15 起）= **(实体, 结果) 二维**：回调按**实体分组**上报
//  （`[SyncEntityOutcomeCount]`），本类只往唯一存储 `reportValue.tally` 里累加；
//  面板的「按实体披露」明细行由 `SyncEntityOutcomeDisclosure` 从同一份账目派生。
//
//  ⚠️ pull 应答可重试（2026-11-03）：一次应答窗口内没收到应答不再直接失败——同轮内重发 pull
//  （默认 3 次，间隔 2s / 5s）；对端回 notReady（曲库未就绪）按 2s / 5s / 10s
//  退避，总窗口 ≤60s。迟到帧只累加账目、不二次收尾（finish 幂等）；
//  取消 / 断连立即中止（在途的退避重发一并取消）。
//
//  ⚠️ 拉取方向的应收数 = 帧 9 到达（本端 peer 的 onPushApplied / onPushSuspended /
//  onPushIgnoredDeletes / onPushUnresolved / onPushUnsupported 五者**累加**回填账目）。五个回调**任一**到达即视为
//  「对端已应答」——`handlePush` 内五者总是同步顺序触发，不在其中挑一个「最后一个」当判据
//  （那会把正确性押在别人代码的调用顺序上）；账目后续帧继续累加，收尾后仍可能被迟到帧回填。
//
//  ⚠️ 两个**本端发送侧**回调（onIncrementMissingIdentity / onPullMissingIdentity）只累加
//  账目（pushedMissingIdentityEntries），**绝不触发收尾**：前者在 `start()` 的推送阶段同步
//  触发（此时还没发帧 8，收尾会把拉取路径切断）；后者由**入站**帧 8 触发，与「对端应答了
//  本端的拉取」无关。
//
//  ⚠️ 必须先持有 peer 再发帧：`SyncChangeLogPeer` 以 `[weak self]` 挂接会话回调，
//  不持有则永不应答（同 `SyncPlaybackCarryPeer` 的既有教训）；同时它的回调必须在
//  `sendPull` **之前**装好——内存回环下应答会在本调用内同步回来。
//
//  线程：会话线程同步驱动；内部锁保护状态与账目，回调一律**锁外**触发；
//  不做任何 UI / 主线程假设。
//

import Foundation

// 状态 / 账目模型（`SyncDataSyncPhase` / `SyncDataSyncReport`）已抽到
// `SyncDataSyncReport.swift`（文件行数结构预算）；收帧账目在 `+Ledger` 扩展。

// MARK: - 编排器

/// 「同步数据」（收藏 / 播放历史 / 歌单结构）的会话级编排：一次推 + 一次拉。
/// 一个会话一个实例（调用方持有并展示状态；本类不含 UI、不含平台分支）。
final class SyncDataSyncCoordinator: @unchecked Sendable {
    /// 阶段（internal：账目扩展 `SyncDataSyncCoordinator+Ledger` 需要读写）。
    enum Stage {
        case idle
        case pushing
        case pulling
        case finished
    }

    private let session: SyncPeerSession
    private let database: DatabaseManager
    /// 曲库根（**必传**）：跨端身份入口的输入，第二身份（相对路径）的换算基准。
    private let libraryRoot: URL
    private let store: SyncChangeLogStore
    private let applier: SyncChangeLogApplier
    /// 本端视角的对端 Device ID（推/拉游标键；空 = 会话未握手，不干活）。
    let resolvedPeerID: String

    /// 等对端应答帧 9 的超时定时（专用串行队列，同 `SyncPeerLibraryClient.timeoutQueue` 做法）。
    private let timeoutQueue = DispatchQueue(label: "qqplayer.sync.data-sync.timeout", qos: .utility)

    /// ⚠️ internal：账目扩展（+Ledger）与本文件共享同一把锁。
    let lock = NSLock()
    var stage: Stage = .idle
    private var phaseValue: SyncDataSyncPhase = .idle
    var reportValue = SyncDataSyncReport()
    /// ⚠️ 必须强持有：peer 以 `[weak self]` 挂接会话回调，弃之则永不处理入站帧
    /// （拉取应答收不到 / 推送回执全丢）。
    private var peerValue: SyncChangeLogPeer?
    private var timeoutItem: DispatchWorkItem?

    /// pull 应答等待的重试策略（注入：单测把间隔压到毫秒级）。
    private let retryPolicy: SyncPullRetryPolicy
    /// 本次拉取已发出的 change_log_pull 次数（1 = 首次）。
    /// ⚠️ internal：账目扩展（+Ledger）的日志行要读「第几次尝试」。
    var pullAttempt = 0
    /// 当前这段「等应答 / 等退避」的起点（notReady 总窗口的计时基准）。
    private var pullWindowStartedAt = Date()
    /// 当前这段是否因 notReady 而重试（决定用哪套退避表）。
    private var awaitingNotReadyRetry = false
    /// 退避重发的调度句柄（取消 / 收尾时一并取消）。
    private var retryItem: DispatchWorkItem?
    /// 重发代际：旧代际的调度即使漏网也不得再发帧。
    private var retryGeneration = 0
    /// 单次应答窗口（秒）——start(timeout:) 传入，后续每次重发沿用同一窗口。
    private var answerWindow: TimeInterval = 20
    /// 本次 pull 的请求标识（诊断 / 去重；应答原样回带，**不参与接受判定**）。
    private var pullRequestID = ""
    /// 当前这次 pull 请求是否已计过一次应答（应答批会触发多个回调，只算一次）。
    var pullAnswerCounted = false
    /// SYNCDIAG `kind=frame` 观测行（INV-37：链路事实必须落盘；只观测不判定）。
    private var frameDiag: SyncDiagAttempt?

    /// pull 请求标识：`<attempt>-<毫秒时间戳>`（可读、可 grep、无需 UUID 依赖）。
    /// 只用于把应答与请求串起来（诊断 / 去重），**绝不用它拒收应答**。
    private static func makePullRequestID(attempt: Int) -> String {
        "\(attempt)-\(Int(Date().timeIntervalSince1970 * 1_000))"
    }

    /// 每阶段回调（锁外触发；会话线程/超时队列）。
    var onStateChange: (@Sendable (SyncDataSyncPhase) -> Void)?

    init(
        session: SyncPeerSession,
        database: DatabaseManager = .shared,
        peerID: String? = nil,
        retryPolicy: SyncPullRetryPolicy = .standard,
        libraryRoot: URL
    ) {
        self.session = session
        self.database = database
        self.store = SyncChangeLogStore(database: database)
        self.libraryRoot = libraryRoot
        self.retryPolicy = retryPolicy
        var applier = SyncChangeLogApplier(database: database)
        // 跨端续播（默认关）：开关开且落点可用才注入落点；关 = 本端不接受播放位置（INV-26）。
        if applier.playbackPositionSyncEnabled {
            applier.playbackPositionSink = { PlaybackPositionResumeSink.apply($0) }
        }
        self.applier = applier
        // peerID 缺省 = 会话握手得到的对端 Device ID（与 SyncChangeLogPeer.peerID 同语义）；
        // 显式传入但为空串（含全空白）= 调用方给错 → 不回落，直接留空让 start() 立即失败
        // （静默回落会把「参数错了」伪装成「同步成功」，比显式失败更难查）。
        if let peerID {
            self.resolvedPeerID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.resolvedPeerID = session.peerHelloValue?.deviceID ?? ""
        }
    }

    // MARK: 对外状态

    var phase: SyncDataSyncPhase {
        lock.lock()
        defer { lock.unlock() }
        return phaseValue
    }

    /// 账目**实时值**（收尾后仍可能被迟到的帧回填，见文件头注释）。
    var report: SyncDataSyncReport {
        lock.lock()
        defer { lock.unlock() }
        return reportValue
    }

    // MARK: 生命周期

    /// 开始一次「同步数据」：推本端增量 → 拉对端增量 → 收尾。
    ///
    /// - 上一轮未收尾（进行中）时**静默忽略**本轮（幂等；本类不抛错，失败一律进
    ///   `report.failureMessage`，调用方只看账目即可）。
    /// - `peerID` 为空（会话未握手完成）→ **立即 finished + failureMessage**，
    ///   绝不拿空串当游标键写脏数据。
    /// - `timeout` = 等对端应答帧 9 的上限（秒）；对端 App 不在前台就不会应答，
    ///   没有上限 = 调用方看到「点了没反应」。`<= 0` = 不启用超时。
    func start(timeout: TimeInterval = 20) {
        let peerID = resolvedPeerID
        guard !peerID.isEmpty else {
            finish(failure: "缺少对端 Device ID（会话尚未完成握手/未配对）")
            return
        }
        lock.lock()
        guard stage == .idle || stage == .finished else {
            lock.unlock()
            return
        }
        retryItem?.cancel()
        retryItem = nil
        retryGeneration += 1
        pullAttempt = 0
        awaitingNotReadyRetry = false
        pullWindowStartedAt = Date()
        answerWindow = timeout
        reportValue.waitingKey = nil
        reportValue.pullAttempts = 0
        reportValue.pullSent = 0
        reportValue.pullRecv = 0
        reportValue.pullLate = 0
        reportValue.pullDuplicates = 0
        reportValue.notReadyReason = nil
        reportValue.retryCountdownSeconds = nil
        lock.unlock()
        // 帧往返观测行：本轮结束（finish）时落一行，字段见 SyncDiagLinkFacts。
        frameDiag = SyncDiagAttempt(
            kind: .frame,
            role: session.role.rawValue,
            channel: .session,
            peerDeviceID: peerID
        )
        lock.lock()
        let peer = SyncChangeLogPeer(
            session: session,
            store: store,
            applier: applier,
            peerID: peerID,
            libraryRoot: libraryRoot
        )
        // 先装回调再发帧：内存回环下应答会在 sendPull 内同步回来。
        peer.onPushApplied = { [weak self] count in self?.recordApplied(count) }
        peer.onPushSuspended = { [weak self] groups in self?.recordAnswered(.suspended, groups: groups) }
        peer.onPushUnresolved = { [weak self] groups in self?.recordAnswered(.unresolved, groups: groups) }
        peer.onPushAmbiguous = { [weak self] groups in
            self?.recordAnswered(.ambiguousIdentity, groups: groups)
        }
        peer.onPushSkippedMissingParent = { [weak self] groups in
            self?.recordAnswered(.skippedMissingParent, groups: groups)
        }
        peer.onPushUnsupported = { [weak self] groups in
            self?.recordAnswered(.unsupported, groups: groups)
        }
        // 应用失败（歌单级失败等）：同样算「对端已应答」——批次已中断，不必再等超时。
        peer.onPushApplyFailed = { [weak self] groups in
            self?.recordAnswered(.applyFailed, groups: groups)
        }
        // 时钟超前门（契约 B1 / INV-34）：对端时间戳来自未来的行不应用，按实体计数上屏。
        peer.onPushFutureTimestamp = { [weak self] groups in
            self?.recordAnswered(.futureTimestamp, groups: groups)
        }
        peer.onPushIgnoredDeletes = { [weak self] count in self?.recordIgnoredDeletes(count) }
        // 对端未就绪（notReady）：不是「应答成功」，也不是立刻失败的理由 → 退避重试。
        peer.onPushNotReady = { [weak self] reason in self?.handleNotReadyAnswer(reason: reason) }
        // INV-36：重复批 = 已应用过（游标之内）→ 不重复应用，但仍算「对端已应答」。
        peer.onPushDuplicate = { [weak self] count in self?.recordDuplicateBatch(count) }
        // 发送侧缺身份键：只累加账目，**不收尾**（见文件头：推送阶段触发 / 入站帧触发，
        // 两者都不是「对端应答了本端拉取」）。
        peer.onIncrementMissingIdentity = { [weak self] groups in
            self?.recordPushedMissingIdentity(groups)
        }
        peer.onPullMissingIdentity = { [weak self] groups in
            self?.recordPushedMissingIdentity(groups)
        }
        stage = .pushing
        peerValue = peer
        lock.unlock()
        emit(phase: .pushing)

        // ① 推送本端增量（帧 9；分批，全部成功后推进 sync_push_cursor）
        do {
            let pushed = try peer.sendIncrement()
            lock.lock()
            // 批次事实（「最近一批发出行数」）→ 覆盖写，不累加（与收口前 `= pushed` 同口径）。
            reportValue.tally.overwrite(.outbound, with: pushed)
            lock.unlock()
        } catch {
            finish(failure: "推送增量失败：\(error)")
            return
        }

        // ② 拉取对端增量（帧 8）
        lock.lock()
        guard stage != .finished else { // 推送期间若已收到对端帧并收尾，不再发拉取
            lock.unlock()
            return
        }
        stage = .pulling
        pullAttempt = 1
        pullWindowStartedAt = Date()
        awaitingNotReadyRetry = false
        reportValue.pullAttempts = 1
        pullRequestID = Self.makePullRequestID(attempt: 1)
        pullAnswerCounted = false
        reportValue.pullSent += 1
        let window = answerWindow
        let requestID = pullRequestID
        lock.unlock()
        emit(phase: .pulling)
        // 到点检查必须在**发请求之前**就位（否则「发送」这段本身不受超时约束；
        // 同 SyncCollectionSyncCoordinator 的 S2 修复）。
        scheduleTimeout(seconds: window)
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 发起 change_log_pull（第 1/\(retryPolicy.maxAttempts) 次，"
                + "应答窗口 \(window)s，peer=\(peerID)）"
        )
        do {
            try peer.sendPull(requestID: requestID)
        } catch {
            finish(failure: "请求拉取失败：\(error)")
        }
    }

    /// 中止（会话关闭 / 调用方取消）：停等应答，落 finished。
    func cancel() {
        finish(failure: "cancelled")
    }

    // MARK: 超时

    private func scheduleTimeout(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.answerWindowElapsed()
        }
        lock.lock()
        timeoutItem = item
        lock.unlock()
        timeoutQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// 应答窗口到点仍没收到任何应答帧：同轮内重发 pull；次数用尽才落失败。
    /// 快照（第几次 / 是否 notReady）与「要不要重发」在同一次持锁内取，
    /// 与 record 系列的收尾互斥（应答一到，到点检查必被挡回）。
    private func answerWindowElapsed() {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
        let attempt = pullAttempt
        let notReady = awaitingNotReadyRetry
        let elapsed = Date().timeIntervalSince(pullWindowStartedAt)
        lock.unlock()

        let delay = notReady
            ? retryPolicy.notReadyRetryDelay(afterAttempt: attempt, elapsed: elapsed)
            : retryPolicy.noAnswerRetryDelay(afterAttempt: attempt)
        guard let delay else {
            if notReady {
                finish(
                    failure: "对端持续未就绪（曲库整理中；已尝试 \(attempt) 次）",
                    failureKey: SyncDataSyncMessageKey.notReadyTimeout
                )
            } else {
                finish(
                    failure: "对端无应答（已重试 \(attempt) 次；对端可能正在整理曲库或处理上一批数据）",
                    failureKey: SyncDataSyncMessageKey.noAnswerTimeout
                )
            }
            return
        }
        let retryNumber = attempt + 1
        let maxAttempts = notReady ? retryPolicy.notReadyMaxAttempts : retryPolicy.maxAttempts
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: pull 第 \(attempt)/\(maxAttempts) 次"
                + "\(notReady ? "未就绪" : "无应答")，\(delay)s 后重发第 \(retryNumber) 次"
        )
        scheduleRetry(after: delay, notReady: notReady)
    }

    /// 收到对端 notReady：不是应答成功，按退避重试；次数 / 窗口耗尽才失败。
    /// 参数 = 对端回带的原因（导入中 / 曲库整理；nil = 旧端未带）。
    private func handleNotReadyAnswer(reason: SyncChangeLogNotReadyReason?) {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
        reportValue.notReadyReason = reason
        let attempt = pullAttempt
        let elapsed = Date().timeIntervalSince(pullWindowStartedAt)
        lock.unlock()
        cancelTimeout()

        let delay = retryPolicy.notReadyRetryDelay(afterAttempt: attempt, elapsed: elapsed)
        guard let delay else {
            finish(
                failure: "对端持续未就绪（曲库整理中；已尝试 \(attempt) 次）",
                failureKey: SyncDataSyncMessageKey.notReadyTimeout
            )
            return
        }
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 对端回 notReady（第 \(attempt) 次），\(delay)s 后重试"
        )
        scheduleRetry(after: delay, notReady: true)
    }

    /// 排程一次重发；代际递增，旧代际的漏网任务不得再发帧。
    private func scheduleRetry(after seconds: TimeInterval, notReady: Bool) {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
        retryGeneration += 1
        let generation = retryGeneration
        retryItem?.cancel()
        reportValue.waitingKey = notReady
            ? SyncDataSyncMessageKey.peerPreparing
            : SyncDataSyncMessageKey.retryingNoAnswer
        // 倒计时（面板「X 秒后自动重试」）：只对 notReady 展示具体秒数。
        reportValue.retryCountdownSeconds = notReady
            ? max(1, Int(seconds.rounded(.up)))
            : nil
        let item = DispatchWorkItem { [weak self] in
            self?.retryPull(generation: generation, notReady: notReady)
        }
        retryItem = item
        lock.unlock()
        timeoutQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func retryPull(generation: Int, notReady: Bool) {
        lock.lock()
        guard stage == .pulling, retryGeneration == generation else {
            lock.unlock()
            return
        }
        pullAttempt += 1
        pullWindowStartedAt = Date()
        awaitingNotReadyRetry = notReady
        reportValue.pullAttempts = pullAttempt
        reportValue.waitingKey = nil
        reportValue.retryCountdownSeconds = nil
        pullRequestID = Self.makePullRequestID(attempt: pullAttempt)
        pullAnswerCounted = false
        reportValue.pullSent += 1
        retryItem = nil
        let attempt = pullAttempt
        let window = answerWindow
        let requestID = pullRequestID
        lock.unlock()

        let maxAttempts = notReady ? retryPolicy.notReadyMaxAttempts : retryPolicy.maxAttempts
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 重发 change_log_pull（第 \(attempt)/\(maxAttempts) 次，"
                + "应答窗口 \(window)s）"
        )
        scheduleTimeout(seconds: window)
        do {
            try peerValue?.sendPull(requestID: requestID)
        } catch {
            finish(failure: "请求拉取失败：\(error)")
        }
    }

    private func cancelTimeout() {
        lock.lock()
        let item = timeoutItem
        timeoutItem = nil
        lock.unlock()
        item?.cancel()
    }

    /// 取消在途的退避重发（会话关闭 / 取消 / 收尾时调用；代际递增让漏网任务也发不出帧）。
    private func cancelRetry() {
        lock.lock()
        let item = retryItem
        retryItem = nil
        retryGeneration += 1
        lock.unlock()
        item?.cancel()
    }

    // MARK: 收尾

    /// 落终态（幂等：已 finished 则只保留首次结论——成功不会被迟到的超时覆盖，
    /// 失败也不会被后续迟到帧冲掉原因）。回调锁外触发。
    func finish(failure: String?, failureKey: String? = nil) {
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        if let failure {
            reportValue.failureMessage = failure
            reportValue.failureKey = failureKey
        }
        reportValue.waitingKey = nil
        reportValue.retryCountdownSeconds = nil
        reportValue.isFinished = true
        // 阶段与 isFinished 必须**同一次持锁内**一起翻页：否则观察者可能先看到
        // 「已收尾」再看到 phase 仍是 .pulling（T1 前就在，T1 加观测行后窗口变宽才暴露）。
        phaseValue = .finished
        lock.unlock()
        cancelTimeout()
        cancelRetry()
        emitFrameDiagIfNeeded()
        onStateChange?(.finished)
    }

    /// SYNCDIAG kind=frame（INV-37）：本轮 pull 往返 + 链路事实落盘。
    /// 只观测，不改判定；`SyncDiagAttempt.finish` 幂等（重复收尾只落一行）。
    private func emitFrameDiagIfNeeded() {
        guard let diag = frameDiag else { return }
        lock.lock()
        var facts = session.linkFacts
        facts.importing = reportValue.notReadyReason == .importing
        facts.pullSent = reportValue.pullSent
        facts.pullRecv = reportValue.pullRecv
        facts.pullLate = reportValue.pullLate
        lock.unlock()
        diag.setFacts(facts)
        diag.finish()
    }

    private func emit(phase: SyncDataSyncPhase) {
        lock.lock()
        phaseValue = phase
        lock.unlock()
        onStateChange?(phase)
    }
}
