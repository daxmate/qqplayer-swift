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
struct SyncDataSyncReport: Equatable, Sendable {
    /// 本端 outbox 增量行数（含被过滤的 delete，口径同 `handlePull` 的计数）；空增量 = 0
    var pushedEntries: Int = 0
    /// 对端推来的帧 9 中实际落到本地业务表的行数
    var appliedEntries: Int = 0
    /// 对端推来的行里因本地缺歌而挂起的行数（歌到位后重放，不丢数据）
    var suspendedEntries: Int = 0
    /// 拉取方向：对端推来的行里因**缺身份键**（contentHash nil/空）而**未落库**的行数
    /// （无法定位到本地歌曲 → 落库也永远不可见；见 `SyncEntryLocalization.unresolved`）
    var unresolvedEntries: Int = 0
    /// 拉取方向：对端推来的 `playback_position` 行里**没有落到本地位置**的行数
    /// （跨端续播开关关 = 默认，或开关开但本端落点未接；见 `SyncChangeLogApplier`）。
    /// ⚠️ 这些行**不计入 `appliedEntries`**——「已应用」= 真的落了本地（INV-20）。
    var unsupportedEntries: Int = 0
    /// 拉取方向：对端推来的行里因**父行/被引用行不存在**而跳过的行数
    /// （歌单结构未到 / 引用歌本地查无；矩阵三级 #8：以前静默失败，现在必须可见）
    var skippedMissingParentEntries: Int = 0
    /// 推送方向：本端发出去的行里缺身份键的条数（对端定位不了它们；含主动推增量
    /// 与应答对方拉取两个方向）
    var pushedMissingIdentityEntries: Int = 0
    /// 对端推来的行里被忽略的 delete 行数（删除不跨端传播）
    var ignoredDeletes: Int = 0
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

    /// 每阶段回调（锁外触发；会话线程/超时队列）。
    var onStateChange: ((SyncDataSyncPhase) -> Void)?

    init(
        session: SyncPeerSession,
        database: DatabaseManager = .shared,
        peerID: String? = nil
    ) {
        self.session = session
        self.database = database
        self.store = SyncChangeLogStore(database: database)
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
        let peer = SyncChangeLogPeer(
            session: session,
            store: store,
            applier: applier,
            peerID: peerID
        )
        // 先装回调再发帧：内存回环下应答会在 sendPull 内同步回来。
        peer.onPushApplied = { [weak self] count in self?.recordApplied(count) }
        peer.onPushSuspended = { [weak self] count in self?.recordSuspended(count) }
        peer.onPushUnresolved = { [weak self] count in self?.recordUnresolved(count) }
        peer.onPushSkippedMissingParent = { [weak self] count in
            self?.recordSkippedMissingParent(count)
        }
        peer.onPushUnsupported = { [weak self] count in self?.recordUnsupported(count) }
        peer.onPushIgnoredDeletes = { [weak self] count in self?.recordIgnoredDeletes(count) }
        // 发送侧缺身份键：只累加账目，**不收尾**（见文件头：推送阶段触发 / 入站帧触发，
        // 两者都不是「对端应答了本端拉取」）。
        peer.onIncrementMissingIdentity = { [weak self] count in self?.recordPushedMissingIdentity(count) }
        peer.onPullMissingIdentity = { [weak self] count in self?.recordPushedMissingIdentity(count) }
        stage = .pushing
        peerValue = peer
        lock.unlock()
        emit(phase: .pushing)

        // ① 推送本端增量（帧 9；分批，全部成功后推进 sync_push_cursor）
        do {
            let pushed = try peer.sendIncrement()
            lock.lock()
            reportValue.pushedEntries = pushed
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
        lock.unlock()
        emit(phase: .pulling)
        // 到点检查必须在**发请求之前**就位（否则「发送」这段本身不受超时约束；
        // 同 SyncCollectionSyncCoordinator 的 S2 修复）。
        scheduleTimeout(seconds: timeout)
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
        reportValue.appliedEntries += count
        lock.unlock()
        finish(failure: nil)
    }

    private func recordSuspended(_ count: Int) {
        lock.lock()
        reportValue.suspendedEntries += count
        lock.unlock()
        finish(failure: nil)
    }

    /// 拉取方向：对端推来的行里因缺身份键未落库的行数（与其它三个「应答已到」回调用同一收尾语义）。
    private func recordUnresolved(_ count: Int) {
        lock.lock()
        reportValue.unresolvedEntries += count
        lock.unlock()
        finish(failure: nil)
    }

    /// 拉取方向：对端推来的播放位置行**没落地**（跨端续播关 = 默认 / 落点未接）。
    /// 与其它四个「应答已到」回调用同一收尾语义；applier 侧已保证这些行不计 applied。
    private func recordUnsupported(_ count: Int) {
        lock.lock()
        reportValue.unsupportedEntries += count
        lock.unlock()
        finish(failure: nil)
    }

    /// 拉取方向：对端推来的行里因**父行 / 被引用行不存在**而跳过的行数（矩阵三级 #8：
    /// 以前静默失败，现在必须计数上屏）。与其它「应答已到」回调用同一收尾语义。
    private func recordSkippedMissingParent(_ count: Int) {
        lock.lock()
        reportValue.skippedMissingParentEntries += count
        lock.unlock()
        finish(failure: nil)
    }

    /// 发送方向：本端发出去但缺身份键的行数。**只累加，不收尾**——这不是「对端应答」。
    private func recordPushedMissingIdentity(_ count: Int) {
        lock.lock()
        reportValue.pushedMissingIdentityEntries += count
        lock.unlock()
    }

    private func recordIgnoredDeletes(_ count: Int) {
        lock.lock()
        reportValue.ignoredDeletes += count
        lock.unlock()
        finish(failure: nil)
    }

    // MARK: 超时

    private func scheduleTimeout(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.failWhileWaitingForAnswer()
        }
        lock.lock()
        timeoutItem = item
        lock.unlock()
        timeoutQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// 仅当**仍在等应答**时落失败：判定与置终态在**同一次持锁内**完成，
    /// 与 `record*` 的收尾互斥（应答一到，到点检查必被挡回）。
    private func failWhileWaitingForAnswer() {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
        lock.unlock()
        finish(failure: "对端无应答（等待超时；请确认对端 QQPlayer 在前台并已连接）")
    }

    private func cancelTimeout() {
        lock.lock()
        let item = timeoutItem
        timeoutItem = nil
        lock.unlock()
        item?.cancel()
    }

    // MARK: 收尾

    /// 落终态（幂等：已 finished 则只保留首次结论——成功不会被迟到的超时覆盖，
    /// 失败也不会被后续迟到帧冲掉原因）。回调锁外触发。
    private func finish(failure: String?) {
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        if let failure {
            reportValue.failureMessage = failure
        }
        reportValue.isFinished = true
        lock.unlock()
        cancelTimeout()
        emit(phase: .finished)
    }

    private func emit(phase: SyncDataSyncPhase) {
        lock.lock()
        phaseValue = phase
        lock.unlock()
        onStateChange?(phase)
    }
}
