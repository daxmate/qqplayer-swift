//
//  SyncCollectionCoordinatorTests.swift
//  QQPlayerTests
//
//  M6（2026-09-12）同步编排状态机回归（CI 版；与本地免模拟器 harness ㊵/㊶/㊷ 同语义）：
//    ① 计划态上报：`start(direction: .upload)` 后等对端 manifest 期间 → `.planning`
//       （非终态、账目已记方向与「已请求」），且此时 `cancel()` → `.failed("cancelled")`
//    ② 等清单超时：注入极小 `peerManifestTimeout` + 对端**不应答** → 有界落到
//       `.failed`（原因含「超时」），不无限干等
//    ③ 到点检查不得覆盖已应答编排：极小超时 + 对端**正常应答** → `.done`，**越过
//       超时点之后**仍为 `.done` 且推送账目完整
//
//  为什么在 QQPlayerTests 再落一份：`scripts/sync-harness` 只能在本地免模拟器跑
//  （CI 不跑），这三条是「点开始后灰键 / 无限等 / 超时误杀进行中编排」的用户可见
//  回归，必须由 CI 的 `-only-testing:QQPlayerTests` 兜住。harness 里的原用例保留
//  （本地快速回归），两份断言语义一致、各自独立。
//
//  夹具：复用 `SyncPeerSessionTestSupport.swift`（`SessionFixture.pairedHandshake()`
//  双 ready 内存回环）+ 本文件最小的内存曲库事实（歌单 → 曲目事实），不入库、不启
//  模拟器、不碰 DB 单例；设备侧用真 `SyncLibraryPassiveHost`（内存 GRDB），与生产
//  应答路径同构。
//
//  ⚠️ 本文件**不断言墙钟耗时**（CI 并行饥饿下会假红）：等待一律「轮询到条件成立 +
//  宽松上限（≤10s）」，断言的是**契约**（状态 / 失败原因内容 / 账目），不是「多久
//  内完成」。超时值注入得极小（相对默认 20s）只为让用例有界、跑得快。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 内存曲库事实（注入桩）

/// 歌单标识 → 曲目事实的最小内存实现（本文件只用 `.playlists` 展开，
/// 显式路径/歌词命名空间不涉及，故返回 nil/false）。
private struct MemoryPlaylistFacts: SyncCollectionFactsProviding {
    var playlists: [String: [SyncCollectionTrackFact]]

    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? {
        playlists[playlistID]
    }

    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? { nil }

    func hasLyrics(atWirePath wirePath: String) -> Bool { false }
}

// MARK: - 落库出口桩

/// 只做协议实现（本文件断言编排状态/账目，不关心入库链路）。
private final class CoordinatorSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var indexed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func indexLandedFile(at url: URL) {
        lock.lock()
        paths.append(url.path)
        lock.unlock()
    }
}

// MARK: - 测试

@MainActor
struct SyncCollectionCoordinatorTests {
    /// 注入的「小」超时（默认值 20s；用例只需**有界**，不是性能断言）。
    /// 取值 2s：要显著大于 CI 偶发线程饥饿量级（本仓库有秒级饥饿先例，0.5s 级
    /// 注入会把「请求刚发出仍在计划态」这条即时读取变成耗时断言 → 假红）。
    private static let tinyTimeout: TimeInterval = 2.0
    /// 轮询上限（宽松；不是耗时断言）。
    private static let waitLimit: TimeInterval = 10

    // MARK: 夹具

    private struct Scenario {
        let fixture: SessionFixture
        let macRoot: URL
        let deviceRoot: URL
        /// 必须强持有：被动端以 [weak self] 挂接会话，创建后即弃会被 ARC 释放
        let deviceHost: SyncLibraryPassiveHost
        let coordinator: SyncCollectionSyncCoordinator
    }

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-coord-ci-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func silentData(_ marker: UInt8, count: Int) -> Data {
        Data(repeating: marker, count: count)
    }

    /// 一条编排的最小夹具：
    /// - Mac 侧曲库根写入 1 个文件，歌单 `p1` 指向它（事实/清单/字节三方自洽）
    /// - 设备侧真被动端（`SyncLibraryPassiveHost` + 内存 GRDB）
    /// - `attachDeviceHost` = 对端是否接线（false = **不应答** manifest）
    private func makeScenario(
        relativePath: String,
        data: Data,
        stableId: String,
        attachDeviceHost: Bool,
        configuration: SyncCollectionSyncConfiguration = SyncCollectionSyncConfiguration(),
        /// 在 `start(direction:)` **之前**配置编排器（S2 竞态用例：注入阻塞回调，
        /// 复现「清单已到、差集还没算完」这段窗口）。
        configureCoordinator: ((SyncCollectionSyncCoordinator) -> Void)? = nil
    ) throws -> Scenario {
        let fixture = SessionFixture.pairedHandshake()

        let macRoot = try makeTempRoot("mac")
        let macFileURL = macRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: macFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: macFileURL)
        // 手推自洽：曲目事实的 content_hash = 文件**真实字节**的 SHA-256（推送侧用它
        // 作 fileID、接收侧据此校验；编造的哈希会让传输被拒 → 用例假红）。
        let contentHash = SyncFileChecksum.sha256Hex(of: data)

