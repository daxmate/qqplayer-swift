//
//  MacSyncRunViewModel.swift
//  QQPlayer
//
//  M6（T3，2026-09-11；T10 2026-09-12 改造）Mac 同步页**执行侧视图模型**
//  （QQPlayerMac target only）。
//
//  职责（契约 C4）：把一个 ready 会话 + 用户选择集，驱动成一次可见的同步：
//  - 装配：`MacSyncCoordinatorFactory.make(session:selection:)`（**唯一装配入口**：
//    曲库根 / 描述符 / sink / 歌词映射一律走它，本文件不另建一套路径或 DB 口径）
//  - 订阅：`onStateChange` / `onFileTransferred` / `onPeerManifestReceived`
//  - 发布：阶段、进度、结果摘要（供执行区 / 结果区 UI 消费）
//  - 判定：全部委托 `SyncUIState`（纯逻辑，可单测）；本文件只做 IO 与线程搬运
//
//  ⚠️ T10 分工（与 `MacSyncContentModel` 的边界）：本类型只管**跑**一次同步；
//  「同步什么」（方向 / 内容源 / 选项 / 选择集）在 `MacSyncContentModel`。两者由
//  View 同时持有；内容侧的 `objectWillChange` 会驱动本类型刷新按钮可用性。
//  T10 新增：**方向是开始同步的前置**（`selectDirection` → 未选方向时按钮禁用）。
//
//  线程（硬要求）：协调器的回调在**会话线程**触发 → 一律 `Task { @MainActor in }`
//  回到主线程再改 `@Published`（本类是 `@MainActor`）。
//
//  会话断开：`SyncHostCenter.connectedPeer` 变 nil 时把进行中的同步 `cancel()` 并
//  标记 `didDisconnectWhileRunning`（UI 展示「设备已断开，同步已停止」而不是
//  干巴巴的 `cancelled`）。
//
//  账目实时读 + 终态兜底重读：`coordinator.report` 是实时值，但两个控制器的
//  落盘/入库账目可能**晚于** `.done` 回调（见 `SyncCollectionSyncCoordinator.report`
//  文档：拉取侧 `summary.completed` 晚于结果帧）→ 终态时先立刻读一次，再延迟读一次
//  覆盖（只在本协调器仍是当前、且仍在终态时生效）。
//
//  为什么不做单测：本文件属 `QQPlayer/Mac/`（iOS 单测 target 看不到它，仓库也没有
//  macOS 单测 target）→ 靠编译 + 代码审查覆盖；其中可测的判定全部在
//  `SyncUIState` / `SyncUIDirectionContent`（共享 Core，QQPlayerTests 真跑）。
//

import Combine
import Foundation

@MainActor
final class MacSyncRunViewModel: ObservableObject {
    // MARK: 依赖

    private let hostCenter: SyncHostCenter
    /// 内容侧（方向 / 内容源 / 选择集）。
    private let content: MacSyncContentModel
    private let deviceStore: DeviceStore
    private let makeCoordinator: (SyncPeerSession, SyncCollectionSelection) -> MacSyncCoordinatorAssembly

    // MARK: 发布状态

    /// 当前阶段。
    @Published private(set) var phase: SyncUIPhase = .disconnected
    /// 「开始同步」可用性。
    @Published private(set) var startAvailability: SyncUIStartAvailability = .notPaired
    /// 文件级进度。
    @Published private(set) var progress: SyncUIProgress = .idle
    /// 最近一次同步的结果摘要（nil = 还没跑过）。
    @Published private(set) var reportSummary: SyncUIReportSummary?
    /// 执行期错误（装配失败等；UI 弹一次）。
    @Published private(set) var errorMessage: String?
    /// 每秒更新（连接时长展示用）。
    @Published private(set) var now = Date()
    /// 同步进行中会话断开（UI 提示用）。
    @Published private(set) var didDisconnectWhileRunning = false
    /// 用户选定的同步方向（T10：面板第一屏；未选 = nil → 不能开始）。
    @Published private(set) var direction: SyncTransferDirection?
    /// 是否**真的**在等对端清单（`.planning` 持续超过 `manifestWaitHintDelay` 才为 true）。
    /// 清单 1s 内就回来时本属性始终 false ⇒ 面板一次都不出现「等待」文案。
    ///
    /// ⚠️ **非 `@Published`**：棘轮要求本文件 `@Published` 计数 ≤ 基线（见
    /// `ObservationMigrationContractTests`）。本属性只做纯派生，重绘由**既有** `now`
    /// 的每秒 tick 驱动（连接期间一直在跑，`.planning` 必然已连接）。
    var isWaitingForPeerManifest: Bool {
        guard phase == .planning, let startedAt = manifestWaitStartedAt else { return false }
        return Date().timeIntervalSince(startedAt) >= Self.manifestWaitHintDelay
    }

