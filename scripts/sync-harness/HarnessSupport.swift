//
//  HarnessSupport.swift — 本地 harness 夹具（**不参与 App target 编译**）
//
//  与 QQPlayerTests/SyncPeerSessionTestSupport.swift 同构（内存信任表 + 回环通道 +
//  双 ready 会话），去掉 `@testable import QQPlayer` 以便 swiftc 直编。
//

import Foundation
import Security

// MARK: - 锁保护的可变盒子

/// 供 `@Sendable` 回调闭包捕获并回写结果的**锁保护**盒子。
///
/// harness 顶层是同步代码：闭包在会话线程被回调，之后主流程再读回结果。若直接改
/// 捕获的局部 `var`，会被判为「concurrently-executing code 改捕获变量」
/// （Swift 6 起为 error）。把可变状态放进本盒子，读写都在同一把锁内完成。
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    /// 原子读。
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// 原子读-改-写（`body` 在锁内执行）。
    @discardableResult
    func mutate<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

// MARK: - 内存信任表

final class MemoryTrustStore: SyncTrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: (publicKey: Data, name: String, role: PeerRole)] = [:]

    func seed(deviceID: String, publicKeyRaw: Data, displayName: String = "测试设备", role: PeerRole = .host) {
        lock.lock()
        defer { lock.unlock() }
        records[deviceID] = (publicKeyRaw, displayName, role)
    }

    func peerPublicKey(deviceID: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return records[deviceID]?.publicKey
    }

    func savePeer(_ device: PeerDevice) throws {
        lock.lock()
        defer { lock.unlock() }
        records[device.peerID] = (Data(base64Encoded: device.peerPublicKey) ?? Data(), device.displayName, device.role)
    }

    func removePeer(deviceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        records[deviceID] = nil
    }
}

// MARK: - 内存回环通道

final class LoopbackTransport: SyncPeerTransport, @unchecked Sendable {
    weak var session: SyncPeerSession?
    var peer: LoopbackTransport?

    func sendFrameBytes(_ data: Data) {
        peer?.deliver(data)
    }

    func closeTransport() {
        peer?.notifyClosed()
    }

    func deliver(_ data: Data) {
        session?.handleInboundData(data)
    }

    func notifyClosed() {
        session?.handleTransportClosed()
    }
}

// MARK: - 手动投递通道（窗口 / 滞后 ack 用例）

/// 与 `LoopbackTransport` 同协议，但 `send` 只**入队**，由用例 `flush` 决定何时投递对端。
///
/// 为什么需要（2026-11-06 滑动窗口）：同步回环下「发一块 → 立刻收到 ack」⇒ 窗口里永远
/// 只有 1 块在途，窗口 8 与窗口 1 在行为上不可区分（等于没测）。攒住帧才有观察点：
/// 「一次补齐发了几块」= 窗口占用。
final class DeferredTransport: SyncPeerTransport, @unchecked Sendable {
    weak var session: SyncPeerSession?
    var peer: DeferredTransport?
    private let lock = NSLock()
    private var outbox: [Data] = []
    private var history: [Data] = []

    func sendFrameBytes(_ data: Data) {
        lock.lock()
        outbox.append(data)
        history.append(data)
        lock.unlock()
    }

    func closeTransport() {
        peer?.deliverClosed()
    }

    /// 待投递帧数。
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return outbox.count
    }

    /// 待投递帧的类型（帧头第 9 字节 = type，恒明文）。
    var pendingTypes: [SyncFrameType] {
        lock.lock(); defer { lock.unlock() }
        return outbox.compactMap { data in
            guard data.count >= SyncFrame.headerLength else { return nil }
            return SyncFrameType(rawValue: data[data.startIndex + 8])
        }
    }

    /// 本端发出过的全部原始帧（flags / 载荷体量断言用）。
    var sentFrames: [Data] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    /// 把队列里的帧按顺序投递给对端；投递中新产生的帧留在队列（不参与本轮）。
    /// - Returns: 本轮投递帧数
    @discardableResult
    func flushAll() -> Int {
        lock.lock()
        let batch = outbox
        outbox.removeAll()
        lock.unlock()
        for data in batch { peer?.deliver(data) }
        return batch.count
    }

    /// 只投递队首 `count` 帧（滞后 ack / 半窗推进用）。
    @discardableResult
    func flush(_ count: Int) -> Int {
        lock.lock()
        let n = min(count, outbox.count)
        let batch = Array(outbox.prefix(n))
        outbox.removeFirst(n)
        lock.unlock()
        for data in batch { peer?.deliver(data) }
        return n
    }

    /// 取下一条待投递帧（用例手工编排投递顺序用，例如多文件交织 / 分步推进）。
    func takeNext() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !outbox.isEmpty else { return nil }
        return outbox.removeFirst()
    }

    func deliver(_ data: Data) {
        session?.handleInboundData(data)
    }

    func deliverClosed() {
        session?.handleTransportClosed()
    }
}

