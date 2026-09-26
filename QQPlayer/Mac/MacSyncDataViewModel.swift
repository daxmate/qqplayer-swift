//
//  MacSyncDataViewModel.swift
//  QQPlayer
//
//  S2-T12（2026-09-13）macOS 同步页**数据同步区**视图模型（QQPlayerMac target only）。
//
//  职责：把一个 ready 会话驱动成一次「同步数据」（收藏 / 播放历史 / 歌单结构的
//  changeLog 增量），并把阶段 + 账目发布给 UI。
//  - 编排：`SyncDataSyncCoordinator`（共享 Core）——一次 = 推本端增量 + 拉对端增量，
//    与文件传输**完全解耦**（不碰 file_* / manifest / 选择集，两端都能独立发起）
//  - 判定：本文件只做 IO 与线程搬运，**不新造状态机**（阶段 / 账目一律来自协调器）
//
//  与 `MacSyncRunViewModel` 的分工：那个类型跑**文件**同步（方向 / 选择集 / 传输进度），
//  本类型跑**播放数据**同步（无方向、无选择集、无文件进度）。两者各自持有自己的
//  协调器实例、互不影响（帧 8/9 与 file_* 是不同帧），可同时跑。
//
//  线程（硬要求）：协调器回调在**会话线程**触发（阶段 emit / 超时队列 / 迟到帧回填）
//  → 一律 `Task { @MainActor in }` 回到主线程再改 `@Published`（同 `MacSyncRunViewModel`）。
//
//  账目实时读 + 终态兜底重读：`coordinator.report` 是**实时值**，收尾后仍可能被
//  迟到帧回填（见 `SyncDataSyncCoordinator` 文件头）→ 终态时先立刻读一次，
//  再延迟读一次覆盖（只在本视图模型仍持有该协调器、且它仍在终态时生效）。
//
//  「重新对账」（2026-09-14 身份缺口包）：把与该对端的推/拉游标清零 → 下次「同步
//  数据」重新全量对齐。游标一旦越过某行就永不回头，所以身份键修复后必须能把位置
//  退回去，否则那些行永远不再同步（参见 `SyncChangeLogStore.resetCursors`）。
//  本类只做 IO + 二次确认后的调用，按钮/弹框在 `MacSyncView`。
//
//  为什么不做单测：本文件属 `QQPlayer/Mac/`（iOS 单测 target 看不到它，仓库也没有
//  macOS 单测 target）→ 靠编译 + 代码审查覆盖；其中可测的判定全在共享 Core
//  （`SyncDataSyncCoordinator` / `SyncChangeLogStore` 等，`QQPlayerTests` 真跑）。
//

import Combine
import Foundation

@MainActor
final class MacSyncDataViewModel: ObservableObject {
    /// 协调器 `cancel()` 的固定失败串（`SyncDataSyncCoordinator.cancel`）。
    private static let cancelledReason = "cancelled"

    // MARK: 依赖

    private let hostCenter: SyncHostCenter
    private let makeCoordinator: (SyncPeerSession) -> SyncDataSyncCoordinator
    /// 「重新对账」的落点（默认 = 生产 store，走 `.shared`；测试/预览可注入）。
    private let resetCursors: (String) throws -> Void
    /// 出站悬空引用对账（T15b）：重置游标**之前**先跑一次（默认 = 生产 `SyncChangeLogDanglingRepair`；
    /// 测试/预览可注入）。
    private let repairDangling: () throws -> SyncChangeLogDanglingRepair.Report

    // MARK: 发布状态

    /// 当前阶段（idle / pushing / pulling / finished）。
    @Published private(set) var phase: SyncDataSyncPhase = .idle
    /// 最近一次「同步数据」的账目（实时值；没跑过 = 全 0）。
    @Published private(set) var report = SyncDataSyncReport()
    /// 面向 UI 的失败 / 中断文案（nil = 无失败）：`cancelled` 走本地化，
    /// 其余协调器内部诊断文案原样展示（比 "unknown" 有信息量，同 `MacSyncRunViewModel`）。
    @Published private(set) var errorMessage: String?
    /// 运行中会话断开（文案优先于 `cancelled`）。
    @Published private(set) var didDisconnectWhileRunning = false
    /// 「重新对账」结果提示（nil = 本次没有可说的；成功 / 失败 / 未连接）。
    @Published private(set) var resetResultMessage: String?

    // MARK: 内部状态

    private var coordinator: SyncDataSyncCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var reportRefreshTask: Task<Void, Never>?

