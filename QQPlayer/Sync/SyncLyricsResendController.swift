//
//  SyncLyricsResendController.swift
//  QQPlayer
//
//  F2（2026-09-16）对齐歌词**补发通道**的一轮编排（`SyncLyricsResend.swift` 是它的纯逻辑）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  一轮做两件事（推送方向；方向决策见 `SyncLyricsResend.swift` 头注释）
//  ════════════════════════════════════════════════════════════════════════════
//    ① 发 `manifest_request`(10) → 收 `manifest_response`(11)（**全量集合**，
//       只在本地把两侧都收口到 `@lyrics/*`——线上不多一个字段、不多一种集合）
//    ② 按 `SyncLyricsResendPlanner` 算计划 → 需要推的走
//       `SyncLibraryPushController`（帧 14 + 4/5/6，**既有实现**）
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么不自己写推送
//  ════════════════════════════════════════════════════════════════════════════
//  推送的**传输机制**（认领表、停等传输、失败记账）已有唯一实现
//  （`SyncLibraryPushController`，含 2026-09-12 审计修过的 T1/T2 缺陷）。
//  本类只负责**预算计划 + 串起来 + 汇总**，不复制第二套传输：
//  子轮由**选择集**收口（`relativePaths(计划里的 wire 路径)`）——推送子轮因此只会碰
//  这些歌词（选择集在本端执行，对端只需回全量 manifest）。
//
//  ⚠️ 子轮之间必须**摘钩子**：本类的对账 peer 会挂在会话分发链上，不摘的话
//  「推送子轮的 manifest 应答」会被它对账 peer 也收到（重复规划）。
//  故对账完成即 `releasePlanningPeer()`、推送子轮终态即 `detachFrameHooks()`
//  （见 `SyncLibraryPushController.detachFrameHooks()`）。
//
//  线程：会话线程（NW 队列）同步驱动（与推送子轮同口径）；状态用锁保护，
//  回调一律锁外触发。
//

import Foundation

