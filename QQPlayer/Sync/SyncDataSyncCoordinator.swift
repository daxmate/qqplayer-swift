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

// MARK: - 状态 / 账目

/// 一次「同步数据」的阶段。
enum SyncDataSyncPhase: Equatable, Sendable {
    case idle
    /// 正在推送本端增量（帧 9）
    case pushing
    /// 已发起拉取（帧 8），等对端应答帧 9
    case pulling
    /// 收尾（成功或失败，见 report.failureMessage）
    case finished
}

/// 一次「同步数据」的账目（调用方只消费，不参与决策）。
///
/// ⚠️ 计数**不在这里维护**：唯一存储 = `tally`（`SyncOutcomeTally`，与 iOS 面板**同一类型**），
/// 下面这些读数是它的投影——面板读的名字不变（UI 零改动），但「谁来加这个数」全仓只剩
/// `tally.accumulate(…)` 一处（L6：失败/结果枚举化 + 两套账目收口）。
struct SyncDataSyncReport: Equatable, Sendable {
    /// **唯一**结果账目（见 `SyncRowOutcome` / `SyncOutcomeTally`）。
    var tally = SyncOutcomeTally()
    /// 本端 outbox 增量行数（含被过滤的 delete，口径同 `handlePull` 的计数）；空增量 = 0
    var pushedEntries: Int { tally.outboundEntries }
    /// 对端推来的帧 9 中实际落到本地业务表的行数
    var appliedEntries: Int { tally.appliedEntries }
    /// 对端推来的行里因本地缺歌而挂起的行数（歌到位后重放，不丢数据）
    var suspendedEntries: Int { tally.suspendedEntries }
    /// 拉取方向：对端推来的行里因**缺身份键**（两把键都拿不到）而**未落库**的行数
    /// （无法定位到本地歌曲 → 落库也永远不可见；见 `SyncEntryLocalization.unresolved`）
    var unresolvedEntries: Int { tally.unresolvedEntries }
    /// 拉取方向：对端推来的行里因**身份歧义**（第二身份相对路径命中多首本地曲目）
    /// 而未落库的行数（不落库、不挂起——选哪首都是猜）
    var ambiguousIdentityEntries: Int { tally.ambiguousIdentityEntries }
    /// 拉取方向：对端推来的 `playback_position` 行里**没有落到本地位置**的行数
    /// （跨端续播开关关 = 默认，或开关开但本端落点未接；见 `SyncChangeLogApplier`）。
    /// ⚠️ 这些行**不计入 `appliedEntries`**——「已应用」= 真的落了本地（INV-20）。
    var unsupportedEntries: Int { tally.unsupportedEntries }
    /// 拉取方向：对端推来的行里因**父行/被引用行不存在**而跳过的行数
    /// （歌单结构未到 / 引用歌本地查无；矩阵三级 #8：以前静默失败，现在必须可见）
    var skippedMissingParentEntries: Int { tally.skippedMissingParentEntries }
    /// 推送方向：本端发出去的行里缺身份键的条数（对端定位不了它们；含主动推增量
    /// 与应答对方拉取两个方向）
    var pushedMissingIdentityEntries: Int { tally.missingIdentityEntries }
    /// 对端推来的行里被忽略的 delete 行数（删除不跨端传播）
    var ignoredDeletes: Int { tally.ignoredDeletes }
    /// 对端推来的行里**应用失败**的行数（载荷解不开 / 落库抛错；不落库、计入缺口）
    var applyFailedEntries: Int { tally.applyFailedEntries }
    /// 失败原因的本地化 key（新路径；nil = 用 failureMessage 原文——旧文案保持不变）。
    var failureKey: String?
    /// 等待对端的提示 key（nil = 不在等待；UI 按 key 取文案）。
    var waitingKey: String?
    /// 本次拉取已发出的 change_log_pull 次数（1 = 只发了首次；>1 = 同轮内重发过）。
    var pullAttempts: Int = 0
    /// 失败原因（nil = 未失败；「缺 peerID / 推失败 / 发拉取失败 / 对端无应答」/ cancelled）
    var failureMessage: String?
    /// 是否已收尾（与 `phase == .finished` 同义；冗余存一份便于调用方只读 report）
    var isFinished: Bool = false
}

// MARK: - 编排器

/// 「同步数据」（收藏 / 播放历史 / 歌单结构）的会话级编排：一次推 + 一次拉。
/// 一个会话一个实例（调用方持有并展示状态；本类不含 UI、不含平台分支）。
final class SyncDataSyncCoordinator: @unchecked Sendable {
    private enum Stage {
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
    private let resolvedPeerID: String

    /// 等对端应答帧 9 的超时定时（专用串行队列，同 `SyncPeerLibraryClient.timeoutQueue` 做法）。
    private let timeoutQueue = DispatchQueue(label: "qqplayer.sync.data-sync.timeout", qos: .utility)

