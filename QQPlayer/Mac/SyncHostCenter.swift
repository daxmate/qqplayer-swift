//
//  SyncHostCenter.swift
//  QQPlayer
//
//  M6（T1，2026-09-11）局域网同步（S2）macOS Host 侧**App 级常驻监听中心**
//  （QQPlayerMac target only）。
//
//  历史：逻辑原在 `MacSyncHostService`（页面级生命周期：`MacSyncSettingsView`
//  .onAppear 启动 / .onDisappear 停止）。问题是用户不可能开着设置页等同步
//  （docs/m6-sync-ui-plan.md §5.1 缺口 1）→ 本类把生命周期提升到 App 级：
//  App 启动即 `start()`，设置页只做控制面（状态展示 + 开关 + 批准卡）。
//
//  ⚠️ 行为零变化约束（M6 契约 C1 硬要求）：`SyncListener` 的 Bonjour 广播 /
//  nonce 注册 / 批准落库 / attach-detach / 越界拒读语义一律与旧实现逐字一致，
//  只搬生命周期。旧文件 `MacSyncHostService.swift` **保持原样不动**（守则 §6 红线）：
//  它已被本类取代、无任何引用，由 maintainer 在 merge 时请示用户后处理。
//
//  职责划分：
//  - 本类：会话接线（ready → 建 `MacSyncLibraryHost`）+ 待批准队列 + 控制面状态。
//  - `SyncHostGate`（共享 Core）：纯判定（能否启动 / 该不该停），本类调用它。
//  - `MacSyncCoordinatorFactory`：真正开始同步时的编排装配（T2）。
//
//  线程：`SyncListener` 回调在其内部串行队列触发 → 一律 hop 主线程；
//  本类是 `@MainActor`。
//

import Combine
import Foundation
import Network
import Observation

/// 当前已连接的对端（同步设置页「连接状态区」展示用）。
struct SyncConnectedPeer: Equatable, Sendable {
    /// 展示名（取已配对设备记录；查不到回落 Device ID 分组格式）
    var displayName: String
    /// 对端 Device ID（全量）
    var peerID: String
    /// 本会话进入 ready 的时刻（UI 显示连接时长）
    var connectedAt: Date
}

/// Mac Host 侧同步监听中心（App 级单例；被追踪状态恒在主线程）。
///
/// 2026-09-20 批 6-8：`ObservableObject` → `@Observable`（视图侧改组合根环境注入，
/// 按属性追踪刷新）；原先的 `@Published` 投影/`objectWillChange` 由下面的
/// `hostStatePublisher` façade 取代 —— 非视图消费者（三个同步面板 view model）
/// 只订阅它（批 6-3「非视图消费者的观察入口」形状）。
@MainActor
@Observable
final class SyncHostCenter {
    /// App 级单例（App 启动即 start；设置页只读它）。
    static let shared = SyncHostCenter()

    /// 主机状态变化信号 —— 非视图消费者的**唯一**观察入口。
    /// 五个状态属性各自的 `didSet` 喂它（状态与信号同源，不靠人记得）。
    private let stateChanges = PassthroughSubject<Void, Never>()

    /// 订阅即监听「连接 / 断开 / 开关 / 待批准 / 启动错误」任一变化（非视图消费者用）。
    /// 语义与迁移前的 `objectWillChange` 一致（不重放当前值）。
    var hostStatePublisher: AnyPublisher<Void, Never> { stateChanges.eraseToAnyPublisher() }

    /// 「允许局域网设备连接」开关的持久化键（缺省 true = 与旧行为一致：装上就监听）。
    static let allowsLANDefaultsKey = "sync.allowsLANConnections.v1"

    // MARK: 对外状态（契约 C1）

    /// 监听是否在运行。
    private(set) var isRunning = false { didSet { stateChanges.send() } }
    /// 当前已连接对端（nil = 无连接）。会话 ready 时置位，会话关闭 / stop 后清空。
    private(set) var connectedPeer: SyncConnectedPeer? { didSet { stateChanges.send() } }

