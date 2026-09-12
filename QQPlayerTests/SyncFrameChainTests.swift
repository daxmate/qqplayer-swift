//
//  SyncFrameChainTests.swift
//  QQPlayerTests
//
//  🟡F1「会话事件分发链」+ 🟡F2「QR nonce TTL / 清理入口」回归用例。
//
//  F1 的缺陷是**释放语义**：旧写法每个 peer 各写一份闭包链
//  （`guard let self ... else { self?.priorAppHandler?(frame); return }`），
//  peer 一释放 → 挂接更早的 handler 在本次会话余下时间全部收不到帧。
//  所以这里用**真实双会话夹具**（内存回环 + 已配对 ready）验证分发行为，
//  而不是只测分发链类本身：断言"peer 释放后更早的 handler 仍收得到"。
//
//  F2 的缺陷是 nonce 无 TTL / 无清理入口：展示过的旧 QR 在 App 生命周期内一直可配对。
//  用例覆盖 TTL 边界、重复注册续期、清理入口语义，以及"过期 nonce → 明确失败"的会话级行为。
//

import Foundation
import Testing

@testable import QQPlayer

/// 分发链上的"更早 handler"观察者：记录收到的帧 / 关闭事件 / 顺序标签。
private final class SyncEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SyncFrame] = []
    private var closes: [SyncSessionCloseReason] = []
    private var tags: [String] = []

    func recordFrame(_ frame: SyncFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func recordClose(_ reason: SyncSessionCloseReason) {
        lock.lock()
        closes.append(reason)
        lock.unlock()
    }

    func recordTag(_ tag: String) {
        lock.lock()
        tags.append(tag)
        lock.unlock()
    }

    var receivedFrames: [SyncFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var receivedCloses: [SyncSessionCloseReason] {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    var receivedTags: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tags
    }
}

struct SyncFrameChainTests {
    // MARK: - 🟡F1：peer 释放不牵连链上其它 handler

    /// 修复前必红：旧写法里 `SyncManifestPeer` 的闭包是
    /// `guard let self ... else { self?.priorAppHandler?(frame); return }`——
    /// self 已释放 → prior **不被调用** → 观察者收到 0 帧。
    /// （把本用例的 `SyncSessionAttachment` 换回裸赋值 `session.onApplicationFrame = { ... }`，
    /// 即是修复前的等价写法，断言同样为 0 帧。）
    @Test("🟡F1：链头 peer 释放后，更早挂接的 handler 仍能收到应用帧")
    func earlierFrameHandlerSurvivesPeerRelease() throws {
        let fixture = SessionFixture.pairedHandshake()
        let recorder = SyncEventRecorder()
        let attachment = SyncSessionAttachment(session: fixture.clientSession, owner: recorder) { frame in
            recorder.recordFrame(frame)
        }
        defer { attachment.detach() }

        // 后挂接的 peer；生产触发点：编排计划完成即 `manifestPeer = nil`
        // （SyncCollectionSyncCoordinator 计划完成 / 失败 / 超时三处）。
        var peer: SyncManifestPeer? = SyncManifestPeer(session: fixture.clientSession)
        peer?.localManifestProvider = { _ in [] }
        #expect(peer != nil)
        peer = nil

        try fixture.hostSession.sendApplicationFrame(type: .manifestRequest, payload: Data("{}".utf8))

        #expect(recorder.receivedFrames.count == 1)
        #expect(recorder.receivedFrames.first?.type == .manifestRequest)
    }

    /// 修复前必红：旧写法（本仓库 SyncPeerLibraryClient / SyncLibraryFetchResponder 同款）
    /// 是 `guard let self else { return }`——self 释放后直接 return，**连 prior 都不调**。
    @Test("🟡F1：链头 peer 释放后，更早挂接的 onClosed handler 仍收到关闭事件")
    func earlierClosedHandlerSurvivesPeerRelease() {
        let fixture = SessionFixture.pairedHandshake()
        let recorder = SyncEventRecorder()
        let attachment = SyncSessionAttachment(
            session: fixture.clientSession,
            owner: recorder,
            onClosed: { reason in recorder.recordClose(reason) }
        )
        defer { attachment.detach() }

        var client: SyncPeerLibraryClient? = SyncPeerLibraryClient(session: fixture.clientSession)
        #expect(client != nil)
        client = nil

        fixture.clientSession.cancel(reason: .userCancelled)

        #expect(recorder.receivedCloses == [.userCancelled])
    }

    /// 释放语义不变式：分发顺序仍是"后挂接的先处理、会话原有 handler 最后"（旧链同款）。
    @Test("🟡F1：分发顺序与旧闭包链一致（后挂先处理）")
    func dispatchOrderMatchesLegacyChain() throws {
        let fixture = SessionFixture.pairedHandshake()
        let recorder = SyncEventRecorder()
        let firstAttachment = SyncSessionAttachment(session: fixture.clientSession, owner: recorder) { _ in
            recorder.recordTag("first-attached")
        }
        let laterAttachment = SyncSessionAttachment(session: fixture.clientSession, owner: recorder) { _ in
            recorder.recordTag("later-attached")
        }
        defer {
            firstAttachment.detach()
            laterAttachment.detach()
        }

        try fixture.hostSession.sendApplicationFrame(type: .fileAck, payload: Data([1]))

        #expect(recorder.receivedTags == ["later-attached", "first-attached"])
    }

    /// `detach()` 必须**与其它项的增删顺序无关**：摘除先挂接的项不得误拆后挂接的链
    /// （"只认链头"的实现会在此静默拆掉后挂的 handler → 0 帧）。
    @Test("🟡F1：detach() 顺序无关——先摘先挂的，后挂的照常收帧")
    func detachIsOrderIndependent() throws {
        let fixture = SessionFixture.pairedHandshake()
        let recorder = SyncEventRecorder()
        let older = SyncSessionAttachment(session: fixture.clientSession, owner: recorder) { frame in
            recorder.recordFrame(frame)
        }
        let newer = SyncSessionAttachment(session: fixture.clientSession, owner: recorder) { frame in
            recorder.recordFrame(frame)
        }
        defer {
            older.detach()
            newer.detach()
        }

        older.detach()

        try fixture.hostSession.sendApplicationFrame(type: .fileAck, payload: Data([1]))

        #expect(recorder.receivedFrames.count == 1)
    }

    // MARK: - 🟡F2：QR nonce TTL 与清理入口

    /// 修复前必红：旧 registry 没有任何时间概念，301s 后 `matchingNonce` 仍返回该 nonce
    /// （= 展示过的旧 QR 一直可配对）。
    @Test("🟡F2：nonce 超过 TTL 即作废（验签不再命中，池里也清掉）")
    func nonceExpiresByTTL() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var clock = start
        let registry = SyncPairingNonceRegistry(nonceTTL: 300, now: { clock })
        let nonce = Data((0 ..< 16).map { UInt8($0) })
        registry.register(nonce)
        let request = try SyncPairingMessages.makePairRequest(
            identity: SyncIdentity.generate(),
            sessionNonce: nonce,
            clientName: "iPhone"
        )

        clock = start.addingTimeInterval(301)

        #expect(registry.matchingNonce(for: request) == nil)
        #expect(registry.pendingCount == 0)
    }

    /// TTL 边界内仍有效：299s 命中（并消耗）。
    @Test("🟡F2：TTL 内 nonce 仍然有效并被消耗")
    func nonceValidWithinTTL() throws {
        let start = Date(timeIntervalSince1970: 2_000_000)
        var clock = start
        let registry = SyncPairingNonceRegistry(nonceTTL: 300, now: { clock })
        let nonce = Data((16 ..< 32).map { UInt8($0) })
        registry.register(nonce)
        let request = try SyncPairingMessages.makePairRequest(
            identity: SyncIdentity.generate(),
            sessionNonce: nonce,
            clientName: "iPhone"
        )

        clock = start.addingTimeInterval(299)

        #expect(registry.matchingNonce(for: request) == nonce)
        #expect(registry.pendingCount == 0) // 命中即消耗（防重放）
    }

    /// 重复注册同一 nonce = 续期（同一张码重新展示）；注册时顺手清掉过期项。
    @Test("🟡F2：重复注册 = 续期；注册时清理过期项")
    func registerRefreshesTTLAndPurgesExpired() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        var clock = start
        let registry = SyncPairingNonceRegistry(nonceTTL: 300, now: { clock })
        let stale = Data([1, 2, 3])
        let fresh = Data([4, 5, 6])
        registry.register(stale)

        clock = start.addingTimeInterval(200)
        registry.register(stale) // 续期（距注册 200s 时重新展示同一张码）
        #expect(registry.pendingCount == 1)

        clock = start.addingTimeInterval(301) // 距**续期**仅 101s → 未过期
        #expect(registry.pendingCount == 1)

        clock = start.addingTimeInterval(501) // 距续期 301s → 过期，注册新码时清掉
        registry.register(fresh)
        #expect(registry.pendingCount == 1)
    }

    /// 清理入口：remove（展示新码→旧码立即失效）/ removeAll（配对完成 / 停止监听）。
    @Test("🟡F2：remove / removeAll 立即作废（不依赖 TTL 到点）")
    func cleanupEntryPointsInvalidateImmediately() throws {
        let clock = Date(timeIntervalSince1970: 4_000_000)
        let registry = SyncPairingNonceRegistry(now: { clock })
        let identity = SyncIdentity.generate()
        let first = Data([7, 7, 7])
        let second = Data([8, 8, 8])
        registry.register(first)
        registry.register(second)
        #expect(registry.pendingCount == 2)

        let firstRequest = try SyncPairingMessages.makePairRequest(
            identity: identity,
            sessionNonce: first,
            clientName: "iPhone"
        )
        registry.remove(first)

        #expect(registry.matchingNonce(for: firstRequest) == nil) // 旧码立即失效
        #expect(registry.pendingCount == 1)

        registry.removeAll()
        #expect(registry.pendingCount == 0)
    }

    /// 会话级：过期 nonce 的 pair_request → **明确失败**（pairResponse 拒绝 + 会话关闭），
    /// 不静默成功、不弹批准卡。修复前必红：nonce 永不过期 → 走到批准 → 双 ready。
    @Test("🟡F2：过期 nonce 的配对请求明确失败（pairingRejected），不静默成功")
    func expiredNoncePairingFailsExplicitly() {
        let start = Date(timeIntervalSince1970: 5_000_000)
        var clock = start
        let registry = SyncPairingNonceRegistry(nonceTTL: 300, now: { clock })
        let sessions = makePairingSessions(registry: registry)
        let nonce = Data((0 ..< 16).map { UInt8($0) })
        registry.register(nonce)
        sessions.clientSession.setPairingExpectations(
            expectedPeerDeviceID: nil,
            candidate: SyncPairingCandidate(
                deviceID: sessions.hostIdentity.deviceID,
                publicKeyRaw: sessions.hostIdentity.publicKeyRaw,
                sessionNonce: nonce,
                hostName: "MacBook Pro"
            )
        )
        var approvalRequested = false
        sessions.hostSession.pairApprovalHandler = { session, _ in
            approvalRequested = true
            session.approvePairing(displayName: nil)
        }

        clock = start.addingTimeInterval(301) // 展示 300s 后旧码过期

        sessions.hostSession.handleTransportReady()
        sessions.clientSession.handleTransportReady()

        #expect(approvalRequested == false)
        #expect(sessions.hostSession.phase == .closed)
        #expect(sessions.clientSession.phase == .closed)
        #expect(sessions.clientSession.closeReason == .pairingRejected("无效或过期的 nonce 签名"))
        #expect(!sessions.hostTrust.contains(deviceID: sessions.clientIdentity.deviceID))
    }

    // MARK: - 工具

    /// 未配对 host + client 双会话（可注入 nonce 注册表：TTL/时钟）。
    private func makePairingSessions(
        registry: SyncPairingNonceRegistry
    ) -> (
        hostSession: SyncPeerSession,
        clientSession: SyncPeerSession,
        hostIdentity: SyncIdentity,
        clientIdentity: SyncIdentity,
        hostTrust: MemoryTrustStore
    ) {
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
            pairingNonces: registry,
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
        return (hostSession, clientSession, hostIdentity, clientIdentity, hostTrust)
    }
}