final class SyncLyricsResendController: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// 会话未 ready（未配对 / 已关闭）
        case sessionNotReady
    }

    private let session: SyncPeerSession
    private let descriptor: SyncLocalLibraryDescriptor
    private let fileManager: FileManager
    private let lock = NSLock()

    /// 对账用的 manifest peer（**只请求不应答**：应答是 MacSyncLibraryHost / 被动端的事）
    private var manifestPeer: SyncManifestPeer?
    private var pushController: SyncLibraryPushController?

    private var stateValue: SyncLyricsResendState = .idle
    private var summaryValue = SyncLyricsResendSummary()

    /// 每态回调（锁外触发；会话线程）。
    var onStateChange: ((SyncLyricsResendState) -> Void)?

    init(
        session: SyncPeerSession,
        descriptor: SyncLocalLibraryDescriptor,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.descriptor = descriptor
        self.fileManager = fileManager
    }

    // MARK: 对外状态

    var state: SyncLyricsResendState {
        lock.lock()
        defer { lock.unlock() }
        return effectiveStateLocked()
    }

    /// 终态（.done）的账目取**实时值**（与推送子轮同口径：子轮先回调、账目必须完整）。
    private func effectiveStateLocked() -> SyncLyricsResendState {
        if case .done = stateValue {
            return .done(summaryValue)
        }
        return stateValue
    }

    var summary: SyncLyricsResendSummary {
        lock.lock()
        defer { lock.unlock() }
        return summaryValue
    }

    // MARK: 生命周期

    /// 开始一轮补发（会话必须已 ready）：请求对端 manifest，随后由帧驱动。
    func start() throws {
        guard session.isReady else { throw StartError.sessionNotReady }

        let peer = SyncManifestPeer(session: session)
        peer.onManifestReceived = { [weak self] response in
            self?.handleManifest(response)
        }
        peer.onDecodeFailure = { [weak self] error in
            self?.transition(to: .failed("manifest 载荷非法：\(error)"))
        }
        manifestPeer = peer

        transition(to: .planning)
        do {
            try peer.requestManifest(collection: .all)
        } catch {
            transition(to: .failed("请求 manifest 失败：\(error)"))
            throw error
        }
    }

    /// 中止（会话关闭 / 用户取消）：停掉在飞子轮，状态落 failed。
    func cancel() {
        pushController?.cancel()
        releasePushController()
        releasePlanningPeer()
        transition(to: .failed("cancelled"))
    }

    // MARK: 对账 → 计划

    private func handleManifest(_ response: SyncManifestResponse) {
        lock.lock()
        let isPlanning: Bool = {
            if case .planning = stateValue { return true }
            return false
        }()
        lock.unlock()
        guard isPlanning else { return } // 幂等：只认计划阶段的第一次响应
        releasePlanningPeer()

        let plan = SyncLyricsResendPlanner.plan(
            localLyrics: descriptor.lyricsEntries(),
            remoteEntries: response.entries
        )

        lock.lock()
        summaryValue.plannedPush = plan.toPush.map(\.relativePath)
        summaryValue.presentCount = plan.present.count
        lock.unlock()

        guard !plan.isIdle else {
            finish()
            return
        }
        startPushRound(plan.toPush.map(\.relativePath))
    }

    // MARK: 推送子轮

    private func startPushRound(_ paths: [String]) {
        guard !paths.isEmpty else {
            finish()
            return
        }
        transition(to: .pushing)
        let controller = SyncLibraryPushController(
            session: session,
            descriptor: descriptor,
            selection: .relativePaths(paths),
            members: descriptor.members(),
            fileManager: fileManager
        )
        controller.onStateChange = { [weak self] state in
            self?.handlePushState(state)
        }
        pushController = controller
        do {
            try controller.start()
        } catch {
            appendPushFailure(detail: "推送子轮启动失败：\(error)")
            releasePushController()
            finish()
        }
    }

    private func handlePushState(_ state: SyncLibraryPushState) {
        switch state {
        case let .done(pushSummary):
            lock.lock()
            summaryValue.pushed = pushSummary.completed.sorted()
            summaryValue.failed.append(contentsOf: pushSummary.failed)
            lock.unlock()
            releasePushController()
            finish()
        case let .failed(reason):
            // 推送子轮中止（会话关闭 / 载荷非法）：如实记账
            appendPushFailure(detail: reason)
            releasePushController()
            finish()
        default:
            break
        }
    }

    // MARK: 收尾

    /// 收尾（幂等）：算「待补」= 计划里没确认送达的条目，落终态。
    /// 待补清单**必须上屏**（缺口 ②：未送达不许悄悄消失）。
    private func finish() {
        lock.lock()
        if case .done = stateValue {
            lock.unlock()
            return
        }
        let delivered = Set(summaryValue.pushed)
        summaryValue.pendingResend = summaryValue.plannedPush
            .filter { !delivered.contains($0) }
            .sorted()
        lock.unlock()
        transition(to: .done(summaryValue))
    }

    // MARK: 钩子释放

    /// 摘掉对账 peer（幂等）：对账完成后必须摘，否则它会响应对推送子轮的 manifest 应答。
    private func releasePlanningPeer() {
        lock.lock()
        let peer = manifestPeer
        manifestPeer = nil
        lock.unlock()
        peer?.onManifestReceived = nil
        peer?.onDecodeFailure = nil
        peer?.detach()
    }

    /// 摘掉推送子轮（幂等）：摘 manifest 钩子 → 让出分发链位。
    private func releasePushController() {
        lock.lock()
        let controller = pushController
        pushController = nil
        lock.unlock()
        controller?.onStateChange = nil
        controller?.detachFrameHooks()
    }

    // MARK: 记账

    private func appendPushFailure(detail: String) {
        lock.lock()
        summaryValue.failed.append(
            SyncPushFailure(relativePath: "", reason: SyncPushFailureReason.sendFailed, detail: detail)
        )
        lock.unlock()
    }

    private func transition(to newState: SyncLyricsResendState) {
        lock.lock()
        let current = stateValue
        guard SyncLyricsResendStateMachine.canTransition(from: current, to: newState) else {
            lock.unlock()
            return
        }
        stateValue = newState
        let effective = effectiveStateLocked()
        lock.unlock()
        onStateChange?(effective)
    }
}
