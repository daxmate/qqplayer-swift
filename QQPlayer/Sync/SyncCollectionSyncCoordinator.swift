//
//  SyncCollectionSyncCoordinator.swift
//  QQPlayer
//
//  T7（2026-09-11）同步方向改造 · **选中集合的单向补齐编排**（Mac 发起，方向由用户显式选择）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  语义（docs/lan-sync-design.md §6.1 + §12b 决策 6-10）
//  ════════════════════════════════════════════════════════════════════════════
//  决策 9：同步集合 = 用户显式勾选的歌单（收藏视为特殊歌单）→ 目标端缺的歌自动补齐。
//  决策 10：不做全库自动镜像（选择性集合是默认路径）。
//  决策 7：**绝不跨端删除**——对端多出来的条目**什么都不做**（只记账，不动手）。
//  决策 6：发起方恒为 Mac，两个方向都在 Mac 上编排。
//
//  R3b（2026-09-11）追加第 ③.5 步：每个方向传输完**跟着歌把该歌的播放数据带过去**
//  （决策 8「跟歌走」）——由注入的 `SyncPlaybackCarryDriving` 执行（生产实现
//  `SyncPlaybackCarryPeer`，走既有帧 8/9 原语 + 既有映射/LWW/落库路径）；
//  未注入 = 不携带（R3a 行为零变化）。
//
//  一次编排 = 计划 + **一个方向**：
//    ① 展开选择集（`SyncCollectionExpander`，注入取曲库事实）
//    ② 请求对端（设备）manifest（帧 10/11）——请求集合按方向取
//       （`SyncCollectionSelection.remoteRequestCollection(for:)`）
//    ③ 按方向算期望集合（`SyncExpectedPlanner`）→ 单向差集（`SyncCollectionDiffPlanner`）
//       : upload = **对端缺 → 推**（`SyncLibraryPushController`），不拉
//       : download = **本端缺 → 拉**（`SyncLibraryPullController`，**以对端清单为准**），不推
//    ③.5 方向收尾时：R3b 携带该方向**成功传输**的歌的播放数据（跟歌走）
//    ④ 汇总账目（`SyncCollectionSyncReport`，含 `direction`）交调用方（UI 只消费）
//
//  为什么不再先推后拉（T7 修正）：
//  - 旧语义「一次开始 → 双向补齐」的对账基准恒为本端展开结果 → **对端独有的歌
//    永远拉不回来**（期望集合里根本没它们）；且 `.all` 展开为空 → 差集恒空 → 空转。
//  - 「上传 / 下载」是用户显式选择的两个**独立操作**，不该混跑。
//
//  本类**不重写传输层**：全部文件字节走既有 `SyncFileSender` / `SyncFileReceiver` /
//  `SyncLibraryFetchResponder`，本类只做「选哪些、先后、记账」。
//
//  ⚠️ T7 后：一次编排只创建一个控制器（upload 只推 / download 只拉），所以「两个控制器
//  的 manifest 钩子互相干扰」的旧问题不再出现（不再有跨方向重排）；账目仍按「最终值」
//  取（收尾时现读控制器 summary，见 `report` 文档），因为控制器的落盘/入库账目可能
//  晚于其 `.done` 回调。
//
//  线程：会话线程同步驱动（内存回环下 `start()` 会在本调用内跑到终态）；
//  状态/账目用锁保护，回调一律锁外触发。
//

import Foundation

// MARK: - 编排器