    // MARK: 同步目标（批 B2）

    /// 本次同步**目标**状态（期望目标 / 在线态 / 连上的与所选是否不符）。
    /// 决策全在 `SyncDeviceListModel`（纯逻辑）；本类只接收视图层推来的事实，
    /// 用于把闸门交给 `SyncUIStartGate`（同样是纯逻辑），不在这里另判。
    /// ⚠️ **非 `@Published`**（批 B2 收尾）：目标状态不进本类型的发布面 —— 棘轮要求本文件
    /// 计数 ≤ 基线（见 `ObservationMigrationContractTests`）。变化经唯一喂入口
    /// `updateSyncTarget(_:)` 落进本镜像并触发 `refreshAvailability()`；重绘由 `startAvailability`
    /// 的发布驱动（它在基线里，保持不变）。为什么不用「注入读视图层真值的 provider 闭包」：
    /// 那要在视图构造/出现时安装并捕获 `View`（值类型）副本，生命周期与新鲜度都要另管；
    /// 私有镜像 + 唯一喂入口是零新增所有权概念的等价形状。
    private var syncTargetStatus: SyncDeviceTargetStatus = .none

    // MARK: 内部状态

    private var coordinator: SyncCollectionSyncCoordinator?
    private var transferredCount = 0
    private var currentPath: String?
    private var cancellables = Set<AnyCancellable>()
    private var tickTask: Task<Void, Never>?
    private var reportRefreshTask: Task<Void, Never>?

    // MARK: 最近一次结果的持久化（2026-09-27 批 persist-last-sync-result）

    /// 上次运行的恢复事实（nil = 本次运行 / 尚无历史）。
    /// ⚠️ **非 `@Published`**（棘轮：本文件 `@Published` 基线 = 8，只减不增）—— 变化由
    /// `reportSummary` 的发布驱动重绘。
    private var restoredLastRun: SyncLastResultRestore.Resolved?
    /// 本次运行的落盘事实（peerID / 设备名 / 方向）：在 `start(direction:)` 快照，
    /// 因为落盘发生在终态后 800ms，彼时可能已断线拿不到分桶 key。
    private var runPeerID: String?
    private var runPeerName: String?
    /// 本次运行**绑定的会话身份**（启动时快照）。
    /// 对端重连会让 host 让位到新会话 —— 此时 `isConnected` 仍为 true（新会话已连上），
    /// 只有会话身份变了，所以「断开就取消」的分支看不见这件事（任务包 §3 D）。
    private var runSessionIdentity: ObjectIdentifier?
    private var runDirection: SyncTransferDirection?