    private let lock = NSLock()
    private var stage: Stage = .idle
    private var phaseValue: SyncDataSyncPhase = .idle
    private var reportValue = SyncDataSyncReport()
    /// ⚠️ 必须强持有：peer 以 `[weak self]` 挂接会话回调，弃之则永不处理入站帧
    /// （拉取应答收不到 / 推送回执全丢）。
    private var peerValue: SyncChangeLogPeer?
    private var timeoutItem: DispatchWorkItem?

    /// pull 应答等待的重试策略（注入：单测把间隔压到毫秒级）。
    private let retryPolicy: SyncPullRetryPolicy
    /// 本次拉取已发出的 change_log_pull 次数（1 = 首次）。
    private var pullAttempt = 0
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
        peer.onPushIgnoredDeletes = { [weak self] count in self?.recordIgnoredDeletes(count) }
        // 对端未就绪（notReady）：不是「应答成功」，也不是立刻失败的理由 → 退避重试。
        peer.onPushNotReady = { [weak self] in self?.handleNotReadyAnswer() }
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
        let window = answerWindow
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
            try peer.sendPull()
        } catch {
            finish(failure: "请求拉取失败：\(error)")
        }
    }

    /// 中止（会话关闭 / 调用方取消）：停等应答，落 finished。
    func cancel() {
        finish(failure: "cancelled")
    }

    // MARK: 收帧账目（peer 回调 → 锁外）

    private func recordApplied(_ count: Int) {
        lock.lock()
        let wasFinished = stage == .finished
        reportValue.tally.accumulate(.applied, count: count)
        lock.unlock()
        logAnswerReceived(wasFinished: wasFinished, applied: count, groups: nil)
        finish(failure: nil)
    }

    /// 拉取方向：把一类结果的**按实体分组**累加进账目并收尾。
    ///
    /// 收尾语义与收口前逐字一致：这些回调**任一到达**即视为「对端已应答」
    /// （挂起 / 未定位即使空数组也上报 → 空数组 = 累加零条 + 照常收尾）。
    private func recordAnswered(_ outcome: SyncRowOutcome, groups: [SyncEntityOutcomeCount]) {
        lock.lock()
        let wasFinished = stage == .finished
        for group in groups {
            reportValue.tally.accumulate(outcome, entity: group.entity, count: group.count)
        }
        lock.unlock()
        logAnswerReceived(wasFinished: wasFinished, applied: nil, groups: groups)
        finish(failure: nil)
    }

    /// 「收到应答 / 迟到帧」各一行（info）：收尾后再来的帧只累加账目，不二次收尾。
    private func logAnswerReceived(
        wasFinished: Bool,
        applied: Int?,
        groups: [SyncEntityOutcomeCount]?
    ) {
        if wasFinished {
            AppLog.info(
                .sync,
                "ℹ️ SyncDataSyncCoordinator: 已收尾会话收到迟到的应答帧（只累加账目，不二次收尾；peer=\(resolvedPeerID)）"
            )
            return
        }
        let detail: String
        if let applied {
            detail = "应用 \(applied) 行"
        } else {
            let total = (groups ?? []).reduce(0) { $0 + $1.count }
            detail = "分组应答 \(total) 行"
        }
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 收到对端应答（\(detail)，第 \(pullAttempt) 次尝试；peer=\(resolvedPeerID)）"
        )
    }

    /// 发送方向：本端发出去但缺身份键的行数（按实体分组）。**只累加，不收尾**——这不是
    /// 「对端应答」。
    private func recordPushedMissingIdentity(_ groups: [SyncEntityOutcomeCount]) {
        lock.lock()
        for group in groups {
            reportValue.tally.accumulate(.missingIdentity, entity: group.entity, count: group.count)
        }
        lock.unlock()
    }

    private func recordIgnoredDeletes(_ count: Int) {
        lock.lock()
        reportValue.tally.accumulate(.ignoredDelete, count: count)
        lock.unlock()
        finish(failure: nil)
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
    private func handleNotReadyAnswer() {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
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
        retryItem = nil
        let attempt = pullAttempt
        let window = answerWindow
        lock.unlock()

        let maxAttempts = notReady ? retryPolicy.notReadyMaxAttempts : retryPolicy.maxAttempts
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 重发 change_log_pull（第 \(attempt)/\(maxAttempts) 次，"
                + "应答窗口 \(window)s）"
        )
        scheduleTimeout(seconds: window)
        do {
            try peerValue?.sendPull()
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
    private func finish(failure: String?, failureKey: String? = nil) {
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
        reportValue.isFinished = true
        lock.unlock()
        cancelTimeout()
        cancelRetry()
        emit(phase: .finished)
    }

    private func emit(phase: SyncDataSyncPhase) {
        lock.lock()
        phaseValue = phase
        lock.unlock()
        onStateChange?(phase)
    }
}
