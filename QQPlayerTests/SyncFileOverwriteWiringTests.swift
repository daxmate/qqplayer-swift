//
//  SyncFileOverwriteWiringTests.swift
//  QQPlayerTests
//
//  批 3：文件覆盖判定 + 台账的**生产接线**端到端用例：
//  SyncCollectionSyncCoordinator.handlePeerManifest（差集之后、推 / 拉分派之前）
//  → SyncFileOverwriteGate（读台账 → SyncFileOverwriteJudge → 落台账）→ 推送 / 跳过。
//
//  规格：docs/lan-sync-design.md §6.1；契约 docs/sync-contract.md §2 G；
//  不变量 docs/sync-invariants.md §H INV-33。
//
//  ⚠️ 本套件需要真 GRDB（被动端 DatabaseManager）+ xcodebuild ⇒ 本地不跑，只在 CI 真跑。
//  无模拟器 harness 的同语义断言见 scripts/sync-harness/main.swift ㊽ 节（本地可跑）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 内存台账（fake，证明接线只依赖最小读写接口）

private final class MemoryLedgerStore: SyncFileOverwriteLedgering, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PeerFileStateRow] = [:]
    private var loadCountValue = 0
    /// 注入读失败（判不了 = 保守冲突）。
    var failLoad = false
    /// 注入写失败（写台账不得拖垮同步）。
    var failUpsert = false

    init(_ rows: [PeerFileStateRow] = []) {
        for row in rows {
            storage[Self.key(row)] = row
        }
    }

    private static func key(_ row: PeerFileStateRow) -> String {
        row.peerId + "|" + row.relativePath
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCountValue
    }

    func load(peerId: String) throws -> [PeerFileStateRow] {
        lock.lock()
        defer { lock.unlock() }
        loadCountValue += 1
        if failLoad { throw NSError(domain: "MemoryLedgerStore", code: 1) }
        return storage.values
            .filter { $0.peerId == peerId }
            .sorted { $0.relativePath < $1.relativePath }
    }

    func upsert(_ row: PeerFileStateRow) throws {
        lock.lock()
        defer { lock.unlock() }
        if failUpsert { throw NSError(domain: "MemoryLedgerStore", code: 2) }
        storage[Self.key(row)] = row
    }

    func row(peerId: String, relativePath: String) -> PeerFileStateRow? {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.first { $0.peerId == peerId && $0.relativePath == relativePath }
    }
}

// MARK: - 曲库事实 / 落盘桩

private struct WiringFacts: SyncCollectionFactsProviding {
    var playlists: [String: [SyncCollectionTrackFact]]

    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? {
        playlists[playlistID]
    }

    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        playlists.values.flatMap { $0 }.first { $0.relativePath == relativePath }
    }

    func hasLyrics(atWirePath wirePath: String) -> Bool { false }
}

private final class WiringSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    func indexLandedFile(at url: URL) {}
}

// MARK: - 用例

@MainActor
struct SyncFileOverwriteWiringTests {
    private static let waitLimit: TimeInterval = 10
    private static let path = "Album/wiring.flac"

    // MARK: 夹具

    private struct Scenario {
        let fixture: SessionFixture
        let macRoot: URL
        let deviceRoot: URL
        /// 必须强持有：被动端以 [weak self] 挂接会话
        let deviceHost: SyncLibraryPassiveHost
        let store: MemoryLedgerStore
        let coordinator: SyncCollectionSyncCoordinator
        let peerId: String
    }

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overwrite-wiring-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func silentData(_ marker: UInt8, count: Int) -> Data {
        Data(repeating: marker, count: count)
    }

    /// 上传场景：Mac 有文件（macData）、对端也有同路径文件（deviceData ⇒ 构成覆盖场景）。
    /// 台账行由调用方按 peerId 生成（peerId 来自配对夹具的 client Device ID）。
    private func makeScenario(
        macData: Data?,
        deviceData: Data?,
        direction: SyncTransferDirection = .upload,
        failLoad: Bool = false,
        ledger: @escaping (String) -> [PeerFileStateRow] = { _ in [] },
        configureCoordinator: ((SyncCollectionSyncCoordinator) -> Void)? = nil
    ) throws -> Scenario {
        let fixture = SessionFixture.pairedHandshake()
        let peerId = fixture.clientIdentity.deviceID
        let relativePath = Self.path

        let macRoot = try makeTempRoot("mac")
        if let macData {
            let url = macRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try macData.write(to: url)
        }
        let macHash = macData.map { SyncFileChecksum.sha256Hex(of: $0) }

        let deviceRoot = try makeTempRoot("device")
        if let deviceData {
            let url = deviceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try deviceData.write(to: url)
        }

        let deviceManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try deviceManager.createTables()
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: WiringSinkSpy(),
            database: deviceManager,
            lyricsStore: AlignedLyricsStore(directory: try makeTempRoot("device-lyrics")),
            lyricsMapping: .unresolved
        )
        #expect(deviceHost.attach(to: fixture.clientSession))

