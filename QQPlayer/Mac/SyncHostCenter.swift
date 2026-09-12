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

import Foundation
import Network

/// 当前已连接的对端（同步设置页「连接状态区」展示用）。
struct SyncConnectedPeer: Equatable, Sendable {
    /// 展示名（取已配对设备记录；查不到回落 Device ID 分组格式）
    var displayName: String
    /// 对端 Device ID（全量）
    var peerID: String
    /// 本会话进入 ready 的时刻（UI 显示连接时长）
    var connectedAt: Date
}

/// Mac Host 侧同步监听中心（App 级单例；`@Published` 状态恒在主线程）。
@MainActor
final class SyncHostCenter: ObservableObject {
    /// App 级单例（App 启动即 start；设置页只读它）。
    static let shared = SyncHostCenter()

    /// 「允许局域网设备连接」开关的持久化键（缺省 true = 与旧行为一致：装上就监听）。
    static let allowsLANDefaultsKey = "sync.allowsLANConnections.v1"

    // MARK: 对外状态（契约 C1）

    /// 监听是否在运行。
    @Published private(set) var isRunning = false
    /// 当前已连接对端（nil = 无连接）。会话 ready 时置位，会话关闭 / stop 后清空。
    @Published private(set) var connectedPeer: SyncConnectedPeer?

    /// 允许局域网设备连接（UserDefaults 持久化，缺省 **true**）。
    /// 置 false → `stop()`；置 true → `start()`（走 `SyncHostGate` 判定，幂等）。
    @Published var allowsLANConnections: Bool {
        didSet {
            guard oldValue != allowsLANConnections else { return }
            defaults.set(allowsLANConnections, forKey: Self.allowsLANDefaultsKey)
            applyToggle()
        }
    }

    /// 待批准配对卡（nil = 无待批准）。批准 / 拒绝后清空。
    @Published private(set) var pendingCard: SyncPairingApprovalCard?
    /// 监听启动失败原因（设置页弹窗展示用）。
    @Published private(set) var startError: String?

    /// 已 attach 的 ready 会话（同步控制面读）。会话关闭 / stop 后为 nil。
    private(set) var activeSession: SyncPeerSession?

    /// 设备列表已变化（批准落库后触发；设置页 reloadDevices()）。
    var onDevicesChanged: (() -> Void)?
    /// 拉取结论（诊断/UI 用；M6 T3 接进度展示）。
    var onFetchResult: ((SyncFetchResult) -> Void)?

    // MARK: 内部状态

    private let defaults: UserDefaults
    private let trustStore: DeviceStore
    private var listener: SyncListener?
    private var pendingSession: SyncPeerSession?
    /// 已连接会话（`connectedPeer` 的来源，见 `clearConnection(ifMatching:)`）。
    private var connectedSession: SyncPeerSession?
    /// 已就绪会话的曲库接线（M3-3b：manifest 应答 + 按路径拉取推送）。
    /// 每个 ready 会话一份；会话关闭 / 服务停止时拆除。
    private var libraryHost: MacSyncLibraryHost?

    /// 曲库根（注入便于测试/多根演进；默认 ~/Music/QQPlayer，与 macOS 扫描默认一致）。
    var libraryRootProvider: () -> URL = {
        MusicFolderResolver.macDefaultFolderURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// 本机身份加载（Keychain；失败 → 记 startError 且不启动，绝不静默换 ID）。
    var identityProvider: () throws -> SyncIdentity = {
        try SyncIdentityStore().loadOrCreateIdentity()
    }

    /// 本机展示名（Bonjour 友好名；与设置页 QR hostName 同源）。
    /// 默认取 `LocalDeviceNameStore`：用户命过名用用户的名，否则回落系统默认名
    /// （macOS = `Host.current().localizedName ?? 主机名`，与提升前逐字等价）。
    var deviceNameProvider: () -> String = { LocalDeviceNameStore.shared.name }

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
            print("❌ SyncHostCenter identity load failed: \(error)")
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
            print("❌ SyncHostCenter updateDisplayName failed: \(error)")
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
    func registerQRNonce(nonceBase64: String) {
        guard isRunning, let nonce = Data(base64Encoded: nonceBase64), !nonce.isEmpty else { return }
        listener?.pairingNonces.register(nonce)
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
        onDevicesChanged?()
    }

    /// 用户点「拒绝」：回复拒绝并关闭会话。
    func rejectPending() {
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
