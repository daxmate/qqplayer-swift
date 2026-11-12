//
//  SyncProtocolHardeningTests.swift
//  QQPlayerTests
//
//  T1 同步协议硬化（2026-11-12）回归防线：
//  - INV-36　迟到 / 跨代际的 pull 应答必须被**幂等接受**，不得因代际翻转静默丢弃；
//             已应用过的批重复到达要被识别为重复（不重复应用）
//  - INV-37　链路事实必须落盘（addr / if / link / importing / pullSent / pullRecv /
//             pullLate / probeMBps 缺失即缺陷；取不到写 -1，不许编造）
//
//  说明：用例只做代码级验证（内存回环会话 + 内存库），不启动模拟器、不做视觉自检。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

private let hardeningLibraryRoot = URL(fileURLWithPath: "/library")

@MainActor
struct SyncProtocolHardeningTests {
    // MARK: - Fixture

    private struct Pair {
        let fixture: SessionFixture
        let hostQueue: DatabaseQueue
        let clientQueue: DatabaseQueue
        let hostManager: DatabaseManager
        let clientManager: DatabaseManager
    }

    private func makePair() throws -> Pair {
        let fixture = SessionFixture.pairedHandshake()
        let hostQueue = try DatabaseQueue()
        let hostManager = DatabaseManager(dbWriter: hostQueue)
        try hostManager.createTables()
        let clientQueue = try DatabaseQueue()
        let clientManager = DatabaseManager(dbWriter: clientQueue)
        try clientManager.createTables()
        return Pair(
            fixture: fixture,
            hostQueue: hostQueue,
            clientQueue: clientQueue,
            hostManager: hostManager,
            clientManager: clientManager
        )
    }