    /// 允许局域网设备连接（UserDefaults 持久化，缺省 **true**）。
    /// 置 false → `stop()`；置 true → `start()`（走 `SyncHostGate` 判定，幂等）。
    var allowsLANConnections: Bool {
        didSet {
            // 信号先发且不看值是否变化：迁移前的 `@Published` 就是「每次赋值都发」。
            stateChanges.send()
            guard oldValue != allowsLANConnections else { return }
            defaults.set(allowsLANConnections, forKey: Self.allowsLANDefaultsKey)
            applyToggle()
        }
    }

    /// 待批准配对卡（nil = 无待批准）。批准 / 拒绝后清空。
    private(set) var pendingCard: SyncPairingApprovalCard? { didSet { stateChanges.send() } }
    /// 监听启动失败原因（设置页弹窗展示用）。
    private(set) var startError: String? { didSet { stateChanges.send() } }

    /// 已 attach 的 ready 会话（同步控制面读）。会话关闭 / stop 后为 nil。
    @ObservationIgnored private(set) var activeSession: SyncPeerSession?

    /// 设备列表已变化（批准落库后触发；设置页 reloadDevices()）。
    @ObservationIgnored var onDevicesChanged: (() -> Void)?
    /// 拉取结论（诊断/UI 用；M6 T3 接进度展示）。
    @ObservationIgnored var onFetchResult: ((SyncFetchResult) -> Void)?

    // MARK: 内部状态

    private let defaults: UserDefaults
    private let trustStore: DeviceStore
    @ObservationIgnored private var listener: SyncListener?
    @ObservationIgnored private var pendingSession: SyncPeerSession?
    /// 已连接会话（`connectedPeer` 的来源，见 `clearConnection(ifMatching:)`）。
    @ObservationIgnored private var connectedSession: SyncPeerSession?
    /// 已就绪会话的曲库接线（M3-3b：manifest 应答 + 按路径拉取推送）。
    /// 每个 ready 会话一份；会话关闭 / 服务停止时拆除。
    @ObservationIgnored private var libraryHost: MacSyncLibraryHost?