/// Mac 侧「选中集合的一套补齐编排」：一次计划 + 推送 + 拉取，产出账目。
/// 一个会话一个实例（M6 由 UI 持有并展示状态；本类不含 UI）。
final class SyncCollectionSyncCoordinator: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// 会话未 ready（未配对/已关闭）
        case sessionNotReady
        /// 已有编排在进行中（S4：重入保护；上一轮未收尾时不允许开新一轮）
        case alreadyRunning
    }

    enum Stage {
        case idle
        case planning
        /// 对端清单已到（已在同一临界区内从 `.planning` 迁出）。
        /// S2（2026-09-12 审计）：存在的唯一理由 = 让「清单已到」对到点检查可见，
        /// 从而「正在开始传输」与「计划态超时失败」互斥。
        case planned
        case pushing
        case pulling
        case finished
    }

    let session: SyncPeerSession
    let descriptor: SyncLocalLibraryDescriptor
    let selection: SyncCollectionSelection
    private let facts: SyncCollectionFactsProviding
    let members: SyncCollectionMembers
    let configuration: SyncCollectionSyncConfiguration
    let sink: SyncLibrarySyncSink
    let lyricsStore: AlignedLyricsStore
    let lyricsMapping: SyncLyricsContentMapping
    /// R3b：播放数据「跟歌走」驱动（nil = 不携带；R3a 行为零变化）。
    let playbackCarry: (any SyncPlaybackCarryDriving)?
    let fileManager: FileManager

    /// 等对端清单的超时定时（专用串行队列，与 `SyncPeerLibraryClient.timeoutQueue` 同款）。
    private let manifestTimeoutQueue = DispatchQueue(
        label: "qqplayer.sync.collection.manifest-timeout",
        qos: .utility
    )

    let lock = NSLock()
    var stateValue: SyncCollectionSyncState = .idle
    var stage: Stage = .idle
    /// T7：本次编排的传输方向（`start(direction:)` 写入；计划/执行阶段据此收窄）。
    var directionValue: SyncTransferDirection = .upload
    var reportValue = SyncCollectionSyncReport()
    var expansionValue = SyncCollectionExpansion()
    /// 计划阶段取回的对端 manifest 条目（R3b 携带时算「对端持有」的身份集合）。
    var peerManifestEntriesValue: [ManifestEntry] = []
    /// R3b：各方向**已确认传输**的相对路径（完成回调收集，传输序；去重）。
    /// 为什么不用控制器 summary：拉取侧的 `summary.completed` 会晚于 `.done` 回调
    /// （见 `report` 文档），阶段收尾时现读会拿到空集合 → 携带永远不触发。
    var pushTransferredValue: [String] = []
    var pullTransferredValue: [String] = []

    var manifestPeer: SyncManifestPeer?
    /// 计划态到点检查的待触发闭包（S4：可取消，不留待触发的 20s 闭包）。
    private var manifestTimeoutItem: DispatchWorkItem?
    var pushController: SyncLibraryPushController?
    var pullController: SyncLibraryPullController?

    /// 每态回调（锁外触发；会话线程）。
    var onStateChange: (@Sendable (SyncCollectionSyncState) -> Void)?
    /// 一个文件完成传输（推送送达 / 拉取落盘；锁外触发；进度用）。
    var onFileTransferred: (@Sendable (String) -> Void)?
    /// 收到对端 manifest 时回调（锁外；诊断/进度用）。
    var onPeerManifestReceived: (@Sendable (SyncManifestResponse) -> Void)?

    init(
        session: SyncPeerSession,
        descriptor: SyncLocalLibraryDescriptor,
        selection: SyncCollectionSelection,
        facts: SyncCollectionFactsProviding,
        members: SyncCollectionMembers = SyncCollectionMembers(),
        configuration: SyncCollectionSyncConfiguration = SyncCollectionSyncConfiguration(),
        sink: SyncLibrarySyncSink = LibraryIndexerSyncSink(),
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping,
        playbackCarry: (any SyncPlaybackCarryDriving)? = nil,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.descriptor = descriptor
        self.selection = selection
        self.facts = facts
        self.members = members
        self.configuration = configuration
        self.sink = sink
        self.lyricsStore = lyricsStore
        self.lyricsMapping = lyricsMapping
        self.playbackCarry = playbackCarry
        self.fileManager = fileManager
    }

    // MARK: 生命周期

    /// 开始一次**单向**编排（会话必须已 ready）：
    /// 展开选择集 → 请求对端 manifest（集合按方向取）→ 算单向差集 → upload 只推 / download 只拉。
    ///
    /// ⚠️ `direction` 有默认值 `.upload` **仅为兼容冻结的调用点**（`QQPlayer/Mac/`
    /// 属 T8 UI 批次，本批禁改）；生产调用点应显式传方向（UI 让用户选）。
    /// ⚠️ 上一轮未收尾（进行中）时**拒绝重入**：`StartError.alreadyRunning`（S4）。
    func start(direction: SyncTransferDirection = .upload) throws {
        guard session.isReady else { throw StartError.sessionNotReady }
        // S4（2026-09-12 审计）：重入保护——只有 idle / finished 能开新一轮。进行中
        // （planning / planned / pushing / pulling）再进来会把 stage、控制器、账目
        // 全部覆盖，且上一轮的收尾回调会被当成新一轮的终态上报（两轮编排串成一条
        // 状态流，账目互相污染）。
        lock.lock()
        guard stage == .idle || stage == .finished else {
            lock.unlock()
            throw StartError.alreadyRunning
        }
        lock.unlock()

        let expansion = SyncCollectionExpander.expand(selection: selection, facts: facts)
        lock.lock()
        directionValue = direction
        expansionValue = expansion
        reportValue.direction = direction
        reportValue.unresolvedCount = expansion.unresolvedCount
        reportValue.unknownPlaylistIDs = expansion.unknownPlaylistIDs
        reportValue.isEmptySelection = expansion.isEmptySelection
        reportValue.isLibraryWide = expansion.isLibraryWide
        lock.unlock()

        // 空选择集 = **不推不拉**（决策 9；与 `.all` 语义相反）
        guard !expansion.isEmptySelection else {
            finishStage()
            return
        }

        lock.lock()
        stage = .planning
        reportValue.didRequestPeerManifest = true
        lock.unlock()
        // M6 修复（2026-09-12）：计划态必须**上报**（不只是置内部 stage）。
        // 等对端 manifest 的这段时间若不上报，UI 侧 `state` 仍是 `.idle`：
        // `SyncUIStartGate.isRunning`（= 非终态）看的是上报状态 → 面板渲染开始键却
        // 按「正在运行」禁用 = 灰键 + 零解释 + 无法取消（用户实测现象）。
        // 锁外调用，与既有 `.pushing` / `.pulling` 写法一致（回调绝不持锁触发）。
        emit(state: .planning)

        let peer = SyncManifestPeer(session: session)
        peer.onManifestReceived = { [weak self] response in
            self?.handlePeerManifest(response)
        }
        peer.onDecodeFailure = { [weak self] error in
            self?.failPlanning("manifest 载荷非法：\(error)")
        }
        lock.lock()
        manifestPeer = peer
        lock.unlock()

        // S2（2026-09-12 审计修复）：到点检查必须在**发请求之前**就位——否则「发送」这段
        // 本身不受超时约束，且响应同步到达时（内存回环 / 局域网极快）到点检查永远晚于
        // 计划阶段 → 窗口无法复现也守不住。取消/收尾会取消该 item（见 cancel）。
        schedulePeerManifestTimeout()
        do {
            // 方向敏感：upload 恒 `.all`（本端展开选择）；download 让对端先按集合收口
            try peer.requestManifest(collection: selection.remoteRequestCollection(for: direction))
        } catch {
            failPlanning("请求 manifest 失败：\(error)")
            throw error
        }
    }

    /// 计划阶段「等对端清单」的超时兜底（`configuration.peerManifestTimeout` `<= 0` = 不启用）。
    ///
    /// 幂等与竞态：判定与置终态**必须一次持锁完成**（`failPlanningWhileWaitingForManifest`）——
    /// 先解锁再置终态的话，对端 manifest 可能恰好在这两步之间抢进
    /// （`handlePeerManifest` → `beginPush` → `stage = .pushing`），随后本次到点检查仍会把
    /// 一个**已经在推**的编排置成 `.finished` + `emit(.failed(超时))`：面板报「超时失败」
    /// 而文件其实还在传，且收尾被 `stage != .finished` 挡掉、永远不会报 `.done`。
    private func schedulePeerManifestTimeout() {
        let seconds = configuration.peerManifestTimeout
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.failPlanningWhileWaitingForManifest("等待设备清单超时（请确认 iPhone 上的 QQPlayer 在前台并已连接）")
        }
        lock.lock()
        manifestTimeoutItem = item
        lock.unlock()
        manifestTimeoutQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// 取消**尚未触发**的到点检查（S4：每次编排后不再留一个最多 `peerManifestTimeout`
    /// （默认 20s）的待触发闭包）。幂等；锁外调用。
    func cancelPeerManifestTimeout() {
        lock.lock()
        let item = manifestTimeoutItem
        manifestTimeoutItem = nil
        lock.unlock()
        item?.cancel()
    }

    /// 仅当**仍在等对端清单**时落失败：判定（`stage == .planning`）与置终态在**同一次持锁内**
    /// 完成，保证与 `handlePeerManifest` / `beginPush` / `beginPull` 的 `stage` 迁移互斥、不打架。
    ///
    /// 与 `failPlanning` 的区别：后者只看「本轮未收尾」（迟到响应后的解码失败等场景仍需它），
    /// 本方法额外要求「仍处计划态」——已应答（进入推送/拉取）、已收尾、已取消的编排，
    /// 到点检查一律不得动手。回调仍锁外触发（与既有写法一致）。
    private func failPlanningWhileWaitingForManifest(_ reason: String) {
        lock.lock()
        // S2：`stage == .planning` 是唯一的「仍在等清单」判据；`handlePeerManifest`
        // 在**同一临界区**内就把 stage 迁到 `.planned`（不再停在 `.planning`），
        // 因此「清单已到并开始传输」与本次到点失败互斥：清单一到，本方法必被守挡住。
        guard stage == .planning else {
            lock.unlock()
            return
        }
        stage = .finished
        let peer = manifestPeer
        manifestPeer = nil
        let item = manifestTimeoutItem
        manifestTimeoutItem = nil
        lock.unlock()
        peer?.onManifestReceived = nil
        peer?.onDecodeFailure = nil
        item?.cancel()
        emit(state: .failed(reason))
    }

    /// 中止（会话关闭 / 用户取消）：停发/停收，落 failed。
    func cancel() {
        // S4（2026-09-12 审计）：收尾彻底——取消未触发的到点检查，并清掉 manifest
        // 请求的钩子与引用（否则每次编排后都留一个待触发闭包，已取消的编排仍握着 peer）。
        cancelPeerManifestTimeout()
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        let push = pushController
        let pull = pullController
        let peer = manifestPeer
        manifestPeer = nil
        lock.unlock()
        peer?.onManifestReceived = nil
        peer?.onDecodeFailure = nil
        push?.cancel()
        pull?.cancel()
        emit(state: .failed("cancelled"))
    }

    // MARK: 收尾

    /// 收尾：落终态（账目由 `report` 实时合并两个控制器的 summary，见其文档）。
    func finishStage() {
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        lock.unlock()
        cancelPeerManifestTimeout() // S4：收尾不留待触发的到点检查

        let finalReport = report
        if let abort = finalReport.pushAbortReason, finalReport.pullAbortReason == nil {
            emit(state: .failed(abort))
        } else if let abort = finalReport.pullAbortReason {
            emit(state: .failed(abort))
        } else if finalReport.pushFailed.isEmpty, finalReport.pullFailed.isEmpty {
            emit(state: .done)
        } else {
            emit(state: .failed(failureSummary(finalReport)))
        }
    }

    private func failPlanning(_ reason: String) {
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        let peer = manifestPeer
        manifestPeer = nil
        let item = manifestTimeoutItem
        manifestTimeoutItem = nil
        lock.unlock()
        peer?.onManifestReceived = nil
        peer?.onDecodeFailure = nil
        item?.cancel()
        emit(state: .failed(reason))
    }

    private func failureSummary(_ report: SyncCollectionSyncReport) -> String {
        if !report.pushFailed.isEmpty, !report.pullFailed.isEmpty {
            return "推送失败 \(report.pushFailed.count) 项 / 拉取失败 \(report.pullFailed.count) 项"
        }
        if !report.pushFailed.isEmpty {
            return "推送失败 \(report.pushFailed.count) 项"
        }
        return "拉取失败 \(report.pullFailed.count) 项"
    }

    func emit(state: SyncCollectionSyncState) {
        lock.lock()
        stateValue = state
        lock.unlock()
        onStateChange?(state)
    }
}
