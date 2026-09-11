//
//  SyncCollectionSyncCoordinator.swift
//  QQPlayer
//
//  R3a（2026-09-11）同步方向改造 · **选中集合的一套补齐编排**（Mac 发起，双向补齐）。
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
//  一次编排 = 计划 + 两个方向（顺序执行）：
//    ① 展开选择集（`SyncCollectionExpander`，注入取曲库事实）
//    ② 取本端（Mac）manifest；请求对端（设备）manifest（帧 10/11）
//    ③ 两侧按选中集合收口 → 算差集：**对端缺 → 推**（`SyncLibraryPushController`）、
//       **本端缺 → 拉**（`SyncLibraryPullController`）
//    ③.5 每个方向收尾时：R3b 携带该方向**成功传输**的歌的播放数据（跟歌走）
//    ④ 汇总账目（`SyncCollectionSyncReport`）交调用方（M6 UI 只消费，不在此实现）
//
//  为什么顺序执行而不是并行：两个方向共用**一个会话**（帧 4-14 的停等传输、
//  manifest 钩子链），并行会互相穿插；串行唯一确定。推送先行：决策 9 的主场景是
//  「设备端缺歌补齐」，先把设备补上，再补本端缺的（两个方向互不依赖）。
//
//  本类**不重写传输层**：全部文件字节走既有 `SyncFileSender` / `SyncFileReceiver` /
//  `SyncLibraryFetchResponder`，本类只做「选哪些、先后、记账」。
//
//  ⚠️ 已知限制（记账已兜、行为无害）：
//  两个控制器**各自**在会话上挂 manifest 钩子（链式转发，都看得到 manifest_response）。
//  推送阶段结束后，其钩子仍在链上：若推送有失败项，本端拉取阶段的对端 manifest
//  响应会让推送控制器**重排一次计划**（失败项重试）。传输层面两个方向互不干扰
//  （推 = Mac→设备，拉 = 设备→Mac，各自停等且接收端 SHA-256 校验），因此无害；
//  但账目必须按「最终值」取（本类在收尾时重新读取两个控制器的 summary），
//  否则重试完成的文件会漏记。彻底消除需给两个控制器的 manifest 钩子加终态守卫
//  （改 R1b-2 既有文件，非本包范围，留给 maintainer 决策）。
//
//  线程：会话线程同步驱动（内存回环下 `start()` 会在本调用内跑到终态）；
//  状态/账目用锁保护，回调一律锁外触发。
//

import Foundation

// MARK: - 差集（纯逻辑，可单测）

/// 选中集合下的一次双向差集（对账键 = relativePath，身份键 = content_hash）。
struct SyncCollectionDiff: Equatable, Sendable {
    /// 对端缺 / 内容不同 → 推送（升序）
    var toPush: [String] = []
    /// 本端缺 → 拉取（升序）
    var toPull: [String] = []
    /// 两侧都有且内容一致 → 零传输（升序）
    var unchanged: [String] = []
    /// 期望里有、但**两侧都没有实体**的路径（什么都不做；诊断用）
    var missingBoth: [String] = []
    /// 对端多出来的条目（不在选中集合内）→ **什么都不做**（决策 7；仅记账）
    var remoteOnlyIgnored: [String] = []

    /// 本次要动的路径总数（诊断/UI）。
    var transferCount: Int { toPush.count + toPull.count }
}

enum SyncCollectionDiffPlanner {
    /// 双向差集（纯函数）：`expected` = 选中集合展开出的期望路径，
    /// `local` / `remote` = **全量** manifest（本端 / 对端）。
    ///
    /// 判定（与既有两个 planner 逐字一致的内容判据：双侧 contentHash 非空且相等 = 一致）：
    /// - 两侧都有：一致 → `unchanged`；不同 → `toPush`（**发起方权威**，不做「拉回来
    ///   再覆盖」——否则同一路径会来回互相覆盖，永不稳定）
    /// - 只有本端有 → `toPush`（对端缺 → 补齐）
    /// - 只有对端有 → `toPull`（本端缺 → 补齐）
    /// - 两侧都没有 → `missingBoth`（不伪造、不动手）
    /// - 对端多出的条目 → `remoteOnlyIgnored`（**不传播删除**）
    static func plan(
        expected: [String],
        local: [ManifestEntry],
        remote: [ManifestEntry]
    ) -> SyncCollectionDiff {
        var localByPath: [String: ManifestEntry] = [:]
        for entry in local { localByPath[entry.relativePath] = entry } // later wins（最终快照）
        var remoteByPath: [String: ManifestEntry] = [:]
        for entry in remote { remoteByPath[entry.relativePath] = entry }

        var diff = SyncCollectionDiff()
        let wanted = Set(expected)
        for path in wanted.sorted() {
            switch (localByPath[path], remoteByPath[path]) {
            case let (localEntry?, remoteEntry?):
                if SyncManifestReconciler.contentMatches(local: localEntry, remote: remoteEntry) {
                    diff.unchanged.append(path)
                } else {
                    diff.toPush.append(path)
                }
            case (_?, nil):
                diff.toPush.append(path)
            case (nil, _?):
                diff.toPull.append(path)
            case (nil, nil):
                diff.missingBoth.append(path)
            }
        }
        diff.remoteOnlyIgnored = Set(remote.map(\.relativePath))
            .filter { !wanted.contains($0) }
            .sorted()
        return diff
    }
}