    init(
        hostCenter: SyncHostCenter? = nil,
        makeCoordinator: @escaping (SyncPeerSession) -> SyncDataSyncCoordinator = {
            SyncDataSyncCoordinator(session: $0, libraryRoot: MusicFolderResolver.syncLibraryRoot)
        },
        resetCursors: ((String) throws -> Void)? = nil,
        repairDangling: (() throws -> SyncChangeLogDanglingRepair.Report)? = nil
    ) {
        // 默认值是 `nil` 而不是 `.shared`：默认实参在**非隔离**上下文求值，
        // 直接写 `= .shared` 会报「main actor-isolated property 跨隔离引用」
        // （Swift 6 语言模式下是错误）→ 在 init 体内（MainActor）解析。
        let center = hostCenter ?? .shared
        self.hostCenter = center
        self.makeCoordinator = makeCoordinator
        self.resetCursors = resetCursors ?? { peerID in
            try SyncChangeLogStore().resetCursors(forPeer: peerID)
        }
        self.repairDangling = repairDangling ?? {
            try SyncChangeLogDanglingRepair().run()
        }
        // 监听中心变化（连接 / 断开）→ 主线程刷新可用性与运行态。
        // 2026-09-20 批 6-8：中心迁 `@Observable` 后 `objectWillChange` 编译期消失 ⇒ 走 façade
        // `hostStatePublisher`（批 6-3 形状，不新增第二套订阅）。
        center.hostStatePublisher
            .sink { [weak self] _ in
                Task { @MainActor in self?.hostDidChange() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 派生（View 只读）

    /// 是否已连接。
    var isConnected: Bool { hostCenter.connectedPeer != nil }

    /// 是否正在跑（按钮切「取消」）。
    var isRunning: Bool {
        switch phase {
        case .pushing, .pulling: return true
        case .idle, .finished: return false
        }
    }

    /// 是否存在可用会话（曲库根就绪 = 接线完成）。
    var hasActiveSession: Bool { hostCenter.activeSession != nil }

    /// 可用性（批 B2，唯一实现 = 目标状态上的 `dataSyncAvailability`）：
    /// 连接 / 会话 / 未在跑 / **目标在线** 四件事的合成判定；本视图模型不自算。
    /// ⚠️ 目标状态由调用方（视图层唯一真值 `SyncDevicePane.syncTargetStatus`）**显式传入**：
    /// 本类型不存镜像、也不发布它（棘轮要求本文件计数 ≤ 基线，见
    /// `ObservationMigrationContractTests`）；判定仍全在 `SyncDeviceTargetStatus` 纯逻辑里。
    func dataAvailability(for targetStatus: SyncDeviceTargetStatus) -> SyncUIStartAvailability {
        targetStatus.dataSyncAvailability(
            isConnected: isConnected,
            hasSession: hasActiveSession,
            isRunning: isRunning
        )
    }

    /// 「同步数据」可用性（目标状态由调用方传入，见上）。
    func canStart(for targetStatus: SyncDeviceTargetStatus) -> Bool {
        dataAvailability(for: targetStatus).canStart
    }

    /// 不能开始的原因（可开始 / 运行中 = nil）。目标离线时返回 nil —— 「等待 <名字> 上线」
    /// 需要设备名，由视图层的目标状态行（唯一渲染）给出，不在这里拼字符串。
    func unavailableReason(for targetStatus: SyncDeviceTargetStatus) -> String? {
        switch dataAvailability(for: targetStatus) {
        case .ready, .targetOffline: return nil
        case .alreadyRunning: return "sync_run_data_reason_already_running".localized
        default: return "sync_run_data_reason_not_connected".localized
        }
    }

    /// 只是用户取消 / 掉线中断（UI 用次要色，不当错误红字）。
    var isInterrupted: Bool {
        didDisconnectWhileRunning || report.failureMessage == Self.cancelledReason
    }

    // MARK: - 生命周期

    /// 页面消失：停掉延迟任务（协调器**不**取消——同步应在后台继续跑完）。
    func onDisappear() {
        stopReportRefresh()
    }
    // MARK: - 同步执行

    /// 跑一次「同步数据」（未连接 / 已在跑 / 目标不可同步 = no-op）。
    /// ⚠️ 目标状态在**动作点**显式传入（第二道闸门，防「View 没拦」）：与按钮 `disabled`
    /// 用的是同一个 `canStart(for:)` 判定，闸门没有挪进 View。
    func start(for targetStatus: SyncDeviceTargetStatus) {
        guard canStart(for: targetStatus), let session = hostCenter.activeSession else { return }
        // 与「连接后自动」共用同一个在飞门：同一会话只允许一轮（手动 / 自动互斥），
        // 取不到门 = 直接放弃本轮（不排队）。
        guard SyncDataRunGate.shared.acquire() else {
            AppLog.info(.ui, "ℹ️ MacSyncDataViewModel: 已有一轮同步数据在跑（自动或手动），本轮跳过")
            return
        }
        stopReportRefresh()
        didDisconnectWhileRunning = false
        report = SyncDataSyncReport()
        errorMessage = nil

        // T15b-2（2026-09-14）：发送前先把「本地真值」对账进 outbox（业务表有、outbox
        // 没有 upsert 的收藏 / 歌单成员 / 播放历史）。收藏在补发通道之前是**只出不进**：
        // 引用失效的 outbox 行被清掉后业务行还在（用户看得见），同步层却永远看不到它
        // ⇒「收藏从来没同步过」且零报错。失败只打日志，**不阻断**本轮同步。
        do {
            let reconcile = try repairDangling()
            if reconcile.didChange {
                AppLog.info(.ui, "ℹ️ MacSyncDataViewModel: 同步前对账本地真值" + reconcile.logText)
            }
        } catch {
            AppLog.warn(.ui, "⚠️ MacSyncDataViewModel: 同步前对账失败 \(error)")
        }

        let coordinator = makeCoordinator(session)
        coordinator.onStateChange = { [weak self] _ in
            Task { @MainActor in self?.refreshFromCoordinator(coordinator) }
        }
        self.coordinator = coordinator
        coordinator.start()
        // 内存回环下 `start()` 可能已在本调用内跑到终态 → 补一次状态同步（幂等）。
        refreshFromCoordinator(coordinator)
    }

    /// 取消进行中的「同步数据」。
    func cancel() {
        guard let coordinator else { return }
        coordinator.cancel()
        refreshFromCoordinator(coordinator)
    }

    // MARK: - 重新对账（重置游标）

    /// 是否可用「重新对账」（批 B2：盯**所选设备**，不再看「谁连上了」——
    /// 游标是本端记录，选中了哪台就重置哪台；没选设备时无可重置。
    func canResetCursors(for targetStatus: SyncDeviceTargetStatus) -> Bool {
        targetStatus.target != nil
    }

    /// 把与**指定对端**的推/拉游标清零（UI 二次确认后调用）：身份修复后必须能重拉，
    /// 否则已被游标越过的行永不重来。同步进行中也可以重置（下一轮生效）。
    /// ⚠️ 批 B2：目标由调用方**显式传入**（= 所选设备的 Device ID）——
    /// 本类型不再读 `hostCenter.connectedPeer`（连上的可以不是所选的那台）。
    func resetCursorsForPeer(_ peerID: String) {
        guard !peerID.isEmpty else {
            // 复用「未连接」既有 key（不造重复 key）
            resetResultMessage = "sync_run_data_reason_not_connected".localized
            return
        }
        do {
            // T15b（2026-09-14）：先对账 outbox 的出站悬空引用（引用 stableId 在 track 表查无行）。
            // 不先修的话「重新对账」只是把同一批废行再推一遍——那些行永远拿不到指纹，
            // 对端仍全部「未定位」。修复失败只打日志，**不阻断**游标重置（两件事互不依赖）。
            do {
                let repair = try repairDangling()
                if repair.didChange {
                    AppLog.info(.ui, "ℹ️ MacSyncDataViewModel: 重置前对账出站悬空引用与本地真值" + repair.logText)
                }
            } catch {
                AppLog.warn(.ui, "⚠️ MacSyncDataViewModel: 出站悬空引用对账失败 \(error)")
            }
            try resetCursors(peerID)
            resetResultMessage = "sync_run_data_reset_done".localized
            AppLog.info(.ui, "ℹ️ MacSyncDataViewModel: 已重置与对端的同步游标（peerID 已脱敏）")
        } catch {
            AppLog.error(.ui, "❌ MacSyncDataViewModel: 重置同步游标失败 \(error)")
            resetResultMessage = "sync_run_data_reset_failed".localized
        }
    }

    // MARK: - 内部

    /// 协调器状态 / 账目 → 发布值。
    private func refreshFromCoordinator(_ source: SyncDataSyncCoordinator) {
        guard coordinator === source else { return }
        report = source.report
        phase = source.phase
        errorMessage = failureText(for: source.report)
        if source.phase == .finished {
            // 收尾 → 释放在飞门（自动轮与手动轮共用；重复释放是幂等的）。
            SyncDataRunGate.shared.release()
            scheduleReportRefresh(for: source)
        }
    }

    private func failureText(for report: SyncDataSyncReport) -> String? {
        guard let message = report.failureMessage else { return nil }
        if didDisconnectWhileRunning { return "sync_run_data_disconnected".localized }
        if message == Self.cancelledReason { return "sync_run_data_cancelled".localized }
        return message
    }

    /// 终态后再延迟读一次账目：迟到帧可能晚于 `.finished` 回调（见文件头）。
    private func scheduleReportRefresh(for source: SyncDataSyncCoordinator) {
        stopReportRefresh()
        reportRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.coordinator === source, source.phase == .finished else { return }
            self.report = source.report
            self.errorMessage = self.failureText(for: source.report)
        }
    }

    private func stopReportRefresh() {
        reportRefreshTask?.cancel()
        reportRefreshTask = nil
    }

    /// 监听中心状态变化：断开时立刻中止进行中的一次——协调器本身要等 20s 超时
    /// 才会报「对端无应答」，对用户来说「设备已断开」更准确也更及时。
    private func hostDidChange() {
        guard !isConnected, let coordinator, !coordinator.report.isFinished else { return }
        didDisconnectWhileRunning = true
        coordinator.cancel()
        refreshFromCoordinator(coordinator)
    }
}