        let macLyricsStore = AlignedLyricsStore(directory: try makeTempRoot("mac-lyrics"))
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: macRoot,
            rootName: "接线测试 Mac 曲库",
            sourceFiles: {
                guard let macData, let macHash else { return [] }
                return [
                    SyncManifestSourceFile(
                        relativePath: relativePath,
                        size: Int64(macData.count),
                        contentHash: macHash,
                        stableId: "s-wiring"
                    ),
                ]
            },
            contentHash: { _ in macHash },
            lyricsFileName: { _ in nil }
        )

        // 选择集展开依赖「曲目已入库」事实（download 场景 Mac 无文件也要有事实）。
        let facts = WiringFacts(
            playlists: [
                "p1": [
                    SyncCollectionTrackFact(
                        stableId: "s-wiring",
                        relativePath: relativePath,
                        contentHash: macHash ?? "device-owned"
                    ),
                ],
            ]
        )

        let store = MemoryLedgerStore(ledger(peerId))
        store.failLoad = failLoad
        let gate = SyncFileOverwriteGate(
            peerId: peerId,
            store: store,
            nowMs: { 1_700_000_000_000 }
        )

        // download 用 .all：对端按 playlist 收口时，夹具设备侧没有歌单归属 ⇒ manifest 会空；
        // .all 直接取对端全量清单（与契约「用户显式从设备取回」的实际形状一致）。
        let selectionValue: SyncCollectionSelection = direction == .download ? .all : .playlists(["p1"])
        let coordinator = SyncCollectionSyncCoordinator(
            session: fixture.hostSession,
            descriptor: descriptor,
            selection: selectionValue,
            facts: facts,
            sink: WiringSinkSpy(),
            lyricsStore: macLyricsStore,
            lyricsMapping: .unresolved,
            overwriteGate: gate
        )
        configureCoordinator?(coordinator)
        try coordinator.start(direction: direction)

        return Scenario(
            fixture: fixture,
            macRoot: macRoot,
            deviceRoot: deviceRoot,
            deviceHost: deviceHost,
            store: store,
            coordinator: coordinator,
            peerId: peerId
        )
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Self.waitLimit)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func deviceData(_ scenario: Scenario) throws -> Data {
        try Data(contentsOf: scenario.deviceRoot.appendingPathComponent(Self.path))
    }

    private func makeRow(
        peerId: String,
        state: PeerFileStateRow.State,
        contentHash: String,
        localHashAtDecision: String?
    ) -> PeerFileStateRow {
        PeerFileStateRow(
            peerId: peerId,
            relativePath: Self.path,
            contentHash: contentHash,
            state: state,
            localHashAtDecision: localHashAtDecision
        )
    }

    // MARK: - 规则 4a：kept 且双方未变 → 静默跳过

    @Test("接线 · 规则 4a：kept 且对端 / 本端都未变 → 不推、不弹窗（skipped 桶），台账保持 kept")
    func keptUnchangedIsSilentlySkipped() throws {
        let localData = silentData(0x11, count: 4_096)
        let remoteData = silentData(0x22, count: 4_096)
        let localHash = SyncFileChecksum.sha256Hex(of: localData)
        let remoteHash = SyncFileChecksum.sha256Hex(of: remoteData)
        let scenario = try makeScenario(
            macData: localData,
            deviceData: remoteData,
            ledger: { peerId in
                [self.makeRow(peerId: peerId, state: .kept, contentHash: remoteHash, localHashAtDecision: localHash)]
            }
        )
        #expect(waitUntil { scenario.coordinator.state == .done }, "编排应收敛到终态")
        #expect(scenario.coordinator.report.plannedPush.isEmpty, "静默跳过不得进推送计划")
        #expect(scenario.coordinator.report.overwriteSkipped == [Self.path])
        #expect(scenario.coordinator.report.overwriteConflicts.isEmpty)
        #expect(try deviceData(scenario) == remoteData, "静默跳过：对端文件必须原样")
        let stored = scenario.store.row(peerId: scenario.peerId, relativePath: Self.path)
        #expect(stored?.state == .kept, "静默跳过不改台账状态")
        #expect(stored?.contentHash == remoteHash)
    }

    // MARK: - 规则 4c：kept 且对端又变 → 冲突

    @Test("接线 · 规则 4c：kept 但对端文件又变 → 本轮不覆盖（peerChanged），台账落 pending")
    func keptPeerChangedBlocksAndRecordsPending() throws {
        let localData = silentData(0x31, count: 4_096)
        let remoteData = silentData(0x32, count: 4_096)
        let remoteHash = SyncFileChecksum.sha256Hex(of: remoteData)
        let scenario = try makeScenario(
            macData: localData,
            deviceData: remoteData,
            ledger: { peerId in
                [self.makeRow(peerId: peerId, state: .kept, contentHash: "stale-peer-hash", localHashAtDecision: SyncFileChecksum.sha256Hex(of: localData))]
            }
        )
        #expect(waitUntil { scenario.coordinator.state == .done })
        #expect(scenario.coordinator.report.plannedPush.isEmpty, "冲突项本轮不得推送")
        #expect(scenario.coordinator.report.overwriteConflicts.map(\.reason) == [.peerChanged])
        #expect(try deviceData(scenario) == remoteData, "冲突：对端文件不能被覆盖")
        let stored = scenario.store.row(peerId: scenario.peerId, relativePath: Self.path)
        #expect(stored?.state == .pending, "判为冲突 → 待确认（pending）")
        #expect(stored?.contentHash == remoteHash, "pending 行的 content_hash = 对端指纹")
    }

    // MARK: - 规则 4b：kept 且本端又变 → 冲突

    @Test("接线 · 规则 4b：kept 但本端决策后又变 → 本轮不覆盖（keptLocalChanged）")
    func keptLocalChangedBlocks() throws {
        let localData = silentData(0x41, count: 4_096)
        let remoteData = silentData(0x42, count: 4_096)
        let remoteHash = SyncFileChecksum.sha256Hex(of: remoteData)
        let scenario = try makeScenario(
            macData: localData,
            deviceData: remoteData,
            ledger: { peerId in
                [self.makeRow(peerId: peerId, state: .kept, contentHash: remoteHash, localHashAtDecision: "stale-local-hash")]
            }
        )
        #expect(waitUntil { scenario.coordinator.state == .done })
        #expect(scenario.coordinator.report.plannedPush.isEmpty)
        #expect(scenario.coordinator.report.overwriteConflicts.map(\.reason) == [.keptLocalChanged])
        #expect(try deviceData(scenario) == remoteData)
        #expect(scenario.store.row(peerId: scenario.peerId, relativePath: Self.path)?.state == .pending)
    }

    // MARK: - 规则 2：approved → 允许覆盖，成功后落 agreed

    @Test("接线 · 规则 2：approved 且本端未再变 → 覆盖执行，推送成功后台账落 agreed")
    func approvedOverwriteProceedsAndRecordsAgreed() throws {
        let localData = silentData(0x51, count: 8_000)
        let remoteData = silentData(0x52, count: 8_000)
        let localHash = SyncFileChecksum.sha256Hex(of: localData)
        let remoteHash = SyncFileChecksum.sha256Hex(of: remoteData)
        let scenario = try makeScenario(
            macData: localData,
            deviceData: remoteData,
            ledger: { peerId in
                [self.makeRow(peerId: peerId, state: .approved, contentHash: remoteHash, localHashAtDecision: localHash)]
            }
        )
        #expect(waitUntil { scenario.coordinator.state == .done })
        #expect(scenario.coordinator.report.overwriteConflicts.isEmpty)
        #expect(scenario.coordinator.report.pushed.contains(Self.path), "确认后应真的推送")
        #expect(try deviceData(scenario) == localData, "确认后对端文件应被覆盖为 Mac 版本")
        let stored = scenario.store.row(peerId: scenario.peerId, relativePath: Self.path)
        #expect(stored?.state == .agreed, "推送成功 → agreed")
        #expect(stored?.contentHash == localHash, "agreed 行 = 本次发出的本端指纹")
    }

    // MARK: - 读台账失败：保守冲突

    @Test("接线 · 台账读取失败 → 本轮全部按冲突处理（undecidable），绝不静默覆盖")
    func ledgerReadFailureIsConservative() throws {
        let localData = silentData(0x61, count: 4_096)
        let remoteData = silentData(0x62, count: 4_096)
        let scenario = try makeScenario(
            macData: localData,
            deviceData: remoteData,
            failLoad: true
        )
        #expect(waitUntil { scenario.coordinator.state == .done })
        #expect(scenario.coordinator.report.plannedPush.isEmpty)
        #expect(scenario.coordinator.report.overwriteConflicts.map(\.reason) == [.undecidable])
        #expect(try deviceData(scenario) == remoteData)
    }

    // MARK: - 写台账失败：不拖垮同步

    @Test("接线 · 台账写失败不拖垮同步：approved 覆盖照常完成")
    func ledgerWriteFailureDoesNotAbortSync() throws {
        let localData = silentData(0x71, count: 8_000)
        let remoteData = silentData(0x72, count: 8_000)
        let localHash = SyncFileChecksum.sha256Hex(of: localData)
        let remoteHash = SyncFileChecksum.sha256Hex(of: remoteData)
        let scenario = try makeScenario(
            macData: localData,
            deviceData: remoteData,
            ledger: { peerId in
                [self.makeRow(peerId: peerId, state: .approved, contentHash: remoteHash, localHashAtDecision: localHash)]
            }
        )
        scenario.store.failUpsert = true
        #expect(waitUntil { scenario.coordinator.state == .done })
        #expect(try deviceData(scenario) == localData, "台账写失败不得回滚已完成的传输")
    }

    // MARK: - 契约 G 行唯一例外：显式「从设备取回」不走闸门

    @Test("接线 · 用户显式从设备取回（download）：不读台账、不判覆盖、计划拉取原样")
    func downloadBypassesOverwriteGate() throws {
        let remoteData = silentData(0x81, count: 4_096)
        let scenario = try makeScenario(
            macData: nil,
            deviceData: remoteData,
            direction: .download,
            ledger: { peerId in
                [self.makeRow(peerId: peerId, state: .pending, contentHash: "stale-peer-hash", localHashAtDecision: nil)]
            }
        )
        #expect(waitUntil { scenario.coordinator.report.plannedPull == [Self.path] }, "取回计划应包含对端唯一条目")
        #expect(scenario.store.loadCount == 0, "download 是唯一例外：不得读覆盖台账")
        #expect(scenario.coordinator.report.overwriteConflicts.isEmpty)
        let stored = scenario.store.row(peerId: scenario.peerId, relativePath: Self.path)
        #expect(stored?.state == .pending, "download 不改覆盖台账")
        scenario.coordinator.cancel()
    }

    // MARK: - 装配事实回报（运行时自检）

    @Test("接线 · 装配事实回报：overwriteLedger 未装上 → Mac 装配点报缺口；装上 → 归零")
    func overwriteLedgerAssemblyFactIsReported() {
        let store = SyncWiringFactsStore.shared
        let platform = SyncEntityRegistry.platformMac
        store.clear(platform: platform)
        store.record(.overwriteLedger, attached: false, platform: platform)
        let gap = store.gaps.first { $0.capabilityID == "mac-overwrite-ledger-attached" }
        #expect(store.gaps.contains { $0.capabilityID == "mac-overwrite-ledger-attached" }, "闸门没装上必须报缺口，不得只留在注释里")
        #expect(gap?.probe == .overwriteLedger)
        store.record(.overwriteLedger, attached: true, platform: platform)
        #expect(
            !store.gaps.contains { $0.capabilityID == "mac-overwrite-ledger-attached" },
            "装上后缺口必须归零"
        )
        store.clear(platform: platform)
    }

    // MARK: - 形状：判定只有一处生产调用点

    @Test("形状：生产码里 SyncFileOverwriteJudge.judge 只有一处调用（接线闸门；禁止第二实现）")
    func judgeHasSingleProductionCallSite() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoot = repoRoot.appendingPathComponent("QQPlayer")
        var hits: [String] = []
        if let enumerator = FileManager.default.enumerator(at: productionRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("SyncFileOverwriteJudge.judge(") {
                    hits.append(url.lastPathComponent)
                }
            }
        }
        #expect(hits == ["SyncFileOverwriteGate.swift"], "判定入口只准出现在接线闸门，实际：[\(hits)]")
    }
}