// MARK: - 配置 / 状态 / 账目

/// 编排配置（选择集之外的参数）。
struct SyncCollectionSyncConfiguration: Equatable, Sendable {
    /// 请求对端 manifest 用的集合（v1 恒 `.all`：选择在**本端**执行，见决策 10）
    var remoteCollection: SyncCollection = .all
    /// 落地目录名（曲库根内隐藏目录；透传拉取控制器）
    var incomingDirectoryName: String = ".sync-incoming"
}

/// 一次编排的进度状态。
enum SyncCollectionSyncState: Equatable, Sendable {
    case idle
    /// 已请求对端 manifest，等应答（并算差集）
    case planning
    /// 正在推送（对端缺的歌）
    case pushing
    /// 正在拉取（本端缺的歌）
    case pulling
    /// 收尾完成（账目见 report）
    case done
    /// 失败（计划阶段致命错误 / 用户取消）
    case failed(String)

    static func isTerminal(_ state: SyncCollectionSyncState) -> Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// 编排设置集后的账目（M6 UI 直接消费；本类不做 UI）。
struct SyncCollectionSyncReport: Equatable, Sendable {
    /// 计划推送的相对路径（升序）
    var plannedPush: [String] = []
    /// 计划拉取的相对路径（升序）
    var plannedPull: [String] = []
    /// 两侧一致、零传输（升序）
    var skipped: [String] = []
    /// 期望里两侧都没有实体的路径（升序；什么都不做）
    var missingBoth: [String] = []
    /// 对端多出的条目（升序；**不传播删除**，仅记账）
    var remoteOnlyIgnored: [String] = []
    /// 展开时未解析的曲目数（未指纹 / 未入库）
    var unresolvedCount: Int = 0
    /// 展开时忽略的未知/非法歌单标识（升序）
    var unknownPlaylistIDs: [String] = []
    /// 选择集是否为空（空 = 不推不拉，连 manifest 都不请求）
    var isEmptySelection: Bool = false
    /// 选择集是否库级（`.all`）
    var isLibraryWide: Bool = false
    /// 已确认送达对端的相对路径（推送序）
    var pushed: [String] = []
    /// 推送失败（本地不可读 / 传输失败 / 声明被丢弃）
    var pushFailed: [SyncPushFailure] = []
    /// 推送方向被跳过的相对路径（对端已一致）
    var pushSkipped: [String] = []
    /// 推送阶段中止原因（nil = 未中止）
    var pushAbortReason: String?
    /// 已落盘并入库的相对路径（接收序，含歌词 wire 路径）
    var pulled: [String] = []
    /// 拉取失败（对端报告）
    var pullFailed: [SyncFileFetchFailure] = []
    /// 拉取方向被跳过的相对路径（本端已一致）
    var pullSkipped: [String] = []
    /// 拉取阶段中止原因（nil = 未中止）
    var pullAbortReason: String?
    /// 对端回报送达的相对路径（`sync_fetch_result.completed`；升序；诊断/携带定范围用）
    var reportedPulled: [String] = []
    /// 是否请求过对端 manifest（空选择集 = false）
    var didRequestPeerManifest: Bool = false
    /// R3b：播放数据「跟歌走」——推送方向已带走的歌曲相对路径（升序）
    var playbackCarriedPush: [String] = []
    /// R3b：播放数据「跟歌走」——拉取方向请求带回的歌曲相对路径（升序）
    var playbackCarriedPull: [String] = []
    /// R3b：播放数据携带失败原因（nil = 未失败 / 未接线）
    var playbackCarryError: String?