    /// 曲库根（注入便于测试/多根演进；默认 ~/Music/QQPlayer，与 macOS 扫描默认一致）。
    @ObservationIgnored var libraryRootProvider: () -> URL = {
        MusicFolderResolver.macDefaultFolderURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// 本机身份加载（Keychain；失败 → 记 startError 且不启动，绝不静默换 ID）。
    @ObservationIgnored var identityProvider: () throws -> SyncIdentity = {
        try SyncIdentityStore().loadOrCreateIdentity()
    }

    /// 本机展示名（Bonjour 友好名；与设置页 QR hostName 同源）。
    /// 默认取 `LocalDeviceNameStore`：用户命过名用用户的名，否则回落系统默认名
    /// （macOS = `Host.current().localizedName ?? 主机名`，与提升前逐字等价）。
    @ObservationIgnored var deviceNameProvider: () -> String = { LocalDeviceNameStore.shared.name }

    init(defaults: UserDefaults = .standard, trustStore: DeviceStore = DeviceStore()) {
        self.defaults = defaults
        self.trustStore = trustStore
        // 缺省 true：与提升为 App 级常驻前的行为一致（装上即监听，用户可关）。
        allowsLANConnections = defaults.object(forKey: Self.allowsLANDefaultsKey) as? Bool ?? true
    }

    /// 清空启动错误（弹窗关闭后）。
    func clearStartError() {
        startError = nil
    }

    // MARK: 生命周期（App 级）

    /// 开始监听（幂等：已运行再调 = no-op，**不重启监听**）。
    /// 开关关闭时（`SyncHostGate`）不启动；identity 加载失败 → 记 startError 不启动。
    func start() {
        guard SyncHostGate.shouldStart(allowsLAN: allowsLANConnections, isRunning: isRunning) else {
            return
        }
        let identity: SyncIdentity
        do {
            identity = try identityProvider()
        } catch {
            // 文案回归：`SyncIdentityError` 不是 `LocalizedError`，直接取
            // `localizedDescription` 会让用户看到
            // 「The operation couldn't be completed. (QQPlayer.SyncIdentityError error 0.)」
            // 这种技术文案 → 回到改造前页面用的本地化键（用户可读），
            // 原始 error 细节只进日志、不进 alert（与仓库既有 print 诊断惯例一致）。
            AppLog.error(.ui, "❌ SyncHostCenter identity load failed: \(error)")
            startError = "sync_identity_missing_error".localized
            return
        }
        // 清理可能残留的接线（listener 为 nil 时无副作用；identity 失败路径不走到这里）。
        stop()

        let listener = SyncListener(
            localIdentity: identity,
            trustStore: trustStore,
            deviceName: deviceNameProvider()
        )
        // host 侧握手 hello 也携带本机展示名（iPhone 侧据此展示/落库 Mac 的名字）
        listener.sessionConfig.clientDisplayName = LocalDeviceNameStore.shared.name
        // 待批准回调在 listener 串行队列触发 → 主线程上抛
        listener.pairApprovalHandler = { [weak self] session, pending in
            Task { @MainActor in
                self?.presentPending(pending, session: session)
            }
        }
        listener.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.listener !== nil || error != nil else { return }
                self.isRunning = false
                if let error {
                    self.startError = "\(error)"
                }
            }
        }
        // 会话进入 ready（配对完成）→ 接曲库；任何状态下线 → 拆除接线
        listener.onSessionStateChange = { [weak self] session, phase in
            Task { @MainActor in
                self?.handleSessionPhase(session, phase: phase)
            }
        }
        listener.onSessionClosed = { [weak self] session, _ in
            Task { @MainActor in
                guard let self else { return }
                self.clearConnection(ifMatching: session)
                guard let host = self.libraryHost else { return }
                host.detach()
                self.libraryHost = nil
            }
        }
        do {
            try listener.start(port: 0)
            self.listener = listener
            isRunning = true
            startError = nil
        } catch {
            startError = "\(error)"
        }
    }

    /// 停止监听并关闭全部活动会话（开关关闭 / App 退出）。
    func stop() {
        discardQRNonce()
        libraryHost?.detach()
        libraryHost = nil
        listener?.stop()
        listener = nil
        pendingSession = nil
        pendingCard = nil
        isRunning = false
        activeSession = nil
        connectedSession = nil
        connectedPeer = nil
    }

    // MARK: 会话 ↔ 曲库接线（M3-3b）

    /// 会话阶段变化：ready（已配对）→ 建接线；closed → 拆接线。
    private func handleSessionPhase(_ session: SyncPeerSession, phase: SyncSessionPhase) {
        switch phase {
        case .ready:
            guard libraryHost == nil else { return } // v1 单会话接线
            // 连接状态以**会话**为准（与是否接上曲库无关，UI 才说得清「连上了但库不可用」）。
            let peerID = session.peerHelloValue?.deviceID ?? ""
            connectedSession = session
            connectedPeer = SyncConnectedPeer(
                displayName: displayName(forPeerID: peerID),
                peerID: peerID,
                connectedAt: Date()
            )
            // 对端 hello 带新展示名 → 刷新信任表 + 当前展示名（改名后不必重配对）
            applyPeerHelloDisplayName(session.peerHelloValue?.name, peerID: peerID)
            let host = MacSyncLibraryHost(libraryRoot: libraryRootProvider())
            host.onFetchResult = { [weak self] result in
                Task { @MainActor in self?.onFetchResult?(result) }
            }
            // 曲库根不存在 → 不接线（宁可不服务，也不回空 manifest 害对端误删）
            guard host.attach(to: session) else { return }
            libraryHost = host
            activeSession = session
            // 连接就绪 → 后台自动跑一次「同步数据」（用户 2026-09-15 拍板：触发时机 = 连接后自动）。
            // 放在这里而不是面板 view model 里：面板没打开时也要跑（否则又变成“点过的才同步”）。
            MacDataSyncAutoRunner.shared.sessionDidBecomeReady(session, libraryRoot: libraryRootProvider())
            // F2 对齐歌词补发（2026-09-16）：连接就绪自动跑一轮 `@lyrics/*` 增量对账
            // （两个方向：对端缺的推过去、本端缺的拉回来）。与「同步数据」一样放在这里
            // 而不是面板 view model：面板没打开时也要跑，否则又变成「点过的才同步」。
            MacLyricsResendAutoRunner.shared.sessionDidBecomeReady(session, libraryRoot: libraryRootProvider())
        case .closed:
            clearConnection(ifMatching: session)
            libraryHost?.detach()
            libraryHost = nil
        default:
            break
        }
    }

    /// 会话下线时清理连接状态（只清**当前这个**会话，防旧会话回调误清新连接）。
    private func clearConnection(ifMatching session: SyncPeerSession) {
        guard connectedSession === session else { return }
        connectedSession = nil
        connectedPeer = nil
        activeSession = nil
        // 会话下线：让自动触发的「一次连接一次」标记归位（下次连上再自动跑一轮）。
        MacDataSyncAutoRunner.shared.sessionDidClose()
        MacLyricsResendAutoRunner.shared.sessionDidClose()
        // 装配自检事实同步归零（不是缺口——没有会话就谈不上装配）。
        SyncWiringFactsStore.shared.clear()
    }

    /// 对端 hello 携带展示名且与信任表现有 display_name 不同 → 刷新 display_name
    /// （只动这一列）→ 重取展示名刷新 `connectedPeer` → 通知设置页刷新设备列表。
    /// 纯展示字段：空白名 / 存储失败只记日志，绝不影响会话接线（连接状态以会话为准）。
    private func applyPeerHelloDisplayName(_ rawName: String?, peerID: String) {
        guard !peerID.isEmpty, let rawName else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let existing = (try? trustStore.byPeerID(peerID)) ?? nil,
              existing.displayName != name
        else { return }
        do {
            try trustStore.updateDisplayName(peerID: peerID, name: name)
        } catch {
            AppLog.error(.ui, "❌ SyncHostCenter updateDisplayName failed: \(error)")
            return
        }
        connectedPeer?.displayName = displayName(forPeerID: peerID)
        onDevicesChanged?()
    }

    /// 对端展示名：优先已配对设备记录，查不到回落 Device ID 分组格式。
    private func displayName(forPeerID peerID: String) -> String {
        guard !peerID.isEmpty else { return "" }
        if let device = (try? trustStore.byPeerID(peerID)) ?? nil {
            return SyncDeviceList.displayName(device)
        }
        return DeviceID.formatted(peerID)
    }

    /// 开关切换后的动作（`SyncHostGate` 判定 → start / stop / 无动作）。
    private func applyToggle() {
        switch SyncHostGate.toggleAction(allowsLAN: allowsLANConnections, isRunning: isRunning) {
        case .start:
            start()
        case .stop:
            stop()
        case .none:
            break
        }
    }

    // MARK: 配对

    /// 把当前展示 QR 的 sessionNonce（base64 → Data）注册进运行中 listener。
    /// 每次展示/刷新新码调用；未运行（开关关闭 / 启动失败）时静默忽略。
    ///
    /// ⚠️ 2026-09-13 恢复：**注册新码不得作废其它已展示的码**。同步中心有两个入口
    /// （设置→同步 / 工具栏面板），各自持一份 `@State` 二维码图；此前「注册即作废旧码」
    /// 会让另一个面板仍在展示、看着有效的二维码静默失效（扫码 → 验签无源 → 静默拒绝，
    /// 桌面不弹批准卡）。旧码在配对完成 / 停止监听时由 `discardQRNonce()` 统一清掉。
    func registerQRNonce(nonceBase64: String) {
        guard isRunning, let nonce = Data(base64Encoded: nonceBase64), !nonce.isEmpty else { return }
        listener?.pairingNonces.register(nonce)
    }

    /// 清空 nonce 池（配对完成 / 停止监听）。
    /// 之后拿旧 QR 回连 → 验签无源 → 会话按 `pairingRejected` 明确失败（不静默成功）。
    func discardQRNonce() {
        listener?.pairingNonces.removeAll()
    }

    /// 用户点「批准」：以 clientName 为展示名落库（空自动回退 ID 短格式，
    /// 语义见 SyncPeerSession.approvePairing）→ 会话进 ready → 刷新设备列表。
    func approvePending() {
        guard let card = pendingCard, let session = pendingSession else { return }
        // displayName 传 clientName 原文；approvePairing 内部 trim + 空回退，
        // 落库展示名与批准卡一致
        session.approvePairing(displayName: card.rawClientName)
        pendingCard = nil
        pendingSession = nil
        // 配对完成：展示码连同池里其它存货一并作废（下次配对需重新展示新码）
        discardQRNonce()
        onDevicesChanged?()
    }

    /// 用户点「拒绝」：回复拒绝并关闭会话。
    func rejectPending() {
        defer { discardQRNonce() }
        guard let session = pendingSession else {
            pendingCard = nil
            pendingSession = nil
            return
        }
        session.rejectPairing(reason: nil)
        pendingCard = nil
        pendingSession = nil
    }

    /// 待批准呈现（v1 单待批准：后到覆盖——若已有待批准会话，先拒绝旧的防悬挂）。
    private func presentPending(_ pending: PendingPairRequest, session: SyncPeerSession) {
        if let old = pendingSession, old !== session {
            old.rejectPairing(reason: "superseded-by-newer-request")
        }
        let isReplacement = ((try? trustStore.byPeerID(pending.request.clientDeviceID)) ?? nil) != nil
        pendingSession = session
        pendingCard = pending.makeApprovalCard(isReplacement: isReplacement)
    }
}