    init(
        hostCenter: SyncHostCenter? = nil,
        content: MacSyncContentModel,
        deviceStore: DeviceStore = DeviceStore(),
        makeCoordinator: @escaping (SyncPeerSession, SyncCollectionSelection) -> MacSyncCoordinatorAssembly = {
            MacSyncCoordinatorFactory.make(session: $0, selection: $1)
        }
    ) {
        // 默认值是 `nil` 而不是 `.shared`：默认实参在**非隔离**上下文求值，
        // 直接写 `= .shared` 会报「main actor-isolated property 跨隔离引用」
        // （Swift 6 语言模式下是错误）→ 在 init 体内（MainActor）解析。
        let center = hostCenter ?? .shared
        self.hostCenter = center
        self.content = content
        self.deviceStore = deviceStore
        self.makeCoordinator = makeCoordinator
        // 监听中心变化（连接/断开/开关）→ 主线程刷新可用性与运行态。
        // 2026-09-20 批 6-8：中心迁 `@Observable` 后 `objectWillChange` **编译期消失** ⇒ 改走中心
        // 自己的 façade `hostStatePublisher`（批 6-3「非视图消费者的唯一观察入口」形状，
        // 不新增第二套订阅）。语义与迁移前一致：变更后发信号、不重放当前值。
        center.hostStatePublisher
            .sink { [weak self] _ in
                Task { @MainActor in self?.hostDidChange() }
            }
            .store(in: &cancellables)
        // 内容变化（选方向 / 勾选 / 换内容源）→ 刷新按钮可用性。
        // ⚠️ `MacSyncContentModel` 本批**未**迁 `@Observable`（仍 ObservableObject）→ 保持原样。
        content.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshAvailability() }
            }
            .store(in: &cancellables)
        restoreLastResult()
        restoreLastDirection()
    }

    /// 上次运行事实（nil = 本次运行 / 尚无历史）；View 传给
    /// `SyncEntityOutcomeDisclosure.fileConclusion(_:lyricsResend:lastRun:)`。
    var reportSummaryLastRun: SyncLastResultRestore.Resolved? { restoredLastRun }

    /// 上次运行的完成时刻（nil = 本次运行 / 尚无历史）。
    var reportSummaryRunAt: Date? { restoredLastRun?.snapshot.finishedAt }

    // MARK: - 派生（View 只读）

    /// 当前连接的对端（nil = 未连接）。
    var connectedPeer: SyncConnectedPeer? { hostCenter.connectedPeer }

    /// 是否已连接。
    var isConnected: Bool { hostCenter.connectedPeer != nil }

    /// 连接时长文案（"3:12"；未连接 = nil）。
    var connectionDurationText: String? {
        guard let peer = hostCenter.connectedPeer else { return nil }
        return SyncUIDurationText.short(seconds: now.timeIntervalSince(peer.connectedAt))
    }

    /// 监听是否在运行（开关关闭 / 启动失败 = false）。
    var isListening: Bool { hostCenter.isRunning }

    /// 允许局域网设备连接（绑定到 `SyncHostCenter`）。
    var allowsLANConnections: Bool {
        get { hostCenter.allowsLANConnections }
        set { hostCenter.allowsLANConnections = newValue }
    }

    /// 中断提示（掉线中止 / 用户取消 / 无）。
    var interruption: SyncUIInterruption {
        SyncUIInterruption.resolve(phase: phase, didDisconnectWhileRunning: didDisconnectWhileRunning)
    }

    /// 当前失败原因文本（非失败态 = nil）：已知码走本地化，未知码原样展示
    /// （协调器内部诊断文案，比 "unknown" 有信息量）。
    var failureText: String? {
        guard case let .failed(reason) = phase else { return nil }
        switch (interruption, reason) {
        case (.sessionClosed, _): return "sync_run_interrupted".localized
        case (.cancelled, _): return "sync_run_cancelled".localized
        default: return reason
        }
    }

    // MARK: - 生命周期

    /// 页面出现：刷新可用性 + 计时。内容（方向/清单）由内容侧自己管。
    func onAppear() {
        refreshAvailability()
        if isConnected { startTicking() } else { stopTicking() }
    }

    /// 页面消失：停掉计时并撤销等待提示（协调器不取消——同步应在后台继续跑）。
    func onDisappear() {
        stopTicking()
        clearManifestWaitHint()
    }

    /// 弹一次错误。
    func clearError() { errorMessage = nil }

    // MARK: - 方向（面板第一屏）

    /// 选定同步方向：内容源整体切换（内容侧负责清空/重建选择集），并刷新可用性。
    /// 选择即落盘（唯一入口 `SyncDirectionMemory`）：已连接 → 写该设备桶 + 「最近一次」；
    /// 未连接 → 只写「最近一次」（没有设备可归属）。
    func selectDirection(_ direction: SyncTransferDirection) {
        self.direction = direction
        SyncDirectionMemory.remember(direction, peerID: hostCenter.connectedPeer?.peerID)
        content.switchDirection(to: direction)
        refreshAvailability()
    }

    // MARK: - 同步执行

    /// 目标选择变化（视图层唯一喂入口；从 `SyncDeviceListModel` 拿到的结论原样传入）。
    /// 值未变不重复刷新（每次连接/列表变化都会调）。
    func updateSyncTarget(_ status: SyncDeviceTargetStatus) {
        guard status != syncTargetStatus else { return }
        syncTargetStatus = status
        refreshAvailability()
    }

    /// 按当前方向开始同步（View 的唯一入口；未选方向 = 什么都不做）。
    func startSync() {
        guard let direction else { return }
        switch direction {
        case .upload: startUpload()
        case .download: startDownload()
        }
    }

    /// 上传到移动端（Mac → iPhone；仅在 `startAvailability == .ready` 时有效）。
    func startUpload() { start(direction: .upload) }

    /// 从移动端下载（iPhone → Mac；仅在 `startAvailability == .ready` 时有效）。
    func startDownload() { start(direction: .download) }

    private func start(direction: SyncTransferDirection) {
        refreshAvailability()
        guard startAvailability == .ready else { return }
        guard let session = hostCenter.activeSession else {
            refreshAvailability()
            return
        }

        stopReportRefresh()
        didReceivePeerManifest = false
        clearManifestWaitHint()
        didDisconnectWhileRunning = false
        transferredCount = 0
        currentPath = nil
        reportSummary = nil
        // 本次运行开始 → 已有结果不再是「上次的」（前缀行随之消失）。
        restoredLastRun = nil
        // 快照落盘事实（此刻 session 活着，避免跑完才断线拿不到分桶 key）。
        runPeerID = hostCenter.connectedPeer?.peerID
        runPeerName = hostCenter.connectedPeer?.displayName
        runDirection = direction
        // 会话身份快照：host 让位（同设备重连）时据此立即取消，而不是对着死会话等清单 20s 超时。
        runSessionIdentity = ObjectIdentifier(session)
        errorMessage = nil

        let assembly = makeCoordinator(session, content.selection)
        let coordinator = assembly.coordinator
        // 观测：一次编排运行的量化记录（纯观测；不参与任何判定）。
        coordinator.diag = SyncDiagAttempt(
            kind: .run,
            role: "host",
            channel: .session,
            candidates: 0,
            peerDeviceID: hostCenter.connectedPeer?.peerID
        )
        // 装配事实 → 运行时自检（INV-16 后半句）：跟歌走携带没装上要看得见，不能只留在注释里。
        SyncWiringFactsStore.shared.record(.playbackCarry, attached: assembly.playbackCarryAttached)
        SyncWiringFactsStore.shared.record(.overwriteLedger, attached: assembly.overwriteLedgerAttached)
        coordinator.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleState(state, from: coordinator) }
        }
        coordinator.onFileTransferred = { [weak self] relativePath in
            Task { @MainActor in self?.handleFileTransferred(relativePath, from: coordinator) }
        }
        coordinator.onPeerManifestReceived = { [weak self] _ in
            Task { @MainActor in self?.handlePeerManifest(from: coordinator) }
        }
        self.coordinator = coordinator

        do {
            try coordinator.start(direction: direction)
        } catch {
            errorMessage = "\(error)"
        }
        // 内存回环下 `start()` 可能已在本调用内跑到终态 → 补一次状态同步（幂等）。
        handleState(coordinator.state, from: coordinator)
        refreshAvailability()
    }

    /// T2 测速：对着当前 ready 会话跑一次合成探针。
    ///
    /// - 不写任何 `@Published`（棘轮：本文件发布面只减不增）——结果由调用方（面板局部
    ///   `@State`）展示；探针总值同时写进 `SyncProbeStore`，供 `kind=frame` 诊断行落盘。
    /// - 探针失败/超时/对端不支持 → `completion(nil)`，**不影响**同步可用性。
    func runProbe(completion: @escaping (Double?) -> Void) {
        guard let session = hostCenter.activeSession, session.isReady else {
            completion(nil)
            return
        }
        // 经调度器单飞：已有自动/手动探针在跑 → 直接放弃本次（不并发两条探针）。
        let started = SyncProbeScheduler.shared.run(session: session) { value in
            Task { @MainActor in completion(value) }
        }
        if !started { completion(nil) }
    }

    /// 取消进行中的同步。
    func cancelSync() {
        guard let coordinator else { return }
        coordinator.cancel()
        handleState(coordinator.state, from: coordinator)
        refreshAvailability()
    }

    // MARK: - 回调处理（主线程）

    private func handleState(_ state: SyncCollectionSyncState, from source: SyncCollectionSyncCoordinator) {
        guard coordinator === source else { return }
        phase = SyncUIPhase.resolve(isConnected: isConnected, state: state)
        if phase == .planning {
            markManifestWaitStartedIfNeeded()
        } else {
            clearManifestWaitHint()
        }
        refreshProgress(for: source)
        guard phase.isTerminal else { return }
        refreshReportSummary(for: source)
        scheduleReportRefresh(for: source)
        refreshAvailability()
    }

    private func handleFileTransferred(_ relativePath: String, from source: SyncCollectionSyncCoordinator) {
        guard coordinator === source else { return }
        transferredCount += 1
        currentPath = relativePath
        refreshProgress(for: source)
    }

    private func handlePeerManifest(from source: SyncCollectionSyncCoordinator) {
        guard coordinator === source else { return }
        // 计划已到手：总数为 0 的阶段到此结束（进度条从不确定态切确定态）。
        didReceivePeerManifest = true
        clearManifestWaitHint()
        currentPath = nil
        refreshProgress(for: source)
    }

    /// 进入 `.planning` 的时刻（nil = 没在等）。**非发布面**：等待文案的重绘由 `now` 的
    /// 每秒 tick 驱动（见 `isWaitingForPeerManifest`）。
    private var manifestWaitStartedAt: Date?
    /// 本次运行是否已收到对端清单（收到 = 之后不再显示「正在获取设备清单」）。
    private var didReceivePeerManifest = false
    /// 「真的在等」的判定阈值（秒）：低于它视为瞬时对账，面板不出现等待文案。
    static let manifestWaitHintDelay: TimeInterval = 1

    /// 进入 `.planning` 时记下开始等待的时刻（已在等 / 已收到清单则不重复记）。
    private func markManifestWaitStartedIfNeeded() {
        guard !didReceivePeerManifest, manifestWaitStartedAt == nil else { return }
        manifestWaitStartedAt = Date()
    }

    /// 撤销等待提示（清单到手 / 离开计划态 / 页面消失 / 新一轮开始）。
    private func clearManifestWaitHint() {
        manifestWaitStartedAt = nil
    }

    /// 监听中心状态变化（连接 / 断开 / 开关）。
    private func hostDidChange() {
        if isConnected {
            startTicking()
            cancelIfRunSessionReplaced()
        } else {
            stopTicking()
            if let coordinator, !SyncCollectionSyncState.isTerminal(coordinator.state) {
                didDisconnectWhileRunning = true
                coordinator.cancel()
            }
        }
        refreshAvailability()
    }

    /// 运行中的会话被替换（对端重连 → host 让位到新会话）：**立即取消**进行中的同步。
    ///
    /// 为什么不能只靠「断开就取消」：让位后 `connectedPeer` 立刻是新会话（isConnected 仍 true），
    /// 而本次运行仍绑在旧会话上 → 会一直等清单直到 20s 超时（真机现象：面板报
    /// 「获取设备清单超时」，重试同样超时）。
    private func cancelIfRunSessionReplaced() {
        guard let coordinator, !SyncCollectionSyncState.isTerminal(coordinator.state),
              let runSessionIdentity, let activeSession = hostCenter.activeSession,
              ObjectIdentifier(activeSession) != runSessionIdentity
        else { return }
        // 复用既有「设备已断开，同步已停止」展示路径（不新增 UI 语义）。
        didDisconnectWhileRunning = true
        coordinator.cancel()
    }

    // MARK: - 内部

    private func refreshAvailability() {
        let running = coordinator.map { !SyncCollectionSyncState.isTerminal($0.state) } ?? false
        startAvailability = SyncUIStartGate.evaluate(
            hasPairedDevice: hasPairedDevice,
            isConnected: isConnected,
            hasSession: hostCenter.activeSession != nil,
            isRunning: running,
            hasDirection: direction != nil,
            isEmptySelection: content.selection.isEmptySelection,
            targetStatus: syncTargetStatus
        )
    }

    private var hasPairedDevice: Bool {
        ((try? deviceStore.all()) ?? []).isEmpty == false
    }

    private func refreshProgress(for source: SyncCollectionSyncCoordinator) {
        progress = SyncUIProgressAggregator.make(
            phase: phase,
            report: source.report,
            completed: transferredCount,
            currentPath: currentPath
        )
    }

    /// 账目快照（数据源 = `report` 实时值）。
    private func refreshReportSummary(for source: SyncCollectionSyncCoordinator) {
        reportSummary = SyncUIReportSummary.make(report: source.report)
    }

    /// 终态后再延迟读一次账目：控制器落盘/入库账目可能晚于终态回调（见文件头）。
    private func scheduleReportRefresh(for source: SyncCollectionSyncCoordinator) {
        stopReportRefresh()
        reportRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.coordinator === source, SyncCollectionSyncState.isTerminal(source.state) else { return }
            self.refreshReportSummary(for: source)
            // 唯一写入时机：账目已定稿（终态后 800ms）之后落盘一次。
            self.persistLastResultIfNeeded()
        }
    }

    /// 启动 / 重建时恢复「记住的最后同步方向」（口径实现 = `SyncDirectionMemory.resolve`：
    /// 该设备桶 → 「最近一次」回退值 → nil）。
    ///
    /// 只回填方向：**不**自动开始同步、**不**改按钮闸门（`SyncUIStartGate` 的判断一条不动）。
    /// 与 `selectDirection` 同一配对要求：设置 `direction` 的同时必须 `content.switchDirection(to:)`，
    /// 否则内容源与方向不匹配（内容区显示的会是另一端）。无记录 = 保持 nil（与今天行为一致）。
    private func restoreLastDirection() {
        guard let remembered = SyncDirectionMemory.resolve(
            connectedPeerID: hostCenter.connectedPeer?.peerID
        ) else { return }
        direction = remembered
        content.switchDirection(to: remembered)
    }

    /// 启动 / 重建时恢复「最近一次结果」（口径 1 的实现在 `SyncLastResultRestore`：
    /// 连上某设备只回显该设备分桶；未连接回显跨设备最近一次）。无历史 = 保持 nil。
    private func restoreLastResult() {
        let connected = hostCenter.connectedPeer
        guard let resolved = SyncLastResultRestore.resolve(
            connectedPeerID: connected?.peerID,
            connectedPeerName: connected?.displayName,
            buckets: SyncLastResultStore.buckets()
        ) else { return }
        reportSummary = SyncUIReportSummary.make(snapshot: resolved.snapshot)
        restoredLastRun = resolved
    }

    /// 落盘「最近一次结果」（口径 3 的实现在 `SyncLastResultPersistRule`）。
    private func persistLastResultIfNeeded() {
        guard let summary = reportSummary,
              let peerID = runPeerID,
              let direction = runDirection else { return }
        guard SyncLastResultPersistRule.shouldPersist(summary: summary, interruption: interruption) else { return }
        let snapshot = SyncLastResultSnapshot(
            summary: summary,
            finishedAt: Date(),
            peerID: peerID,
            peerDisplayName: runPeerName ?? "",
            direction: direction
        )
        SyncLastResultStore.save(snapshot)
    }

    private func stopReportRefresh() {
        reportRefreshTask?.cancel()
        reportRefreshTask = nil
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
