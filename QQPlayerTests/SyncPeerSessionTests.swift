//
//  SyncPeerSessionTests.swift
//  QQPlayerTests
//
//  S2 M2a：会话状态机（handshake → ready → closed）端到端纯逻辑测试。
//  不经 NWConnection：内存回环 SyncPeerTransport 同步投递，握手/配对/
//  加密帧/断连全在测试线程内确定性地跑完。
//
//  覆盖：
//  - 已配对握手：host+client 双 ready，密钥就绪后可加密业务帧 roundtrip
//  - 未配对配对流：QR nonce → 待批准回调 → 批准 → 双向落信任表 + ready；
//    拒绝路径 client 收 pairingRejected
//  - 安全反例：对端公钥错误（冒充）拒、无信任无候选 peerUntrusted、
//    ready 后明文业务帧拒、加密帧重放拒（nonce）
//  - 生命周期：bye 优雅关闭、传输断开 remoteClosed、握手超时
//  - DeviceStore(SyncTrustStore) 适配：真实 GRDB 内存库上读写通
//

import CryptoKit
import Foundation
import GRDB
import Security
import Testing

@testable import QQPlayer

// MARK: - 内存信任表

/// 内存 SyncTrustStore（握手 pinning / 配对落库），协议层注入。
private final class MemoryTrustStore: SyncTrustStore, @unchecked Sendable {
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
private final class LoopbackTransport: SyncPeerTransport, @unchecked Sendable {
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
private struct SessionFixture {
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

// MARK: - 测试

struct SyncPeerSessionTests {
    // MARK: 已配对握手

    @Test("已配对握手：双方 ready，加密业务帧 roundtrip")
    func pairedHandshakeReachesReady() throws {
        let fixture = SessionFixture.pairedHandshake()
        #expect(fixture.hostSession.phase == .ready)
        #expect(fixture.clientSession.phase == .ready)

        // client → host 加密 file_meta 帧
        var received: [SyncFrame] = []
        fixture.hostSession.onApplicationFrame = { frame in
            received.append(frame)
        }
        let meta = Data("曲目元数据".utf8)
        try fixture.clientSession.sendApplicationFrame(type: .fileMeta, payload: meta)
        #expect(received.count == 1)
        #expect(received[0].type == .fileMeta)
        #expect(received[0].payload == meta)
        #expect(!received[0].isEncrypted) // 分发时已解密
    }

    @Test("已配对握手：host→client 加密 chunk 大 payload 往返")
    func pairedChunkLargePayload() throws {
        let fixture = SessionFixture.pairedHandshake()
        var received: [SyncFrame] = []
        fixture.clientSession.onApplicationFrame = { received.append($0) }
        let chunk = Data((0 ..< 200_000).map { UInt8($0 & 0xFF) })
        try fixture.hostSession.sendApplicationFrame(type: .fileChunk, payload: chunk)
        #expect(received.count == 1)
        #expect(received[0].type == .fileChunk)
        #expect(received[0].payload == chunk)
        // 线上帧无破坏性截断（加密后仍小于 16MB 上限）
        #expect(fixture.hostChannel.sentLog.first!.count == chunk.count + SyncFrame.headerLength + 28)
    }

    @Test("ready 前 sendApplicationFrame 抛错")
    func sendBeforeReadyThrows() {
        let fixture = SessionFixture.make()
        fixture.hostSession.handleTransportReady()
        #expect(throws: SyncFrameError.self) {
            try fixture.hostSession.sendApplicationFrame(type: .fileMeta, payload: Data())
        }
    }

    // MARK: 未配对配对流

