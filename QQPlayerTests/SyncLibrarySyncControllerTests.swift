//
//  SyncLibrarySyncControllerTests.swift
//  QQPlayerTests
//
//  S2 M3-3b Client 侧控制器纯逻辑：
//  - 状态机流转合法性（idle→requestingManifest→fetching→done / failed；
//    无可拉取条目时 requestingManifest→done 直落）
//  - 对账 → 请求列表映射（missing / 内容不同 → 拉取；一致 → unchanged）
//  - 不传播删除：远端已消失的本地条目不进任何待处理列表、不被删除
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

    private func configuration(collection: SyncCollection = .all) -> SyncLibrarySyncConfiguration {
        var config = SyncLibrarySyncConfiguration()
        config.collection = collection
        return config
    }

    // MARK: - 状态机

    @Test("状态机：正常序列放行，越级/终态后迁移拒绝")
    func stateMachineTransitions() {
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .requestingManifest))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .requestingManifest, to: .fetching))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .requestingManifest, to: .done(SyncLibrarySyncSummary())))
        #expect(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .done(SyncLibrarySyncSummary())))

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
        #expect(plan.fetchRequest?.collection == .all) // 集合透传到拉取请求
        #expect(plan.unchanged.map(\.relativePath) == ["same.flac"])
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
        #expect(plan.unchanged.map(\.relativePath) == ["a.flac"])
    }

    @Test("★不传播删除：远端已消失的本地条目不进任何待处理列表、不被删除")
    func planIgnoresRemoteRemovedLocally() {
        let local = [
            entry("gone.flac", hash: "h1", stableId: "s1"),
            entry("kept.flac", hash: "h2"),
            entry("Imported/manual.m4a", hash: "h3"),
        ]
        let remote = [entry("kept.flac", hash: "h2")]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: remote),
            local: local,
            configuration: configuration()
        )
        // 没有待拉取动作（对端少的条目不是同步的事），本端文件一律保留
        #expect(plan.fetchRequest == nil)
        #expect(plan.unchanged.map(\.relativePath) == ["kept.flac"])
    }

    @Test("不传播删除：集合选择不影响本端存留（远端空 → 无动作）")
    func planIgnoresCollectionScopeForDeletion() {
        let local = [
            entry("selected.flac", hash: "h1", stableId: "s1"),
            entry("other.flac", hash: "h2", stableId: "s2"),
        ]
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: []),
            local: local,
            configuration: configuration(collection: .tracks(["s1"]))
        )
        #expect(plan.fetchRequest == nil)
        #expect(plan.unchanged.isEmpty)
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
