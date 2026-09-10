//
//  SyncLibrarySyncControllerTests.swift
//  QQPlayerTests
//
//  S2 M3-3b Client 侧控制器纯逻辑：
//  - 状态机流转合法性（idle→requestingManifest→fetching→applyingDeletes→done/failed）
//  - 对账 → 请求列表映射（missing / 内容不同 → 拉取；一致 → unchanged）
//  - 删除范围：私有区绝不删、未受管集合（tracks/playlists）不删
//  - 执行期复核 mayDelete 与计划一致
//  - 文件名回收映射（同名多路径按请求序）
//  - 未 ready 会话 start() 必须抛错
//  端到端（真跑传输）见 SyncLibrarySyncE2ETests.swift。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncLibrarySyncControllerTests {
    // MARK: 工具

    private func entry(_ path: String, hash: String?, stableId: String? = nil) -> ManifestEntry {
        ManifestEntry(relativePath: path, size: 10, mtimeMs: 0, contentHash: hash, stableId: stableId)
    }

    private func configuration(
        collection: SyncCollection = .all,
        protected: Set<String> = []
    ) -> SyncLibrarySyncConfiguration {
        var config = SyncLibrarySyncConfiguration()
        config.collection = collection
        config.protectedRelativePaths = protected
        return config
    }

    // MARK: - 状态机

    @Test("状态机：正常序列放行，越级/终态后迁移拒绝")
    func stateMachineTransitions() {
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .requestingManifest))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .requestingManifest, to: .fetching))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .requestingManifest, to: .applyingDeletes))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .applyingDeletes))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .applyingDeletes, to: .done(SyncLibrarySyncSummary())))

        // 越级/重复
        #expect(!SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .fetching))
        #expect(!SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .done(SyncLibrarySyncSummary())))
        #expect(!SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .requestingManifest))

        // 任意非终态 → failed；终态后不可再迁移
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .failed("x")))
        #expect(!SyncLibrarySyncStateMachine.canTransition(from: .done(SyncLibrarySyncSummary()), to: .failed("x")))
        #expect(!SyncLibrarySyncStateMachine.canTransition(from: .failed("x"), to: .requestingManifest))

        #expect(SyncLibrarySyncStateMachine.isTerminal(.done(SyncLibrarySyncSummary())))
        #expect(SyncLibrarySyncStateMachine.isTerminal(.failed("x")))
        #expect(!SyncLibrarySyncStateMachine.isTerminal(.fetching))
    }

    // MARK: - 对账 → 计划

    @Test("对账映射：本地缺失 / 内容不同 → 拉取；一致 → unchanged")
    func planMapsFetchList() {
        let local = [entry("same.flac", hash: "h1"), entry("changed.flac", hash: "old")]
        let remote = [
            entry("changed.flac", hash: "new"),
            entry("missing.flac", hash: "h3"),
            entry("same.flac", hash: "h1"),
        ]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: remote),
            local: local,
            configuration: configuration()
        )
        #expect(plan.fetchRequest?.relativePaths == ["changed.flac", "missing.flac"])
        #expect(plan.unchanged.map(\.relativePath) == ["same.flac"])
        #expect(plan.deletes.isEmpty)
    }

    @Test("对账映射：无差异 → 不发拉取请求")
    func planSkipsFetchWhenIdentical() {
        let local = [entry("a.flac", hash: "h1")]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: [entry("a.flac", hash: "h1")]),
            local: local,
            configuration: configuration()
        )
        #expect(plan.fetchRequest == nil)
        #expect(plan.deletes.isEmpty)
    }

    @Test("对账映射：远端已消失 → 进删除列表（受管范围内）")
    func planCollectsDeletes() {
        let local = [entry("gone.flac", hash: "h1", stableId: "s1"), entry("kept.flac", hash: "h2")]
        let remote = [entry("kept.flac", hash: "h2")]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: remote),
            local: local,
            configuration: configuration()
        )
        #expect(plan.deletes.map(\.relativePath) == ["gone.flac"])
        #expect(plan.deletes.first?.stableId == "s1")
    }

    // MARK: - 私有区 / 未受管保护

    @Test("私有区条目绝不进删除列表（远端全消失也不删）")
    func privateZoneIsProtected() {
        let local = [
            entry("Album/synced.flac", hash: "h1"),
            entry("Imported/private.flac", hash: "h2"),
        ]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: []),
            local: local,
            configuration: configuration(protected: ["Imported/private.flac"])
        )
        #expect(plan.deletes.map(\.relativePath) == ["Album/synced.flac"])
        #expect(plan.protectedSkipped.map(\.relativePath) == ["Imported/private.flac"])
    }

    @Test("未受管集合（tracks 选择）内的本地条目不被删")
    func unmanagedCollectionIsNotDeleted() {
        let local = [
            entry("selected.flac", hash: "h1", stableId: "s1"),
            entry("other.flac", hash: "h2", stableId: "s2"),
        ]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: []),
            local: local,
            configuration: configuration(collection: .tracks(["s1"]))
        )
        #expect(plan.deletes.map(\.relativePath) == ["selected.flac"])
        // 未入选不受管 = 静默忽略（既不删也不报）
        #expect(plan.protectedSkipped.isEmpty)
    }

    @Test("执行期复核 mayDelete：私有区/未受管一律 false")
    func executionRecheckMatchesPlan() {
        let local = [
            entry("Album/synced.flac", hash: "h1", stableId: "s1"),
            entry("Imported/private.flac", hash: "h2", stableId: "s2"),
        ]
        let config = configuration(protected: ["Imported/private.flac"])
        #expect(SyncLibrarySyncPlanner.mayDelete(local[0], configuration: config, local: local))
        #expect(!SyncLibrarySyncPlanner.mayDelete(local[1], configuration: config, local: local))
    }

    // MARK: - 文件名回收

    @Test("文件名 → 期望路径映射：同名多路径按请求序")
    func expectedPathsByName() {
        let map = SyncLibrarySyncController.expectedPathsByName([
            "Album A/01.flac",
            "Album B/01.flac",
            "track.flac",
        ])
        #expect(map["01.flac"] == ["Album A/01.flac", "Album B/01.flac"])
        #expect(map["track.flac"] == ["track.flac"])
    }

    // MARK: - 前置条件

    @Test("会话未 ready → start() 抛 sessionNotReady")
    func startRequiresReadySession() throws {
        let fixture = SessionFixture.make()
        let controller = SyncLibrarySyncController(
            session: fixture.clientSession,
            libraryRoot: FileManager.default.temporaryDirectory
        )
        #expect(controller.state == .idle)
        #expect(throws: SyncLibrarySyncController.StartError.sessionNotReady) {
            try controller.start()
        }
    }
}
