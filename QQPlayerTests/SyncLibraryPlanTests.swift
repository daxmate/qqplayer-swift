//
//  SyncLibraryPlanTests.swift
//  QQPlayerTests
//
//  2026-09-12 审计 I7：把「只在无模拟器 harness（scripts/sync-harness/main.swift）里、
//  CI 永远看不到」的关键正确性场景补进 CI 可见的单测 target。
//
//  本文件与 harness 的以下段落一一对应（同口径断言，harness 定位见文件内注释）：
//    - harness ③ 控制器状态机（`sync-harness/main.swift:307-340`）
//    - harness ③ 拉取方向对账（`:342-361`）
//    - harness ⑳ 推送方向对账 + 推送选择集（`:1231-1286`）
//
//  为什么这些场景值得进 CI：状态迁移表是「终态后不得再迁移 / 不得越级」的守卫，
//  两个对账器是「**只补齐、不删除**」这条跨端契约的唯一实现（删除不传播是本项目
//  最关键的同步安全性不变量），而 harness 不在 CI 里跑（`ci.yml` 只跑 xcodebuild test）。
//
//  纯逻辑：无 DB / 无文件系统 / 无会话夹具，故不需要 `.serialized`。
//

import Foundation
import Testing

@testable import QQPlayer

/// harness `entry(_:hash:stableId:)`（`sync-harness/main.swift:204-206`）同口径的最小条目夹具。
private func entry(_ path: String, hash: String?, stableId: String? = nil) -> ManifestEntry {
    ManifestEntry(relativePath: path, size: 10, mtimeMs: 0, contentHash: hash, stableId: stableId)
}

struct SyncLibraryPlanTests {
    // MARK: - 状态迁移表（harness ③）