// MARK: - 连接后自动跑一轮「同步数据」（2026-09-15）

/// 连接就绪 → 后台自动跑一轮「同步数据」（用户 2026-09-15 拍板：触发时机 = 连接后自动）。
///
/// 为什么是 App 级而不是面板 view model：面板（`MacSyncView`）没打开时 view model 根本
/// 不存在，自动触发就会退化成“打开面板才同步”——正是矩阵三级空格
/// 「点过的设备同步了、没点的没有」。
///
/// 一轮 = ① 本地真值对账（补发，与手动路径同一入口）② 推本端增量 + 拉对端增量。
/// 与手动触发共用一个在飞门（`SyncDataRunGate`）：同一会话只允许一轮，取不到门就放弃本轮。
/// 一次连接只自动跑一次（会话下线时清标记，重连再跑）。
///
/// **前置门**（2026-09-16 补上，唯一判定 = `IndexingGate.isReadyForChangeLogSync`）：
/// 曲库索引未到终态时**不跑**——此刻 `track` 表正在重建，本端「这首歌在不在」的事实不稳定：
/// ① 本地真值对账会把「暂时查不到」当成**本地悬空** → 把 outbox 行清掉且不补发（真值静默
/// 从同步层消失）；② 出站行整批拿不到 `content_hash` / 相对路径 → 对端全判「未定位」。
/// iOS 侧一直有这道门（`IOSPassiveSyncCenter.attachDataSync`），Mac 侧此前**没接**
/// （真机取证与判定说明见 `IndexingGate` 文件头）；门关时订阅索引信号，终态一到补跑。
@MainActor
final class MacDataSyncAutoRunner {
    static let shared = MacDataSyncAutoRunner()
    private var coordinator: SyncDataSyncCoordinator?
    private var didAutoRunForCurrentConnection = false
    /// 本 runner 是否持有在飞门（释放只释放自己那份，不误伤手动轮）。
    private var holdsGate = false
    /// 待跑的会话（前置门未开时留着，等索引可跑再补跑）
    private var pendingSession: SyncPeerSession?
    private var pendingLibraryRoot: URL?
    private var indexingReadinessCancellable: AnyCancellable?

