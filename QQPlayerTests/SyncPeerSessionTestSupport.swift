//
//  SyncPeerSessionTestSupport.swift
//  QQPlayerTests
//
//  S2 M2a/M2b 会话测试共享夹具（从 SyncPeerSessionTests.swift 抽出，避免多测试文件复制）：
//  - MemoryTrustStore：内存 SyncTrustStore（握手 pinning / 配对落库）
//  - LoopbackTransport：内存回环 SyncPeerTransport（send 同步投递对端）
//  - SessionFixture：host+client 双会话 + 回环通道；make() 裸建、pairedHandshake() 双 ready
//  抽出处：SyncPeerSessionTests.swift（删除原 private 声明，访问级改 internal）。
//

import Foundation
import Security

@testable import QQPlayer

// MARK: - 内存信任表

/// 内存 SyncTrustStore（握手 pinning / 配对落库），协议层注入。
final class MemoryTrustStore: SyncTrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: PeerDevice] = [:]
    private(set) var savedDevices: [PeerDevice] = []
    var failReads = false
    var failWrites = false

    func seed(deviceID: String, publicKeyRaw: Data, displayName: String = "测试设备", role: PeerRole = .host) {
        lock.lock()
        defer { lock.unlock() }
        let now = Int64(Date().timeIntervalSince1970)
        records[deviceID] = PeerDevice(
            peerID: deviceID,
            peerPublicKey: publicKeyRaw.base64EncodedString(),
            displayName: displayName,
            role: role,
            pairedAt: now,
            lastSeenAt: now,
            notes: nil
        )
    }

    func peerPublicKey(deviceID: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if failReads { throw SyncKeychainError.status(errSecNotAvailable) }
        return records[deviceID].flatMap { Data(base64Encoded: $0.peerPublicKey) }
    }

    func savePeer(_ device: PeerDevice) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw SyncKeychainError.status(errSecNotAvailable) }
        records[device.peerID] = device
        savedDevices.append(device)
    }

    func removePeer(deviceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        records[deviceID] = nil
    }

    func contains(deviceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records[deviceID] != nil
    }
}

// MARK: - 内存回环 transport

/// 会话 ↔ 会话的同步字节通道：一方 send 立即投递给对端 session。
final class LoopbackTransport: SyncPeerTransport, @unchecked Sendable {
    weak var session: SyncPeerSession?
    var peer: LoopbackTransport?
    /// 本端发出的全部线上字节（重放攻击测试取用）
    private(set) var sentLog: [Data] = []
    private let lock = NSLock()

    func sendFrameBytes(_ data: Data) {
        lock.lock()
        sentLog.append(data)
        lock.unlock()
        peer?.deliver(data)
    }

    func closeTransport() {
        // 模拟通道关闭：对端感知断开（幂等由会话保证）
        peer?.notifyClosed()
    }

    func deliver(_ data: Data) {
        session?.handleInboundData(data)
    }

    func notifyClosed() {
        session?.handleTransportClosed()
    }
}

// MARK: - 夹具

/// 一套 host+client 会话 + 回环通道（含信任表种子等）。
struct SessionFixture {
    let hostIdentity: SyncIdentity
    let clientIdentity: SyncIdentity
    let hostTrust: MemoryTrustStore
    let clientTrust: MemoryTrustStore
    let hostSession: SyncPeerSession
    let clientSession: SyncPeerSession
    let hostChannel: LoopbackTransport
    let clientChannel: LoopbackTransport

    /// 双 ready（已配对握手）。调用方先在各自信任表 seed 对方公钥。
    static func pairedHandshake(config: SyncSessionConfiguration = SyncSessionConfiguration()) -> SessionFixture {
        let fixture = make(config: config)
        fixture.hostTrust.seed(deviceID: fixture.clientIdentity.deviceID,
                               publicKeyRaw: fixture.clientIdentity.publicKeyRaw,
                               displayName: "iPhone", role: .client)
        fixture.clientTrust.seed(deviceID: fixture.hostIdentity.deviceID,
                                 publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                                 displayName: "MacBook", role: .host)
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()
        return fixture
    }

    static func make(config: SyncSessionConfiguration = SyncSessionConfiguration()) -> SessionFixture {
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
            config: config,
            pairingNonces: SyncPairingNonceRegistry(),
            transport: hostChannel
        )
        let clientSession = SyncPeerSession(
            role: .client,
            localIdentity: clientIdentity,
            trustStore: clientTrust,
            config: config,
            transport: clientChannel
        )
        hostChannel.session = hostSession
        clientChannel.session = clientSession
        return SessionFixture(
            hostIdentity: hostIdentity,
            clientIdentity: clientIdentity,
            hostTrust: hostTrust,
            clientTrust: clientTrust,
            hostSession: hostSession,
            clientSession: clientSession,
            hostChannel: hostChannel,
            clientChannel: clientChannel
        )
    }
}
