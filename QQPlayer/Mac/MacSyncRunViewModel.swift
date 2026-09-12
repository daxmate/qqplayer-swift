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
    private let makeCoordinator: (SyncPeerSession, SyncCollectionSelection) -> SyncCollectionSyncCoordinator

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

    // MARK: 内部状态

    private var coordinator: SyncCollectionSyncCoordinator?
    private var transferredCount = 0
    private var currentPath: String?
    private var cancellables = Set<AnyCancellable>()
    private var tickTask: Task<Void, Never>?
    private var reportRefreshTask: Task<Void, Never>?

    init(
        hostCenter: SyncHostCenter? = nil,
        content: MacSyncContentModel,
        deviceStore: DeviceStore = DeviceStore(),
        makeCoordinator: @escaping (SyncPeerSession, SyncCollectionSelection) -> SyncCollectionSyncCoordinator = {
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
        // objectWillChange 是**变更前**通知 → 用 Task 排到主线程队列尾，读到的就是新值。
        center.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.hostDidChange() }
            }
            .store(in: &cancellables)
        // 内容变化（选方向 / 勾选 / 换内容源）→ 刷新按钮可用性。
        content.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshAvailability() }
            }
            .store(in: &cancellables)
    }

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

    /// 页面消失：停掉计时与延迟任务（协调器不取消——同步应在后台继续跑）。
    func onDisappear() {
        stopTicking()
    }

    /// 弹一次错误。
    func clearError() { errorMessage = nil }

    // MARK: - 方向（面板第一屏）

    /// 选定同步方向：内容源整体切换（内容侧负责清空/重建选择集），并刷新可用性。
    func selectDirection(_ direction: SyncTransferDirection) {
        self.direction = direction
        content.switchDirection(to: direction)
        refreshAvailability()
    }

    // MARK: - 同步执行

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
        didDisconnectWhileRunning = false
        transferredCount = 0
        currentPath = nil
        reportSummary = nil
        errorMessage = nil

        let coordinator = makeCoordinator(session, content.selection)
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
        currentPath = nil
        refreshProgress(for: source)
    }

    /// 监听中心状态变化（连接 / 断开 / 开关）。
    private func hostDidChange() {
        if isConnected {
            startTicking()
        } else {
            stopTicking()
            if let coordinator, !SyncCollectionSyncState.isTerminal(coordinator.state) {
                didDisconnectWhileRunning = true
                coordinator.cancel()
            }
        }
        refreshAvailability()
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
            isEmptySelection: content.selection.isEmptySelection
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
        }
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
