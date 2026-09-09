//
//  MacSyncHostService.swift
//  QQPlayer
//
//  局域网同步（S2 接线）macOS Host 侧监听服务（QQPlayerMac target only）：
//  - 生命周期：MacSyncSettingsView .onAppear 启动 / .onDisappear 停止
//    （stop 同时 cancel 活动会话）；页面可见期间才接受配对。
//  - SyncListener 封装：Bonjour 广播 + 接受连接 → host 会话；QR 刷新时把
//    sessionNonce 注册进 listener.pairingNonces（不注册则配对必被拒）。
//  - 待批准队列：v1 单待批准——新请求到达时若已有待批准，后到覆盖并自动
//    拒绝前一个（防止旧会话悬挂在 waitingForPairApproval 无人应答）。
//  - 批准 → session.approvePairing(displayName:)（落 client 信任记录 →
//    ready）；拒绝 → rejectPairing。批准/拒绝后回调 onDevicesChanged 由
//    页面 reloadDevices()。
//
//  线程：SyncListener 回调在其内部串行队列触发 → 一律 hop 主线程。
//

import Foundation
import Network

/// Mac Host 侧同步监听服务（@MainActor：@Published 状态与存储访问在主线程）。
@MainActor
final class MacSyncHostService: ObservableObject {
    /// 监听是否在运行（页面可见 = true）
    @Published private(set) var isRunning = false
    /// 待批准配对卡（nil = 无待批准）。批准/拒绝后清空。
    @Published private(set) var pendingCard: SyncPairingApprovalCard?
    /// 监听启动失败原因（页面展示用）
    @Published private(set) var startError: String?

    /// 清空启动错误（弹窗关闭后）。
    func clearStartError() {
        startError = nil
    }

    /// 设备列表已变化（批准落库后触发；页面 reloadDevices()）
    var onDevicesChanged: (() -> Void)?

    private let trustStore = DeviceStore()
    private var listener: SyncListener?
    private var pendingSession: SyncPeerSession?

    // MARK: 生命周期（页面 .onAppear / .onDisappear）

    /// 开始监听。identity 为 nil（身份加载失败）时只记录错误不启动。
    func start(identity: SyncIdentity?, deviceName: String) {
        guard let identity else {
            startError = "sync_identity_missing_error".localized
            return
        }
        stop()
        let listener = SyncListener(
            localIdentity: identity,
            trustStore: trustStore,
            deviceName: deviceName
        )
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
        do {
            try listener.start(port: 0)
            self.listener = listener
            isRunning = true
            startError = nil
        } catch {
            startError = "\(error)"
        }
    }

    /// 停止监听并关闭全部活动会话（页面消失/切走）。
    func stop() {
        listener?.stop()
        listener = nil
        pendingSession = nil
        pendingCard = nil
        isRunning = false
    }

    /// 把当前展示 QR 的 sessionNonce（base64 → Data）注册进运行中 listener。
    /// 每次展示/刷新新码调用；未运行（页面不可见）时静默忽略。
    func registerQRNonce(nonceBase64: String) {
        guard isRunning, let nonce = Data(base64Encoded: nonceBase64), !nonce.isEmpty else { return }
        listener?.pairingNonces.register(nonce)
    }

    // MARK: 批准 / 拒绝

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

    // MARK: 待批准呈现

    private func presentPending(_ pending: PendingPairRequest, session: SyncPeerSession) {
        // v1 单待批准：后到覆盖——若已有待批准会话，先拒绝旧的防悬挂
        if let old = pendingSession, old !== session {
            old.rejectPairing(reason: "superseded-by-newer-request")
        }
        let isReplacement = (try? trustStore.byPeerID(pending.request.clientDeviceID)) != nil
        pendingSession = session
        pendingCard = pending.makeApprovalCard(isReplacement: isReplacement)
    }
}
