//
//  SandboxMigrationPlannerTests.swift
//  QQPlayerTests
//
//  M3-2：iCloud → 沙盒迁移决策纯逻辑测试（SandboxMigrationPlanner）。
//  - 判同 = 同 content_hash（§8.5 防双位置重复）
//  - copyToSandbox / alreadyInSandbox / nameConflict 三分支
//  - DB 路径切换候选（content_hash 命中沙盒目标才产出）
//  - 幂等断点：沙盒目标已存在同内容 ⇒ 重跑 filesToCopy 为空 / 计划收敛
//
//  执行器（SandboxMusicMigrator）是 iOS-only 真机逻辑，无单测；验收留 M6 用户真机。
//

import Foundation
import Testing

@testable import QQPlayer

struct SandboxMigrationPlannerTests {
    // MARK: - 辅助

    private func cloud(_ path: String, _ hash: String?) -> SandboxMigrationPlanner.CloudFile {
        SandboxMigrationPlanner.CloudFile(relativePath: path, contentHash: hash)
    }

    private func sandbox(_ path: String, _ hash: String?) -> SandboxMigrationPlanner.SandboxFile {
        SandboxMigrationPlanner.SandboxFile(relativePath: path, contentHash: hash)
    }

    private func track(_ stableId: String, _ cloudPath: String, _ hash: String?) -> SandboxMigrationPlanner.CloudTrack {
        SandboxMigrationPlanner.CloudTrack(stableId: stableId, cloudPath: cloudPath, contentHash: hash)
    }

    // MARK: - copyToSandbox

    @Test("空沙盒 → 全部 copyToSandbox，目标相对路径与源同名")
    func emptySandboxCopiesAll() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [
                cloud("a.flac", "h1"),
                cloud("sub/b.mp3", "h2"),
            ],
            sandboxFiles: [],
            cloudTracks: []
        )
        #expect(plan.filesToCopy.count == 2)
        #expect(plan.filesToCopy[0].action == .copyToSandbox)
        #expect(plan.filesToCopy[0].destinationRelativePath == "a.flac")
        #expect(plan.filesToCopy[1].destinationRelativePath == "sub/b.mp3")
        #expect(plan.pathSwitches.isEmpty)
    }

    // MARK: - alreadyInSandbox（判同 = content_hash）

    @Test("沙盒存在同 content_hash（不同路径）→ alreadyInSandbox，不复制")
    func sameHashDifferentPathIsDeduplicated() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("old/曲.flac", "hA")],
            sandboxFiles: [sandbox("Music/曲.flac", "hA")],
            cloudTracks: []
        )
        #expect(plan.filesToCopy.isEmpty)
        #expect(plan.items.first?.action == .alreadyInSandbox)
    }

    @Test("沙盒存在同路径且同 hash → alreadyInSandbox（幂等：重跑不重复复制）")
    func idempotentWhenAlreadyCopied() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", "h1")],
            sandboxFiles: [sandbox("a.flac", "h1")],
            cloudTracks: []
        )
        #expect(plan.filesToCopy.isEmpty)
        #expect(plan.items.first?.action == .alreadyInSandbox)
        // 断点语义：第二次 makePlan（沙盒已是复制后状态）不再要求复制
        let rerun = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", "h1")],
            sandboxFiles: [sandbox("a.flac", "h1")],
            cloudTracks: []
        )
        #expect(rerun.filesToCopy.isEmpty)
    }

    // MARK: - nameConflict

    @Test("沙盒同名但内容不同 → nameConflict，不覆盖沙盒文件")
    func sameNameDifferentContentConflicts() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", "hCloud")],
            sandboxFiles: [sandbox("a.flac", "hLocal")],
            cloudTracks: []
        )
        #expect(plan.items.first?.action == .nameConflict)
        #expect(plan.filesToCopy.isEmpty)
        #expect(plan.items.first?.destinationRelativePath == nil)
    }

    // MARK: - hash 未知的保守路径比对

    @Test("cloud hash 未知：同相对路径已存在 → 视为已有（保守不覆盖）")
    func unknownCloudHashFallsBackToPathMatch() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", nil)],
            sandboxFiles: [sandbox("a.flac", "anything")],
            cloudTracks: []
        )
        #expect(plan.items.first?.action == .alreadyInSandbox)
    }

    @Test("cloud hash 未知且沙盒无同名 → copyToSandbox")
    func unknownCloudHashNoPathMatchCopies() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", nil)],
            sandboxFiles: [],
            cloudTracks: []
        )
        #expect(plan.items.first?.action == .copyToSandbox)
    }

    // MARK: - DB 路径切换（content_hash 映射旧引用）

    @Test("DB 云行 content_hash 命中沙盒目标 → 产出 pathSwitch")
    func cloudTrackHashMatchesSandboxProducesSwitch() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("iCloud/a.flac", "h1")],
            sandboxFiles: [sandbox("a.flac", "h1")],
            cloudTracks: [track("stable-1", "/cloud/container/Documents/a.flac", "h1")]
        )
        // 沙盒已有同内容 → 云文件不复制；DB 行直接切换
        #expect(plan.filesToCopy.isEmpty)
        #expect(plan.pathSwitches.count == 1)
        #expect(plan.pathSwitches[0].trackStableId == "stable-1")
        #expect(plan.pathSwitches[0].destinationRelativePath == "a.flac")
    }

    @Test("DB 云行 hash 为 nil → 不产出 switch（无法判同，保守不动）")
    func cloudTrackWithoutHashNoSwitch() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", "h1")],
            sandboxFiles: [],
            cloudTracks: [track("stable-1", "/cloud/a.flac", nil)]
        )
        #expect(plan.pathSwitches.isEmpty)
        // 文件仍需复制（供后续入库或人工处理）
        #expect(plan.filesToCopy.count == 1)
    }

    @Test("DB 云行 hash 无沙盒命中 → 不产出 switch")
    func cloudTrackHashWithoutSandboxMatchNoSwitch() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [cloud("a.flac", "h1")],
            sandboxFiles: [sandbox("b.flac", "hOther")],
            cloudTracks: [track("stable-1", "/cloud/a.flac", "h1")]
        )
        #expect(plan.pathSwitches.isEmpty)
        #expect(plan.filesToCopy.count == 1)
    }

    // MARK: - 混合场景 + 相对路径拼接

    @Test("混合：新文件复制 + 已有文件跳过 + 冲突保留，各归其位")
    func mixedPlanClassifiesEachFile() {
        let plan = SandboxMigrationPlanner.makePlan(
            cloudFiles: [
                cloud("new.flac", "hNew"),
                cloud("done.flac", "hDone"),
                cloud("clash.flac", "hCloud"),
            ],
            sandboxFiles: [
                sandbox("done.flac", "hDone"),
                sandbox("clash.flac", "hLocal"),
            ],
            cloudTracks: []
        )
        #expect(plan.filesToCopy.map(\.cloudFile.relativePath) == ["new.flac"])
        let actions = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cloudFile.relativePath, $0.action) })
        #expect(actions["done.flac"] == .alreadyInSandbox)
        #expect(actions["clash.flac"] == .nameConflict)
    }

    @Test("url(relativePath:under:) 拼接正确")
    func relativeURLJoin() {
        let root = URL(fileURLWithPath: "/sandbox/Documents", isDirectory: true)
        let url = SandboxMigrationPlanner.url(relativePath: "sub/曲.flac", under: root)
        #expect(url.path == "/sandbox/Documents/sub/曲.flac")
    }
}
