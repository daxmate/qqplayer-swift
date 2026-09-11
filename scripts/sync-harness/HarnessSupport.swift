//
//  HarnessSupport.swift — 本地 harness 夹具（**不参与 App target 编译**）
//
//  与 QQPlayerTests/SyncPeerSessionTestSupport.swift 同构（内存信任表 + 回环通道 +
//  双 ready 会话），去掉 `@testable import QQPlayer` 以便 swiftc 直编。
//

import Foundation
import Security

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