    @Test("配对流：QR nonce 验签 → 待批准回调 → 批准 → 双向落库 + 双 ready")
    func pairingFlowApproved() throws {
        let fixture = SessionFixture.make()
        // Host 展示 QR：注册一次性 nonce
        let nonce = Data((0 ..< 16).map { UInt8($0) })
        fixture.hostSession.pairingNonces?.register(nonce)
        // Client 扫码：候选（host ID + 公钥 + nonce）
        fixture.clientSession.setPairingExpectations(
            expectedPeerDeviceID: nil,
            candidate: SyncPairingCandidate(
                deviceID: fixture.hostIdentity.deviceID,
                publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                sessionNonce: nonce,
                hostName: "MacBook Pro"
            )
        )
        let expectedClientID = fixture.clientIdentity.deviceID
        // Host 批准回调（UI 层模拟：自动批准）
        fixture.hostSession.pairApprovalHandler = { session, pending in
            #expect(pending.request.clientDeviceID == expectedClientID)
            session.approvePairing(displayName: "老婆的 iPhone")
        }

        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        #expect(fixture.hostSession.phase == .ready)
        #expect(fixture.clientSession.phase == .ready)
        // 双向落库：host 存 client、client 存 host
        #expect(fixture.hostTrust.contains(deviceID: fixture.clientIdentity.deviceID))
        #expect(fixture.clientTrust.contains(deviceID: fixture.hostIdentity.deviceID))
        let clientRecord = fixture.hostTrust.savedDevices.last
        #expect(clientRecord?.displayName == "老婆的 iPhone")
        #expect(clientRecord?.role == .client)
        let hostRecord = fixture.clientTrust.savedDevices.last
        #expect(hostRecord?.displayName == "MacBook Pro")
        #expect(hostRecord?.role == .host)
        // 配对完成后可以发加密业务帧（信任表已生效）
        var received: [SyncFrame] = []
        fixture.hostSession.onApplicationFrame = { received.append($0) }
        try fixture.clientSession.sendApplicationFrame(type: .fileAck, payload: Data([9]))
        #expect(received.count == 1)
    }

    @Test("配对流：host 拒绝 → client 收到 pairingRejected")
    func pairingFlowRejected() throws {
        let fixture = SessionFixture.make()
        let nonce = Data(count: 16)
        fixture.hostSession.pairingNonces?.register(nonce)
        fixture.clientSession.setPairingExpectations(
            expectedPeerDeviceID: nil,
            candidate: SyncPairingCandidate(
                deviceID: fixture.hostIdentity.deviceID,
                publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                sessionNonce: nonce,
                hostName: "MacBook"
            )
        )
        fixture.hostSession.pairApprovalHandler = { session, _ in
            session.rejectPairing(reason: "用户点拒绝")
        }
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        #expect(fixture.clientSession.phase == .closed)
        #expect(fixture.clientSession.closeReason == .pairingRejected("用户点拒绝"))
        #expect(fixture.hostSession.phase == .closed)
        #expect(!fixture.clientTrust.contains(deviceID: fixture.hostIdentity.deviceID))
    }

    @Test("配对流：host 无 nonce 注册 → 拒绝（无效 nonce 签名）")
    func pairingFlowWithoutRegisteredNonceRejected() throws {
        let fixture = SessionFixture.make()
        // 故意不注册 nonce
        fixture.clientSession.setPairingExpectations(
            expectedPeerDeviceID: nil,
            candidate: SyncPairingCandidate(
                deviceID: fixture.hostIdentity.deviceID,
                publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                sessionNonce: Data(count: 16),
                hostName: "MacBook"
            )
        )
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()
        #expect(fixture.clientSession.phase == .closed)
        if case let .pairingRejected(reason?) = fixture.clientSession.closeReason {
            #expect(reason.contains("nonce"))
        } else {
            Issue.record("期望 pairingRejected，实际 \(fixture.clientSession.closeReason)")
        }
    }

    @Test("同一 nonce 只可配对一次（重放 pair_request 拒）")
    func pairingNonceSingleUse() throws {
        let fixture = SessionFixture.make()
        let nonce = Data((1 ..< 17).map { UInt8($0) })
        fixture.hostSession.pairingNonces?.register(nonce)
        fixture.clientSession.setPairingExpectations(
            expectedPeerDeviceID: nil,
            candidate: SyncPairingCandidate(
                deviceID: fixture.hostIdentity.deviceID,
                publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                sessionNonce: nonce,
                hostName: "MacBook"
            )
        )
        // 批准后捕获 client 发的 pair_request 字节用于重放
        fixture.hostSession.pairApprovalHandler = { session, _ in
            session.approvePairing(displayName: nil)
        }
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()
        #expect(fixture.hostSession.phase == .ready)
        // nonce 已消耗
        #expect(fixture.hostSession.pairingNonces?.pendingCount == 0)
        // 换一个全新 client 再拿同一 nonce 签名也无效（nonce 没了）
        let secondClientIdentity = SyncIdentity.generate()
        let secondRequest = try SyncPairingMessages.makePairRequest(
            identity: secondClientIdentity,
            sessionNonce: nonce
        )
        // 注：结构校验过但注册表为空 → 不命中
        #expect(fixture.hostSession.pairingNonces?.matchingNonce(for: secondRequest) == nil)
    }