// MARK: - 手动投递版双 ready 夹具

/// `SessionFixture` 的延迟投递版：握手也走 DeferredTransport（内部反复 flush 直到两端
/// ready），之后由用例逐帧推进。
struct DeferredSessionFixture {
    let hostSession: SyncPeerSession
    let clientSession: SyncPeerSession
    let hostChannel: DeferredTransport
    let clientChannel: DeferredTransport

    static func pairedHandshake() -> DeferredSessionFixture {
        let hostIdentity = SyncIdentity.generate()
        let clientIdentity = SyncIdentity.generate()
        let hostTrust = MemoryTrustStore()
        let clientTrust = MemoryTrustStore()
        let hostChannel = DeferredTransport()
        let clientChannel = DeferredTransport()
        hostChannel.peer = clientChannel
        clientChannel.peer = hostChannel

        let hostSession = SyncPeerSession(
            role: .host,
            localIdentity: hostIdentity,
            trustStore: hostTrust,
            config: SyncSessionConfiguration(),
            pairingNonces: SyncPairingNonceRegistry(),
            transport: hostChannel
        )
        let clientSession = SyncPeerSession(
            role: .client,
            localIdentity: clientIdentity,
            trustStore: clientTrust,
            config: SyncSessionConfiguration(),
            transport: clientChannel
        )
        hostChannel.session = hostSession
        clientChannel.session = clientSession

        hostTrust.seed(deviceID: clientIdentity.deviceID, publicKeyRaw: clientIdentity.publicKeyRaw,
                       displayName: "iPhone", role: .client)
        clientTrust.seed(deviceID: hostIdentity.deviceID, publicKeyRaw: hostIdentity.publicKeyRaw,
                         displayName: "MacBook", role: .host)
        hostSession.handleTransportReady()
        clientSession.handleTransportReady()
        // 已配对重连：hello 一来一回即 ready（20 轮上限 = 防死循环的硬闸）
        var rounds = 0
        while !(hostSession.isReady && clientSession.isReady), rounds < 20 {
            hostChannel.flushAll()
            clientChannel.flushAll()
            rounds += 1
        }
        hostChannel.flushAll()
        clientChannel.flushAll()
        return DeferredSessionFixture(
            hostSession: hostSession,
            clientSession: clientSession,
            hostChannel: hostChannel,
            clientChannel: clientChannel
        )
    }
}

// MARK: - R3a 曲库事实桩（选择集展开器注入）

/// 内存曲库事实（歌单 → 曲目 → content_hash/相对路径）：harness 里模拟 Mac 侧 DB。
/// `playlists[id]` 缺席 = 歌单不存在（展开器据此记入 unknownPlaylistIDs）。
struct MemoryCollectionFacts: SyncCollectionFactsProviding {
    var playlists: [String: [SyncCollectionTrackFact]] = [:]
    var knownPaths: [String: SyncCollectionTrackFact] = [:]
    var lyricsWirePaths: Set<String> = []

    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? {
        playlists[playlistID]
    }

    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        knownPaths[relativePath]
    }

    func hasLyrics(atWirePath wirePath: String) -> Bool {
        lyricsWirePaths.contains(wirePath)
    }
}

// MARK: - R3b 携带事实桩 + 携带替身

/// 内存携带事实（模拟 Mac 侧 DB：相对路径 → 曲目事实；stableId → 播放数据行）。
struct MemoryCarryFacts: SyncPlaybackCarryFactsProviding {
    /// 相对路径 → 曲目事实
    var tracks: [String: SyncCollectionTrackFact] = [:]
    /// 本端 stableId → 待携带播放数据行（未过滤 delete）
    var rows: [String: [SyncPlaybackCarryRow]] = [:]