    private static func insertTrack(
        _ queue: DatabaseQueue,
        stableId: String,
        contentHash: String?
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: [stableId, "T-\(stableId)", "/m/\(stableId).flac", contentHash]
            )
        }
    }

    private static func favoriteIDs(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id")
        }
    }

    /// 一行的远端收藏批（contentHash 走第一身份映射）。
    private static func favoriteBatch(
        stableKey: String,
        contentHash: String,
        lastOutboxID: Int64
    ) -> SyncChangeLogPushPayload {
        SyncChangeLogPushPayload(
            entries: [
                SyncChangeLogWireEntry(
                    id: lastOutboxID,
                    entity: SyncChangeEntity.favorite.rawValue,
                    rowKey: stableKey,
                    op: SyncChangeOp.upsert.rawValue,
                    updatedAtMs: 2_000,
                    contentHash: contentHash,
                    payloadJSON: nil
                ),
            ],
            lastOutboxID: lastOutboxID
        )
    }

    /// 首发即超时的策略（用于「收尾后才到」的迟到应答用例）。
    private static let noRetryPolicy = SyncPullRetryPolicy(
        maxAttempts: 1,
        noAnswerDelays: [],
        notReadyMaxAttempts: 1,
        notReadyDelays: [],
        notReadyWindow: 0.2
    )

    private func waitUntilFinished(
        _ coordinator: SyncDataSyncCoordinator,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !coordinator.report.isFinished, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.report.isFinished, "协调器必须在超时前收尾")
    }

    // MARK: - INV-36

    @Test("INV-36 迟到应答：收尾后到达的 pull 应答仍幂等应用并记账（不静默丢弃）")
    func inv36LateAnswerIsAccepted() async throws {
        let pair = try makePair()
        try Self.insertTrack(pair.hostQueue, stableId: "late-track", contentHash: "H-late")

        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.fixture.clientIdentity.deviceID,
            retryPolicy: Self.noRetryPolicy,
            libraryRoot: hardeningLibraryRoot
        )
        coordinator.start(timeout: 0.05)
        try await waitUntilFinished(coordinator)
        let firstFailure = coordinator.report.failureMessage
        #expect(firstFailure != nil, "首发超时必须显式失败（不静默）")

        // 收尾之后对端才把应答送到（真机 2026-11-12 的场景：应答已发、未被消费）。
        let late = Self.favoriteBatch(stableKey: "late-track", contentHash: "H-late", lastOutboxID: 7)
        try pair.fixture.clientSession.sendApplicationFrame(
            type: .changeLogPush,
            payload: try JSONEncoder().encode(late)
        )

        let report = coordinator.report
        #expect(report.pullLate == 1, "迟到应答必须被记成 pullLate（不是静默丢弃）")
        #expect(report.pullRecv == 0, "迟到 ≠ 窗口内收到")
        #expect(report.appliedEntries == 1, "迟到应答的数据必须照常落库")
        #expect(try Self.favoriteIDs(pair.hostQueue) == ["late-track"])
        #expect(report.failureMessage == firstFailure, "迟到帧不得覆盖首次结论")
    }

    @Test("INV-36 跨代际应答：第一次超时重发后，应答仍被接受并收尾成功")
    func inv36CrossGenerationAnswerIsAccepted() async throws {
        let pair = try makePair()
        try Self.insertTrack(pair.hostQueue, stableId: "gen-track", contentHash: "H-gen")

        // 应答端只在**第 2 次** pull 时才回包（第 1 次的应答窗口已翻页）。
        let responder = ManualPullResponder(
            session: pair.fixture.clientSession,
            answerAfter: 2,
            payload: Self.favoriteBatch(stableKey: "gen-track", contentHash: "H-gen", lastOutboxID: 1)
        )
        _ = responder

        let policy = SyncPullRetryPolicy(
            maxAttempts: 3,
            noAnswerDelays: [0.05, 0.05],
            notReadyMaxAttempts: 1,
            notReadyDelays: [],
            notReadyWindow: 0.2
        )
        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.fixture.clientIdentity.deviceID,
            retryPolicy: policy,
            libraryRoot: hardeningLibraryRoot
        )
        coordinator.start(timeout: 0.05)
        try await waitUntilFinished(coordinator)

        let report = coordinator.report
        #expect(report.pullAttempts == 2, "应答在第 2 次尝试到达")
        #expect(report.pullSent == 2)
        #expect(report.pullRecv == 1)
        #expect(report.failureMessage == nil, "跨代际应答必须被接受为成功")
        #expect(report.appliedEntries == 1)
    }

    @Test("INV-36 重复批：已应用过的批重复到达不重复应用，但记账")
    func inv36DuplicateBatchIsNotAppliedTwice() async throws {
        let pair = try makePair()
        try Self.insertTrack(pair.hostQueue, stableId: "dup-track", contentHash: "H-dup")

        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.fixture.clientIdentity.deviceID,
            retryPolicy: Self.noRetryPolicy,
            libraryRoot: hardeningLibraryRoot
        )
        coordinator.start(timeout: 0.05)
        try await waitUntilFinished(coordinator)

        let batch = Self.favoriteBatch(stableKey: "dup-track", contentHash: "H-dup", lastOutboxID: 3)
        let data = try JSONEncoder().encode(batch)
        try pair.fixture.clientSession.sendApplicationFrame(type: .changeLogPush, payload: data)
        try pair.fixture.clientSession.sendApplicationFrame(type: .changeLogPush, payload: data)

        let report = coordinator.report
        #expect(report.appliedEntries == 1, "同一批只应用一次")
        #expect(report.pullDuplicates == 1, "第二次必须被识别为重复批")
        #expect(try Self.favoriteIDs(pair.hostQueue) == ["dup-track"])
    }

    // MARK: - INV-37

    @Test("INV-37 链路事实：conn / frame / run 三类汇总行都带固定 8 字段，取不到写 -1")
    func inv37LinkFactsOnAllKinds() {
        let kinds: [SyncDiagKind] = [.conn, .frame, .run]
        for kind in kinds {
            let sink = LineSink()
            let attempt = SyncDiagAttempt(
                kind: kind,
                role: "client",
                channel: .session,
                emit: { sink.append($0) }
            )
            attempt.finish()
            let line = sink.values.first ?? ""
            for field in ["addr=", "if=", "link=", "importing=", "pullSent=", "pullRecv=", "pullLate=", "probeMBps="] {
                #expect(line.contains(" \(field)"), "\(kind.rawValue) 行缺字段 \(field)：\(line)")
            }
            #expect(line.contains("addr=-1"), "拿不到 addr 必须写 -1（不编造）")
            #expect(line.contains("link=unknown"))
            #expect(line.contains("probeMBps=-1"))
        }
    }

    @Test("INV-37 链路事实：实测值覆盖缺省，顺序固定")
    func inv37LinkFactsMergeAndOrder() {
        var facts = SyncDiagLinkFacts()
        facts.addr = "192.168.1.20:53612"
        facts.interface = "en0"
        facts.link = "wifi"
        facts.importing = true
        facts.pullSent = 2
        facts.pullRecv = 1
        facts.pullLate = 1
        facts.probeMBps = 87.24

        let fields = facts.fields
        #expect(fields == [
            "addr=192.168.1.20:53612",
            "if=en0",
            "link=wifi",
            "importing=1",
            "pullSent=2",
            "pullRecv=1",
            "pullLate=1",
            "probeMBps=87.2",
        ])

        // 缺省值不得覆盖已有实测值（merged 方向：新值只补未知）。
        let merged = SyncDiagLinkFacts().merged(over: facts)
        #expect(merged.addr == "192.168.1.20:53612")
        #expect(merged.link == "wifi")
    }

    @Test("INV-37 链路事实：端点解析只认具体地址，具名服务写 -1")
    func inv37EndpointAddressParsing() {
        #expect(SyncDiagLinkFacts.addr(from: .hostPort(host: "192.168.1.9", port: 53612)) == "192.168.1.9:53612")
        #expect(SyncDiagLinkFacts.addr(from: .service(name: "x", type: "_y._tcp", domain: "local.", interface: nil)) == "-1")
        #expect(SyncDiagLinkFacts.addr(from: nil) == "-1")
    }
}

/// 诊断行捕获（测试用）。
private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}

/// 手工应答端（测试用）：按「第几次 pull」决定是否回包。
private final class ManualPullResponder: @unchecked Sendable {
    private let session: SyncPeerSession
    private let answerAfter: Int
    private let payload: SyncChangeLogPushPayload
    private let lock = NSLock()
    private var seen = 0
    private var prior: (@Sendable (SyncFrame) -> Void)?

    init(session: SyncPeerSession, answerAfter: Int, payload: SyncChangeLogPushPayload) {
        self.session = session
        self.answerAfter = answerAfter
        self.payload = payload
        self.prior = session.onApplicationFrame
        session.onApplicationFrame = { [weak self] frame in
            guard let self else { return }
            if frame.type == .changeLogPull {
                self.handlePull(frame)
            }
            self.prior?(frame)
        }
    }

    private func handlePull(_ frame: SyncFrame) {
        lock.lock()
        seen += 1
        let index = seen
        lock.unlock()
        guard index >= answerAfter else { return }
        let request = try? JSONDecoder().decode(SyncChangeLogPullRequest.self, from: frame.payload)
        var reply = payload
        // 回带请求 id（T1：只用于诊断 / 去重，不参与接受判定）。
        reply.requestID = request?.requestID
        guard let data = try? JSONEncoder().encode(reply) else { return }
        try? session.sendApplicationFrame(type: .changeLogPush, payload: data)
    }
}