    // MARK: 安全反例

    @Test("对端公钥错误（冒充已配对设备）→ 双方握手失败关闭")
    func wrongPeerPublicKeyRejected() {
        let fixture = SessionFixture.make()
        // host 的信任表里 client 的公钥是攻击者的（错记录）
        let attacker = SyncIdentity.generate()
        fixture.hostTrust.seed(
            deviceID: fixture.clientIdentity.deviceID,
            publicKeyRaw: attacker.publicKeyRaw,
            role: .client
        )
        fixture.clientTrust.seed(
            deviceID: fixture.hostIdentity.deviceID,
            publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
            role: .host
        )
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        // host 验 client 签名失败 → 关闭
        #expect(fixture.hostSession.phase == .closed)
        if case let .handshakeFailed(failure) = fixture.hostSession.closeReason {
            #expect(failure == .signatureInvalid)
        } else {
            Issue.record("期望 handshakeFailed(.signatureInvalid)，实际 \(fixture.hostSession.closeReason)")
        }
        // client 感知通道断开
        #expect(fixture.clientSession.phase == .closed)
        #expect(fixture.clientSession.closeReason == .remoteClosed)
    }

    @Test("client 未配对且无候选（遇未知 host）→ peerUntrusted")
    func unknownHostWithoutCandidateRejected() {
        let fixture = SessionFixture.make()
        // host 也不知道 client → 走配对流；但 client 没有候选/期望 → 拒
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()
        #expect(fixture.clientSession.phase == .closed)
        if case let .peerUntrusted(deviceID) = fixture.clientSession.closeReason {
            #expect(deviceID == fixture.hostIdentity.deviceID)
        } else {
            Issue.record("期望 peerUntrusted，实际 \(fixture.clientSession.closeReason)")
        }
        fixture.hostSession.cancel()
    }

    @Test("client 期望主机 ID 不符 → identityMismatch 拒绝")
    func wrongExpectedHostRejected() {
        let fixture = SessionFixture.make()
        fixture.clientTrust.seed(
            deviceID: fixture.hostIdentity.deviceID,
            publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
            role: .host
        )
        fixture.hostSession.handleTransportReady()
        // client 以为在连另一台主机
        fixture.clientSession.setPairingExpectations(
            expectedPeerDeviceID: SyncIdentity.generate().deviceID,
            candidate: nil
        )
        fixture.clientSession.handleTransportReady()
        #expect(fixture.clientSession.phase == .closed)
        if case let .handshakeFailed(failure) = fixture.clientSession.closeReason,
           case .identityMismatch = failure {
            // 期望路径正确
        } else {
            Issue.record("期望 identityMismatch，实际 \(fixture.clientSession.closeReason)")
        }
        fixture.hostSession.cancel()
    }

    @Test("ready 后明文业务帧 → 协议违例关闭")
    func plaintextBusinessFrameInReadyRejected() throws {
        let fixture = SessionFixture.pairedHandshake()
        // 手工伪造一帧明文 file_meta 直接喂 host
        let forged = try SyncFrame(type: .fileMeta, flags: [], payload: Data("裸奔".utf8)).encode()
        fixture.hostSession.handleInboundData(forged)
        #expect(fixture.hostSession.phase == .closed)
        if case let .protocolViolation(message) = fixture.hostSession.closeReason {
            #expect(message.contains("加密"))
        } else {
            Issue.record("期望 protocolViolation，实际 \(fixture.hostSession.closeReason)")
        }
    }

    @Test("加密帧重放（同一线上字节二次投递）→ nonce 拒 → 会话关闭")
    func replayedEncryptedFrameRejected() throws {
        let fixture = SessionFixture.pairedHandshake()
        // client 发一帧 → 线上字节入 log（末条即加密业务帧）
        try fixture.clientSession.sendApplicationFrame(type: .fileMeta, payload: Data("original".utf8))
        #expect(fixture.hostSession.phase == .ready)
        // 重放同一字节
        let replayed = try #require(fixture.clientChannel.sentLog.last)
        fixture.hostSession.handleInboundData(replayed)
        #expect(fixture.hostSession.phase == .closed)
        if case let .handshakeFailed(failure) = fixture.hostSession.closeReason {
            #expect(failure == .replayOrOutOfOrder)
        } else {
            Issue.record("期望 handshakeFailed(.replayOrOutOfOrder)，实际 \(fixture.hostSession.closeReason)")
        }
    }