    /// 本次实际传输的文件数（诊断/UI）。
    var transferCount: Int { pushed.count + pulled.count }
    /// 推送方向是否全部送达。
    var isPushComplete: Bool { pushAbortReason == nil && pushFailed.isEmpty }
    /// 拉取方向是否全部落地。
    var isPullComplete: Bool { pullAbortReason == nil && pullFailed.isEmpty }
    /// 本次编排是否完全成功（无中止、无失败项）。
    var isComplete: Bool { isPushComplete && isPullComplete }
}

// MARK: - 编排器

/// Mac 侧「选中集合的一套补齐编排」：一次计划 + 推送 + 拉取，产出账目。
/// 一个会话一个实例（M6 由 UI 持有并展示状态；本类不含 UI）。
final class SyncCollectionSyncCoordinator: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// 会话未 ready（未配对/已关闭）
        case sessionNotReady
    }

    private enum Stage {
        case idle
        case planning
        case pushing
        case pulling
        case finished
    }

    private let session: SyncPeerSession
    private let descriptor: SyncLocalLibraryDescriptor
    private let selection: SyncCollectionSelection
    private let facts: SyncCollectionFactsProviding
    private let members: SyncCollectionMembers
    private let configuration: SyncCollectionSyncConfiguration
    private let sink: SyncLibrarySyncSink
    private let lyricsStore: AlignedLyricsStore
    private let lyricsMapping: SyncLyricsContentMapping
    /// R3b：播放数据「跟歌走」驱动（nil = 不携带；R3a 行为零变化）。
    private let playbackCarry: (any SyncPlaybackCarryDriving)?
    private let fileManager: FileManager

    private let lock = NSLock()
    private var stateValue: SyncCollectionSyncState = .idle
    private var stage: Stage = .idle
    private var reportValue = SyncCollectionSyncReport()
    private var expansionValue = SyncCollectionExpansion()
    /// 计划阶段取回的对端 manifest 条目（R3b 携带时算「对端持有」的身份集合）。
    private var peerManifestEntriesValue: [ManifestEntry] = []
    /// R3b：各方向**已确认传输**的相对路径（完成回调收集，传输序；去重）。
    /// 为什么不用控制器 summary：拉取侧的 `summary.completed` 会晚于 `.done` 回调
    /// （见 `report` 文档），阶段收尾时现读会拿到空集合 → 携带永远不触发。
    private var pushTransferredValue: [String] = []
    private var pullTransferredValue: [String] = []

    private var manifestPeer: SyncManifestPeer?
    private var pushController: SyncLibraryPushController?
    private var pullController: SyncLibraryPullController?

    /// 每态回调（锁外触发；会话线程）。
    var onStateChange: ((SyncCollectionSyncState) -> Void)?
    /// 一个文件完成传输（推送送达 / 拉取落盘；锁外触发；进度用）。
    var onFileTransferred: ((String) -> Void)?
    /// 收到对端 manifest 时回调（锁外；诊断/进度用）。
    var onPeerManifestReceived: ((SyncManifestResponse) -> Void)?

    init(
        session: SyncPeerSession,
        descriptor: SyncLocalLibraryDescriptor,
        selection: SyncCollectionSelection,
        facts: SyncCollectionFactsProviding,
        members: SyncCollectionMembers = SyncCollectionMembers(),
        configuration: SyncCollectionSyncConfiguration = SyncCollectionSyncConfiguration(),
        sink: SyncLibrarySyncSink = LibraryIndexerSyncSink(),
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping? = nil,
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
        self.lyricsMapping = lyricsMapping ?? .unresolved
        self.playbackCarry = playbackCarry
        self.fileManager = fileManager
    }

    // MARK: 对外状态

    var state: SyncCollectionSyncState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    /// 账目**实时值**：意图（planned/skipped/未解析）来自计划阶段，结果（pushed /
    /// pulled / 失败）一律从两个控制器的**当前** summary 现读。
    ///
    /// 为什么必须现读而不是快照：控制器的落盘/入库账目可能晚于其 `.done` 回调
    /// （harness 实测：拉取控制器的 `summary.completed` 在结果帧回调之后才补齐），
    /// 快照会把刚补齐的文件漏记（账目与事实不符）。
    var report: SyncCollectionSyncReport {
        lock.lock()
        var snapshot = reportValue
        let push = pushController
        let pull = pullController
        lock.unlock()
        if let summary = push?.summary {
            snapshot.pushed = summary.completed
            snapshot.pushFailed = summary.failed
            snapshot.pushSkipped = summary.skipped
        }
        if let summary = pull?.summary {
            snapshot.pulled = summary.completed
            snapshot.pullFailed = summary.failed
            snapshot.pullSkipped = summary.unchanged
            snapshot.reportedPulled = summary.reportedCompleted.sorted()
        }
        return snapshot
    }

    /// 选择集展开结果（诊断/UI：未解析明细等）。
    var expansion: SyncCollectionExpansion {
        lock.lock()
        defer { lock.unlock() }
        return expansionValue
    }

    // MARK: 生命周期

    /// 开始一次编排（会话必须已 ready）：展开选择集 → 请求对端 manifest → 推 → 拉。
    func start() throws {
        guard session.isReady else { throw StartError.sessionNotReady }

        let expansion = SyncCollectionExpander.expand(selection: selection, facts: facts)
        lock.lock()
        expansionValue = expansion
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

        do {
            try peer.requestManifest(collection: configuration.remoteCollection)
        } catch {
            failPlanning("请求 manifest 失败：\(error)")
            throw error
        }
    }

    /// 中止（会话关闭 / 用户取消）：停发/停收，落 failed。
    func cancel() {
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        let push = pushController
        let pull = pullController
        lock.unlock()
        push?.cancel()
        pull?.cancel()
        emit(state: .failed("cancelled"))
    }

    // MARK: 计划

    /// 本端（Mac）全量清单（曲库 + aligned 歌词）。
    private func localManifest() -> [ManifestEntry] {
        SyncManifestGenerator.generate(files: descriptor.sourceFiles()) + descriptor.lyricsEntries()
    }

    private func handlePeerManifest(_ response: SyncManifestResponse) {
        lock.lock()
        let isPlanning = stage == .planning
        let expansion = expansionValue
        lock.unlock()
        guard isPlanning else { return } // 幂等：只认计划阶段的第一次响应

        onPeerManifestReceived?(response)

        let diff = SyncCollectionDiffPlanner.plan(
            expected: expansion.relativePaths,
            local: localManifest(),
            remote: response.entries
        )

        lock.lock()
        reportValue.plannedPush = diff.toPush
        reportValue.plannedPull = diff.toPull
        reportValue.skipped = diff.unchanged
        reportValue.missingBoth = diff.missingBoth
        reportValue.remoteOnlyIgnored = diff.remoteOnlyIgnored
        peerManifestEntriesValue = response.entries
        // 后续（控制器自己的）manifest 响应不再触发本类计划
        let peer = manifestPeer
        manifestPeer = nil
        lock.unlock()
        peer?.onManifestReceived = nil
        peer?.onDecodeFailure = nil

        beginPush()
    }

    private func beginPush() {
        lock.lock()
        guard stage == .planning else {
            lock.unlock()
            return
        }
        let planned = reportValue.plannedPush
        guard !planned.isEmpty else {
            lock.unlock()
            beginPull()
            return
        }
        stage = .pushing
        lock.unlock()
        emit(state: .pushing)

        let controller = SyncLibraryPushController(
            session: session,
            descriptor: descriptor,
            selection: .relativePaths(planned),
            members: members,
            fileManager: fileManager
        )
        controller.onStateChange = { [weak self] state in self?.handlePushState(state) }
        controller.onFilePushed = { [weak self] path in
            self?.onFileTransferred?(path)
            self?.recordTransferred(path, direction: .push)
        }
        lock.lock()
        pushController = controller
        lock.unlock()

        do {
            try controller.start()
        } catch {
            lock.lock()
            if reportValue.pushAbortReason == nil {
                reportValue.pushAbortReason = "启动推送失败：\(error)"
            }
            lock.unlock()
            beginPull()
            return
        }
        // 内存回环：start() 内可能已跑完终态 → 补一次（handlePushState 幂等）
        handlePushState(controller.state)
    }

    private func handlePushState(_ state: SyncLibraryPushState) {
        lock.lock()
        guard stage == .pushing else {
            lock.unlock()
            return
        }
        switch state {
        case .done:
            break // 结果账目由 `report` 实时合并控制器 summary
        case let .failed(reason):
            // 推送中止不阻断拉取（方向独立）
            if reportValue.pushAbortReason == nil {
                reportValue.pushAbortReason = reason
            }
        default:
            lock.unlock()
            return
        }
        lock.unlock()
        carryPlaybackData(direction: .push)
        beginPull()
    }

    private func beginPull() {
        lock.lock()
        guard stage == .planning || stage == .pushing else {
            lock.unlock()
            return
        }
        let planned = reportValue.plannedPull
        guard !planned.isEmpty else {
            lock.unlock()
            finishStage()
            return
        }
        stage = .pulling
        lock.unlock()
        emit(state: .pulling)

        var pullConfiguration = SyncLibraryPullConfiguration()
        pullConfiguration.collection = configuration.remoteCollection
        pullConfiguration.selection = .relativePaths(planned)
        pullConfiguration.incomingDirectoryName = configuration.incomingDirectoryName

        let controller = SyncLibraryPullController(
            session: session,
            descriptor: descriptor,
            sink: sink,
            configuration: pullConfiguration,
            lyricsStore: lyricsStore,
            lyricsMapping: lyricsMapping,
            fileManager: fileManager
        )
        controller.onStateChange = { [weak self] state in self?.handlePullState(state) }
        controller.onFileApplied = { [weak self] path in
            self?.onFileTransferred?(path)
            self?.recordTransferred(path, direction: .pull)
        }
        lock.lock()
        pullController = controller
        lock.unlock()

        do {
            try controller.start()
        } catch {
            lock.lock()
            if reportValue.pullAbortReason == nil {
                reportValue.pullAbortReason = "启动拉取失败：\(error)"
            }
            lock.unlock()
            finishStage()
            return
        }
        handlePullState(controller.state)
    }

    private func handlePullState(_ state: SyncLibraryPullState) {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
        switch state {
        case .done:
            break // 结果账目由 `report` 实时合并控制器 summary
        case let .failed(reason):
            if reportValue.pullAbortReason == nil {
                reportValue.pullAbortReason = reason
            }
        default:
            lock.unlock()
            return
        }
        lock.unlock()
        carryPlaybackData(direction: .pull)
        finishStage()
    }

    // MARK: R3b 播放数据「跟歌走」

    /// 一个方向收尾后：把该方向**成功传输**的歌的播放数据带过去（决策 8）。
    /// 未注入驱动 / 无成功传输 = 直接返回（行为与 R3a 一致）；失败只记账，不影响编排终态。
    private func carryPlaybackData(direction: SyncPlaybackCarryDirection) {
        guard let driver = playbackCarry else { return }
        let pulled = report.reportedPulled
        lock.lock()
        let transferred = direction == .push
            ? pushTransferredValue
            // 拉取方向：以对端回报的送达集为准（阶段收尾时已可用）；本端落位回调会晚于
            // 结果帧，两边取并集兜底（任一先到时都能得到完整集合）。
            : Array(Set(pullTransferredValue).union(pulled)).sorted()
        let peerEntries = peerManifestEntriesValue
        lock.unlock()
        guard !transferred.isEmpty else { return }
        do {
            let plan = try direction == .push
                ? driver.carryPush(transferredPaths: transferred, peerEntries: peerEntries)
                : driver.carryPull(transferredPaths: transferred, peerEntries: peerEntries)
            lock.lock()
            if direction == .push {
                reportValue.playbackCarriedPush = plan.carriedPaths
            } else {
                reportValue.playbackCarriedPull = plan.carriedPaths
            }
            lock.unlock()
        } catch {
            lock.lock()
            if reportValue.playbackCarryError == nil {
                reportValue.playbackCarryError = "\(error)"
            }
            lock.unlock()
        }
    }

    /// 记一条已确认传输的相对路径（完成回调；去重保持传输序）。
    private func recordTransferred(_ relativePath: String, direction: SyncPlaybackCarryDirection) {
        lock.lock()
        defer { lock.unlock() }
        switch direction {
        case .push:
            guard !pushTransferredValue.contains(relativePath) else { return }
            pushTransferredValue.append(relativePath)
        case .pull:
            guard !pullTransferredValue.contains(relativePath) else { return }
            pullTransferredValue.append(relativePath)
        }
    }

    // MARK: 收尾

    /// 收尾：落终态（账目由 `report` 实时合并两个控制器的 summary，见其文档）。
    private func finishStage() {
        lock.lock()
        guard stage != .finished else {
            lock.unlock()
            return
        }
        stage = .finished
        lock.unlock()

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
        manifestPeer = nil
        lock.unlock()
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

    private func emit(state: SyncCollectionSyncState) {
        lock.lock()
        stateValue = state
        lock.unlock()
        onStateChange?(state)
    }
}