    @Test("拉取状态迁移：合法路径放行；越级与终态后迁移一律拒绝")
    func pullStateMachineTransitions() {
        #expect(SyncLibraryPullStateMachine.canTransition(from: .idle, to: .requestingManifest))
        #expect(SyncLibraryPullStateMachine.canTransition(from: .requestingManifest, to: .fetching))
        // 无待拉取条目：对账后直接收尾
        #expect(
            SyncLibraryPullStateMachine.canTransition(
                from: .requestingManifest, to: .done(SyncLibraryPullSummary())
            )
        )
        #expect(
            SyncLibraryPullStateMachine.canTransition(
                from: .fetching, to: .done(SyncLibraryPullSummary())
            )
        )
        // 越级：登记了清单就直接跳到「拉取中」是非法迁移
        #expect(!SyncLibraryPullStateMachine.canTransition(from: .idle, to: .fetching))
        // 非终态 → failed 允许
        #expect(SyncLibraryPullStateMachine.canTransition(from: .fetching, to: .failed("x")))
        // 终态是吸收态：done 之后不得再迁移（含 failed）
        #expect(
            !SyncLibraryPullStateMachine.canTransition(
                from: .done(SyncLibraryPullSummary()), to: .failed("x")
            )
        )

        #expect(SyncLibraryPullStateMachine.isTerminal(.done(SyncLibraryPullSummary())))
        #expect(SyncLibraryPullStateMachine.isTerminal(.failed("x")))
        #expect(!SyncLibraryPullStateMachine.isTerminal(.idle))
        #expect(!SyncLibraryPullStateMachine.isTerminal(.requestingManifest))
        #expect(!SyncLibraryPullStateMachine.isTerminal(.fetching))
    }

    @Test("推送状态迁移：合法路径放行；越级与终态后迁移一律拒绝")
    func pushStateMachineTransitions() {
        #expect(SyncLibraryPushStateMachine.canTransition(from: .idle, to: .requestingManifest))
        // 全部已一致 / 无条目：对账后直接收尾
        #expect(
            SyncLibraryPushStateMachine.canTransition(
                from: .requestingManifest, to: .done(SyncLibraryPushSummary())
            )
        )
        #expect(SyncLibraryPushStateMachine.canTransition(from: .requestingManifest, to: .pushing))
        #expect(
            SyncLibraryPushStateMachine.canTransition(
                from: .pushing, to: .done(SyncLibraryPushSummary())
            )
        )
        #expect(!SyncLibraryPushStateMachine.canTransition(from: .idle, to: .pushing))
        #expect(SyncLibraryPushStateMachine.canTransition(from: .pushing, to: .failed("x")))
        #expect(
            !SyncLibraryPushStateMachine.canTransition(
                from: .done(SyncLibraryPushSummary()), to: .failed("x")
            )
        )

        #expect(SyncLibraryPushStateMachine.isTerminal(.done(SyncLibraryPushSummary())))
        #expect(SyncLibraryPushStateMachine.isTerminal(.failed("x")))
        #expect(!SyncLibraryPushStateMachine.isTerminal(.idle))
        #expect(!SyncLibraryPushStateMachine.isTerminal(.requestingManifest))
        #expect(!SyncLibraryPushStateMachine.isTerminal(.pushing))
    }

    // MARK: - 拉取方向对账（harness ③）

    @Test("拉取对账：本端缺 / 内容不同 → 拉取列表；一致 → unchanged")
    func pullPlannerReconciles() {
        let remote = SyncManifestResponse(entries: [
            entry("changed.flac", hash: "new"),
            entry("missing.flac", hash: "h3"),
            entry("same.flac", hash: "h1"),
        ])
        let local = [entry("same.flac", hash: "h1"), entry("changed.flac", hash: "old")]

        let plan = SyncLibraryPullPlanner.plan(remote: remote, local: local, selection: .all)
        #expect(plan.relativePaths == ["changed.flac", "missing.flac"])
        #expect(plan.unchanged.map(\.relativePath) == ["same.flac"])
    }

    @Test("★拉取对账：远端已删 → 本端一条都不动（不传播删除）")
    func pullPlannerNeverDeletesFromRemoteAbsence() {
        // 对端清单为空（对端已把文件删了）→ 计划里既没有拉取也没有删除通道
        let plan = SyncLibraryPullPlanner.plan(
            remote: SyncManifestResponse(entries: []),
            local: [entry("Album/synced.flac", hash: "h1"), entry("Imported/private.flac", hash: "h2")],
            selection: .all
        )
        #expect(plan.relativePaths.isEmpty)
        #expect(plan.unchanged.isEmpty)
    }

    @Test("拉取对账：显式选择集只拉入选路径（不产生删除）")
    func pullPlannerScopesToSelection() {
        let remote = SyncManifestResponse(entries: [
            entry("selected.flac", hash: "h1", stableId: "s1"),
            entry("other.flac", hash: "h2", stableId: "s2"),
        ])
        let plan = SyncLibraryPullPlanner.plan(
            remote: remote,
            local: [],
            selection: .relativePaths(["other.flac"])
        )
        #expect(plan.relativePaths == ["other.flac"])
    }

    // MARK: - 推送方向对账（harness ⑳）

    @Test("推送对账：对端缺或内容不同 → 推；同路径同指纹 → 跳过；对端独有 → 什么都不做")
    func pushPlannerReconciles() {
        let localEntries = [
            entry("Album/changed.flac", hash: "new"),
            entry("Album/missing.flac", hash: "h3"),
            entry("Album/same.flac", hash: "h1"),
            entry("@lyrics/h1.json", hash: "lh1"),
        ]
        let remoteEntries = [
            entry("Album/changed.flac", hash: "old"),
            entry("Album/same.flac", hash: "h1"),
            entry("Album/device-only.flac", hash: "h9"),
        ]

        let plan = SyncLibraryPushPlanner.plan(local: localEntries, remote: remoteEntries)
        #expect(
            plan.toPush.map(\.relativePath)
                == ["@lyrics/h1.json", "Album/changed.flac", "Album/missing.flac"]
        )
        #expect(plan.unchanged.map(\.relativePath) == ["Album/same.flac"])
        // 对端多出来的条目：既不推也不删（绝不跨端删除）
        #expect(!plan.toPush.contains { $0.relativePath == "Album/device-only.flac" })
        #expect(!plan.unchanged.contains { $0.relativePath == "Album/device-only.flac" })
    }

    @Test("推送对账：任一侧指纹缺失 → 保守判为需推送（绝不误判一致）")
    func pushPlannerConservativeOnMissingHash() {
        #expect(
            SyncLibraryPushPlanner.plan(
                local: [entry("Album/x.flac", hash: nil)],
                remote: [entry("Album/x.flac", hash: "h")]
            ).toPush.map(\.relativePath) == ["Album/x.flac"]
        )
        #expect(
            SyncLibraryPushPlanner.plan(
                local: [entry("Album/x.flac", hash: "h")],
                remote: [entry("Album/x.flac", hash: nil)]
            ).toPush.map(\.relativePath) == ["Album/x.flac"]
        )
    }

    @Test("推送选择集：规范化（拒非法 / 去重 / 升序）+ 过滤命中")
    func pushSelectionNormalizesAndFilters() {
        let localEntries = [
            entry("Album/changed.flac", hash: "new"),
            entry("Album/missing.flac", hash: "h3"),
            entry("Album/same.flac", hash: "h1"),
            entry("@lyrics/h1.json", hash: "lh1"),
        ]

        let selection = SyncLibraryPushSelection.relativePaths(
            ["B/2.flac", "A/1.flac", "../escape.flac", "A/1.flac"]
        )
        #expect(selection.normalizedPaths == ["A/1.flac", "B/2.flac"])
        #expect(
            SyncLibraryPushSelection.relativePaths(["Album/same.flac"]).filter(localEntries)
                .map(\.relativePath) == ["Album/same.flac"]
        )
        #expect(SyncLibraryPushSelection.all.filter(localEntries).count == localEntries.count)
    }
}