        let deviceRoot = try makeTempRoot("device")
        let deviceManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try deviceManager.createTables()
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: CoordinatorSinkSpy(),
            database: deviceManager,
            lyricsStore: AlignedLyricsStore(directory: try makeTempRoot("device-lyrics")),
            lyricsMapping: .unresolved
        )
        if attachDeviceHost {
            #expect(deviceHost.attach(to: fixture.clientSession))
        }

        // Mac 侧描述符：清单只含这一条（size/hash/stableId 与磁盘字节一致）。
        let macLyricsStore = AlignedLyricsStore(directory: try makeTempRoot("mac-lyrics"))
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: macRoot,
            rootName: "CI 测试 Mac 曲库",
            sourceFiles: {
                [
                    SyncManifestSourceFile(
                        relativePath: relativePath,
                        size: Int64(data.count),
                        contentHash: contentHash,
                        stableId: stableId
                    ),
                ]
            },
            contentHash: { _ in contentHash },
            lyricsFileName: { _ in nil }
        )

        let sink = CoordinatorSinkSpy()
        let coordinator = SyncCollectionSyncCoordinator(
            session: fixture.hostSession,
            descriptor: descriptor,
            selection: .playlists(["p1"]),
            facts: MemoryPlaylistFacts(
                playlists: [
                    "p1": [
                        SyncCollectionTrackFact(
                            stableId: stableId,
                            relativePath: relativePath,
                            contentHash: contentHash
                        ),
                    ],
                ]
            ),
            configuration: configuration,
            sink: sink,
            lyricsStore: macLyricsStore,
            lyricsMapping: .unresolved
        )
        configureCoordinator?(coordinator)
        try coordinator.start(direction: .upload)

        return Scenario(
            fixture: fixture,
            macRoot: macRoot,
            deviceRoot: deviceRoot,
            deviceHost: deviceHost,
            coordinator: coordinator
        )
    }

    // MARK: 等待 / 状态助手

    /// 有界轮询到条件成立（宽松上限 10s，须大于 `tinyTimeout`）。**不是耗时断言**：
    /// 条件本身才是契约。
    @discardableResult
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Self.waitLimit)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// `.failed(reason)` 的原因（非失败态 = nil）。
    private func failureReason(_ state: SyncCollectionSyncState) -> String? {
        if case let .failed(reason) = state { return reason }
        return nil
    }

    // MARK: ① 计划态上报（回归：面板灰键无解释 + 无退出路径）

    @Test("计划态上报：start 后等对端 manifest 期间 → .planning（非终态 + 可取消）")
    func reportsPlanningWhileWaitingForPeerManifest() throws {
        // 对端**不接线**（不应答 manifest）→ 编排停在「已请求、等应答」的计划态，
        // 这正是用户点「上传到 iPhone」后的时序（M6 缺陷：此时内部只置 stage，从不上报）。
        let scenario = try makeScenario(
            relativePath: "Album/plan.flac",
            data: silentData(0xC6, count: 8_000),
            stableId: "s-plan",
            attachDeviceHost: false
        )
        let coordinator = scenario.coordinator

        #expect(coordinator.state == .planning)
        // 计划态非终态（UI 据此渲染取消键，不再把开始键禁用）
        #expect(!SyncCollectionSyncState.isTerminal(coordinator.state))
        #expect(coordinator.report.didRequestPeerManifest)
        #expect(coordinator.report.direction == .upload)

        // 计划态必须可取消（缺陷现象之一：灰键不可点 → 没有退出路径）
        coordinator.cancel()
        #expect(coordinator.state == .failed("cancelled"))
    }

    // MARK: ② 等清单超时（回归：对端不应答 → 不无限干等）

    @Test("等清单超时：对端不应答 → 有界落到 .failed（原因含「超时」）")
    func failsBoundedlyWhenPeerManifestTimesOut() throws {
        var configuration = SyncCollectionSyncConfiguration()
        configuration.peerManifestTimeout = Self.tinyTimeout
        // 极小超时 + 对端不应答 = 用户实测的「点开始后一直等」。
        let scenario = try makeScenario(
            relativePath: "Album/timeout.flac",
            data: silentData(0xC7, count: 8_000),
            stableId: "s-timeout",
            attachDeviceHost: false,
            configuration: configuration
        )
        let coordinator = scenario.coordinator

        // 请求刚发出、超时未到 → 仍在计划态（未提前判超时）
        #expect(coordinator.state == .planning)
        #expect(coordinator.report.didRequestPeerManifest)

        // 有界等待到终态（上限宽松；条件是「落终态」而非「多久内落」）
        #expect(waitUntil { SyncCollectionSyncState.isTerminal(coordinator.state) })
        let reason = failureReason(coordinator.state)
        #expect(reason?.contains("超时") == true, "失败原因含「超时」：\(reason ?? "nil")")
    }

    // MARK: ③ 到点检查不得覆盖已应答编排

    @Test("到点检查不覆盖已应答编排：极小超时 + 正常应答 → 越过超时点仍 .done、账目完整")
    func timeoutCheckDoesNotOverwriteAnsweredRun() throws {
        var configuration = SyncCollectionSyncConfiguration()
        configuration.peerManifestTimeout = Self.tinyTimeout
        // 极小超时 + 对端**正常应答**（设备被动端已接线）。到点时只能看到「已应答 /
        // 已收尾」，绝不允许把编排打成失败。
        let relativePath = "Album/race.flac"
        let scenario = try makeScenario(
            relativePath: relativePath,
            data: silentData(0xC8, count: 8_000),
            stableId: "s-race",
            attachDeviceHost: true,
            configuration: configuration
        )
        let coordinator = scenario.coordinator

        #expect(waitUntil { coordinator.state == .done })
        #expect(coordinator.state == .done)
        #expect(failureReason(coordinator.state) == nil)
        // 账目完整：对端缺这条 → 推送且成功
        #expect(coordinator.report.pushed == [relativePath])

        // 越过超时点之后复核：到点检查必须被「仍在计划态」守卫挡住。
        // 只需跨过超时点即可（不再乘倍数，省 CI 时间）；这仍是「越过之后」的复核，
        // 不是耗时断言 —— 断言的是越过之后的状态契约。
        Thread.sleep(forTimeInterval: Self.tinyTimeout + 1.0)
        #expect(coordinator.state == .done)
        #expect(failureReason(coordinator.state) == nil)
        #expect(coordinator.report.pushed == [relativePath])
    }

    // MARK: ④ S2：清单已到 vs 计划态超时（回归：清单到了仍被判超时 + 一条文件都不传）

    @Test("S2 竞态：清单已到（计划途中越过超时点）→ 不得判超时、文件必须照传")
    func peerManifestArrivalBeatsTimeoutCheck() throws {
        var configuration = SyncCollectionSyncConfiguration()
        configuration.peerManifestTimeout = Self.tinyTimeout
        // 在「清单已到、差集还没算完」这段窗口里阻塞（越过超时点）：到点检查恰好落在
        // handlePeerManifest 解锁后、beginTransfers 之前——修复前会判超时并置终态，
        // 随后的 beginPush 被守挡住 = 一条文件都不传。
        // 断言的是契约（状态 / 账目），不是耗时；阻塞上限只用来复现窗口。
        let blockUntil = Date().addingTimeInterval(Self.tinyTimeout + 2.0)
        let relativePath = "Album/race-manifest.flac"
        let scenario = try makeScenario(
            relativePath: relativePath,
            data: silentData(0xC9, count: 8_000),
            stableId: "s-rm",
            attachDeviceHost: true,
            configuration: configuration,
            configureCoordinator: { coordinator in
                coordinator.onPeerManifestReceived = { _ in
                    while Date() < blockUntil { Thread.sleep(forTimeInterval: 0.02) }
                }
            }
        )
        let coordinator = scenario.coordinator

        #expect(failureReason(coordinator.state) == nil, "清单已到 → 不得落「超时」失败")
        #expect(coordinator.state == .done)
        #expect(coordinator.report.pushed == [relativePath], "文件必须真的传出（一条都不传 = 缺陷现象）")
    }

    // MARK: ⑤ S4：重入保护（进行中拒绝第二轮）

    @Test("S4：进行中重入被拒（alreadyRunning）且不覆盖进行中的编排")
    func rejectsReentrantStart() throws {
        var configuration = SyncCollectionSyncConfiguration()
        // 只验证重入守卫；超时给得足够大，不让它参与本用例。
        configuration.peerManifestTimeout = 30
        let scenario = try makeScenario(
            relativePath: "Album/reentry.flac",
            data: silentData(0xCA, count: 8_000),
            stableId: "s-re",
            attachDeviceHost: false, // 对端不应答 → 停在计划态（= 进行中）
            configuration: configuration
        )
        let coordinator = scenario.coordinator
        #expect(coordinator.state == .planning)
        #expect(coordinator.report.direction == .upload)

        var startError: SyncCollectionSyncCoordinator.StartError?
        do {
            try coordinator.start(direction: .download)
        } catch let error as SyncCollectionSyncCoordinator.StartError {
            startError = error
        } catch {
            startError = nil
        }
        #expect(startError == .alreadyRunning)
        #expect(coordinator.state == .planning, "重入被拒 → 进行中的状态不变")
        #expect(coordinator.report.direction == .upload, "重入被拒 → 方向不被第二轮覆盖")
    }
}