    private init() {}

    func sessionDidBecomeReady(_ session: SyncPeerSession, libraryRoot: URL) {
        pendingSession = session
        pendingLibraryRoot = libraryRoot
        startIfPossible()
    }

    /// 真跑一轮（幂等：已跑过 / 无待跑会话 / 会话不再 ready / 门被占 / 前置门未开 → 什么都不做）。
    private func startIfPossible() {
        guard let session = pendingSession,
              let libraryRoot = pendingLibraryRoot,
              session.isReady
        else { return }
        guard SyncDataAutoRunDecision.shouldStart(
            isConnected: true,
            hasActiveSession: true,
            isBusy: SyncDataRunGate.shared.isHeld,
            didAutoRunForCurrentConnection: didAutoRunForCurrentConnection
        ) else { return }
        guard IndexingGate.isReadyForChangeLogSync(LibraryIndexer.shared) else {
            AppLog.warn(.ui, "⏸️ MacDataSyncAutoRunner: 曲库索引未到终态，等终态后补跑自动同步")
            // 门控期不申报「装配缺口」（有意不跑 = 不适用，INV-26；与 iOS 侧同口径）。
            SyncWiringFactsStore.shared.record(.dataSyncEntry, attached: nil)
            observeIndexingReadiness()
            return
        }
        guard SyncDataRunGate.shared.acquire() else { return }
        holdsGate = true
        didAutoRunForCurrentConnection = true

        // 同手动路径：发送前先把「本地真值」对账进 outbox（补发）。失败只打日志、不阻断。
        do {
            let reconcile = try SyncChangeLogDanglingRepair().run()
            if reconcile.didChange {
                AppLog.info(.ui, "ℹ️ MacDataSyncAutoRunner: 连接后自动对账本地真值" + reconcile.logText)
            }
        } catch {
            AppLog.warn(.ui, "⚠️ MacDataSyncAutoRunner: 自动对账失败 \(error)")
        }

        // peerID 取对端 hello 的 Device ID（与手动路径同一口径）；空着就不跑，
        // 避免拿空串当游标键写脏数据。
        guard let peerID = session.peerHelloValue?.deviceID,
              !peerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.warn(.ui, "⚠️ MacDataSyncAutoRunner: 会话无对端 Device ID，跳过自动同步")
            // 装配自检事实：声明了「同步数据入口」却装配不了（会话没有可用游标键）→ 面板可见。
            SyncWiringFactsStore.shared.record(.dataSyncEntry, attached: false)
            finish()
            return
        }
        SyncWiringFactsStore.shared.record(.dataSyncEntry, attached: true)