    func trackFact(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        tracks[relativePath]
    }

    func playbackRows(forTrackStableId stableId: String) -> [SyncPlaybackCarryRow] {
        rows[stableId] ?? []
    }
}

/// R3b 携带替身（无模拟器 harness 用）：跑**真实**计划器（纯逻辑），只记录计划、不发帧。
final class CarrySpyDriver: SyncPlaybackCarryDriving, @unchecked Sendable {
    private let facts: SyncPlaybackCarryFactsProviding
    private let lock = NSLock()
    private var pushPlans: [SyncPlaybackCarryPlan] = []
    private var pullPlans: [SyncPlaybackCarryPlan] = []

    init(facts: SyncPlaybackCarryFactsProviding) {
        self.facts = facts
    }

    var pushCarryPlans: [SyncPlaybackCarryPlan] {
        lock.lock(); defer { lock.unlock() }; return pushPlans
    }

    var pullCarryPlans: [SyncPlaybackCarryPlan] {
        lock.lock(); defer { lock.unlock() }; return pullPlans
    }

    /// 最近一次推送携带计划（nil = 从未触发）。
    var lastPushPlan: SyncPlaybackCarryPlan? { pushCarryPlans.last }
    /// 最近一次拉取携带计划（nil = 从未触发）。
    var lastPullPlan: SyncPlaybackCarryPlan? { pullCarryPlans.last }

    func carryPush(transferredPaths: [String], peerEntries: [ManifestEntry]) throws -> SyncPlaybackCarryPlan {
        let scope = SyncPlaybackCarryScope.afterTransfer(
            direction: .push,
            transferredPaths: transferredPaths,
            peerEntries: peerEntries,
            facts: facts
        )
        let plan = SyncPlaybackCarryPlanner.plan(scope: scope, facts: facts)
        lock.lock(); pushPlans.append(plan); lock.unlock()
        return plan
    }

    func carryPull(transferredPaths: [String], peerEntries: [ManifestEntry]) throws -> SyncPlaybackCarryPlan {
        let scope = SyncPlaybackCarryScope.afterTransfer(
            direction: .pull,
            transferredPaths: transferredPaths,
            peerEntries: peerEntries,
            facts: facts
        )
        let plan = SyncPlaybackCarryPlanner.pairingPlan(scope: scope, facts: facts)
        lock.lock(); pullPlans.append(plan); lock.unlock()
        return plan
    }
}

// MARK: - 双 ready 会话夹具

struct SessionFixture {
    let hostIdentity: SyncIdentity
    let clientIdentity: SyncIdentity
    let hostSession: SyncPeerSession
    let clientSession: SyncPeerSession

    static func pairedHandshake() -> SessionFixture {
        let hostIdentity = SyncIdentity.generate()
        let clientIdentity = SyncIdentity.generate()
        let hostTrust = MemoryTrustStore()
        let clientTrust = MemoryTrustStore()
        let hostChannel = LoopbackTransport()
        let clientChannel = LoopbackTransport()
        hostChannel.peer = clientChannel
        clientChannel.peer = hostChannel

        let hostSession = SyncPeerSession(
            role: .host,
            localIdentity: hostIdentity,
            trustStore: hostTrust,
            config: SyncSessionConfiguration(),
            pairingNonces: SyncPairingNonceRegistry(),
            transport: hostChannel
        )
        let clientSession = SyncPeerSession(
            role: .client,
            localIdentity: clientIdentity,
            trustStore: clientTrust,
            config: SyncSessionConfiguration(),
            transport: clientChannel
        )
        hostChannel.session = hostSession
        clientChannel.session = clientSession

        hostTrust.seed(deviceID: clientIdentity.deviceID, publicKeyRaw: clientIdentity.publicKeyRaw,
                       displayName: "iPhone", role: .client)
        clientTrust.seed(deviceID: hostIdentity.deviceID, publicKeyRaw: hostIdentity.publicKeyRaw,
                         displayName: "MacBook", role: .host)
        hostSession.handleTransportReady()
        clientSession.handleTransportReady()
        return SessionFixture(
            hostIdentity: hostIdentity,
            clientIdentity: clientIdentity,
            hostSession: hostSession,
            clientSession: clientSession
        )
    }
}