    @Test("坏 magic 字节流 → 协议违例关闭")
    func garbageBytesRejected() {
        let fixture = SessionFixture.pairedHandshake()
        fixture.hostSession.handleInboundData(Data("NOTQQP1...garbage...".utf8))
        #expect(fixture.hostSession.phase == .closed)
        if case let .protocolViolation(message) = fixture.hostSession.closeReason {
            #expect(message.contains("帧解码"))
        }
    }

    // MARK: 生命周期

    @Test("bye：对端优雅关闭，本端收到 receivedBye")
    func byeGracefulClose() throws {
        let fixture = SessionFixture.pairedHandshake()
        try fixture.clientSession.sendBye()
        #expect(fixture.clientSession.phase == .closed)
        #expect(fixture.hostSession.phase == .closed)
        #expect(fixture.hostSession.closeReason == .receivedBye)
    }

    @Test("传输断开（无 bye）→ remoteClosed")
    func transportDropRejected() {
        let fixture = SessionFixture.pairedHandshake()
        fixture.hostChannel.peer = nil // 断开 host→client 方向
        fixture.hostSession.handleTransportClosed()
        #expect(fixture.hostSession.phase == .closed)
        #expect(fixture.hostSession.closeReason == .remoteClosed)
    }

    @Test("握手超时：host 等不到 client hello → handshakeTimeout")
    func handshakeTimeout() async throws {
        let fixture = SessionFixture.make(config: SyncSessionConfiguration(handshakeTimeout: 0.05))
        fixture.hostSession.handleTransportReady()
        #expect(fixture.hostSession.phase == .waitingForPeerHello)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.hostSession.phase == .closed)
        #expect(fixture.hostSession.closeReason == .handshakeTimeout)
    }

    @Test("握手超时后 cancel 幂等、closeReason 不变")
    func cancelAfterCloseIsIdempotent() {
        let fixture = SessionFixture.pairedHandshake()
        fixture.hostSession.cancel()
        fixture.hostSession.cancel() // 二次 cancel 幂等
        #expect(fixture.hostSession.phase == .closed)
        #expect(fixture.hostSession.closeReason == .userCancelled)
    }

    @Test("阶段回调顺序：host 经历 waitingForPeerHello → ready → closed")
    func stateChangeSequence() throws {
        let fixture = SessionFixture.make()
        var states: [SyncSessionPhase] = []
        fixture.hostSession.onStateChange = { states.append($0) }
        fixture.hostTrust.seed(deviceID: fixture.clientIdentity.deviceID,
                               publicKeyRaw: fixture.clientIdentity.publicKeyRaw,
                               role: .client)
        fixture.clientTrust.seed(deviceID: fixture.hostIdentity.deviceID,
                                 publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                                 role: .host)
        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()
        #expect(states.contains(.ready))
        fixture.hostSession.cancel()
        #expect(states.last == .closed)
    }

    // MARK: DeviceStore → SyncTrustStore 适配（真实 GRDB 内存库）

    @Test("DeviceStore 作 SyncTrustStore：读写配对记录通")
    func deviceStoreTrustAdapter() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let store = DeviceStore(database: manager)
        let identity = SyncIdentity.generate()

        // 未配对 → nil（不抛）
        #expect(try store.peerPublicKey(deviceID: identity.deviceID) == nil)
        // savePeer → 可查回同公钥
        try store.savePeer(PeerDevice(
            peerID: identity.deviceID,
            peerPublicKey: identity.publicKeyRaw.base64EncodedString(),
            displayName: "真实存储",
            role: .client,
            pairedAt: 1_700_000_000,
            lastSeenAt: 1_700_000_000,
            notes: nil
        ))
        #expect(try store.peerPublicKey(deviceID: identity.deviceID) == identity.publicKeyRaw)
        // removePeer 幂等
        try store.removePeer(deviceID: identity.deviceID)
        #expect(try store.peerPublicKey(deviceID: identity.deviceID) == nil)
        try store.removePeer(deviceID: identity.deviceID) // 再删不抛
    }
}