        let coordinator = SyncDataSyncCoordinator(
            session: session,
            database: .shared,
            peerID: peerID,
            libraryRoot: libraryRoot
        )
        self.coordinator = coordinator
        coordinator.onStateChange = { [weak self] phase in
            Task { @MainActor in
                guard let self, phase == .finished else { return }
                let report = coordinator.report
                AppLog.info(.ui,
                            "ℹ️ MacDataSyncAutoRunner: 自动同步收尾"
                                + "（发送=\(report.pushedEntries) 应用=\(report.appliedEntries)"
                                + " 挂起=\(report.suspendedEntries) 未定位=\(report.unresolvedEntries)"
                                + " 未支持=\(report.unsupportedEntries) 忽略删除=\(report.ignoredDeletes)"
                                + " 失败=\(report.failureMessage ?? "无")）"
                )
                self.finish()
            }
        }
        AppLog.info(.ui, "ℹ️ MacDataSyncAutoRunner: 连接就绪 → 自动跑一轮同步数据")
        coordinator.start()
    }

    /// 订阅「索引可跑」信号：到达后重走**唯一判定入口**（`startIfPossible` 自己幂等）。
    ///
    /// 为什么要两条信号：`indexingTerminalStatePublisher` 只在**本次启动首次**主扫完成时
    /// 翻转（`$hasCompletedScanThisLaunch` 的 map），若连接就绪时正赶上**重扫**
    /// （`isIndexing == true`，但首次完成早已发生）它不会再发 → 补跑永远等不到；
    /// `isIndexingPublisher` 覆盖那种情况（每次扫描起止都会通知）。
    private func observeIndexingReadiness() {
        guard indexingReadinessCancellable == nil else { return }
        let indexer = LibraryIndexer.shared
        indexingReadinessCancellable = indexer.indexingTerminalStatePublisher
            .merge(with: indexer.isIndexingPublisher.map { _ in () })
            .sink { [weak self] in
                Task { @MainActor in self?.startIfPossible() }
            }
    }

    /// 会话下线：标记归位（下次连上再自动跑一轮）+ 取消未收尾的自动轮并释放门。
    func sessionDidClose() {
        didAutoRunForCurrentConnection = false
        pendingSession = nil
        pendingLibraryRoot = nil
        indexingReadinessCancellable = nil
        if let coordinator {
            coordinator.cancel()
            self.coordinator = nil
        }
        if holdsGate { finish() }
    }

    private func finish() {
        coordinator = nil
        if holdsGate {
            holdsGate = false
            SyncDataRunGate.shared.release()
        }
    }
}
