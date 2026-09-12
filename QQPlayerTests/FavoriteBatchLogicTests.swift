//
//  FavoriteBatchLogicTests.swift
//  QQPlayerTests
//
//  审计 B5 · 🔴-1 回归：批量「加入喜欢」必须是幂等语义（全部设为已喜欢），
//  不是逐曲 toggle（取反）——修复前混合选择会把已喜欢的曲目取消喜欢。
//
//  本用例修复前必红的原因：这一决策此前只存在于视图层（TrackListView /
//  TrackBulkSelection 各自 for 循环调用 AppCoordinator.toggleFavorite），
//  没有任何可测的"文案 → 目标状态"逻辑；FavoriteBatchLogic 不存在，
//  用例无法编译。第一次通过即锁定「已处于目标状态的曲目必须被跳过」。
//

import Foundation
import Testing

@testable import QQPlayer

struct FavoriteBatchLogicTests {
    // MARK: - 文案 → 目标状态

    @Test("「加入喜欢」（非 liked 列表）目标状态是 true")
    func desiredStateForAddToLiked() {
        #expect(FavoriteBatchLogic.desiredState(isLikedContext: false) == true)
    }

    @Test("「移出喜欢」（liked 列表）目标状态是 false")
    func desiredStateForRemoveFromLiked() {
        #expect(FavoriteBatchLogic.desiredState(isLikedContext: true) == false)
    }

    // MARK: - 幂等规划

    @Test("加入喜欢：混合选择时，已喜欢的曲目不得进入变更集合（修复前会被取反取消）")
    func mixedSelectionKeepsAlreadyLiked() throws {
        let liked = ["a", "c"]
        let toChange = try FavoriteBatchLogic.stableIdsNeedingChange(
            ["a", "b", "c"],
            desired: true,
            isFavorite: { liked.contains($0) }
        )
        #expect(toChange == ["b"])
    }

    @Test("加入喜欢：全部已喜欢 → 无需写库（幂等，无副作用）")
    func allAlreadyLikedIsNoOp() throws {
        let toChange = try FavoriteBatchLogic.stableIdsNeedingChange(
            ["a", "b"],
            desired: true,
            isFavorite: { _ in true }
        )
        #expect(toChange.isEmpty)
    }

    @Test("移出喜欢：只变更当前已喜欢的曲目")
    func unlikedRemovalTargetsOnlyLiked() throws {
        let liked = ["b"]
        let toChange = try FavoriteBatchLogic.stableIdsNeedingChange(
            ["a", "b", "c"],
            desired: false,
            isFavorite: { liked.contains($0) }
        )
        #expect(toChange == ["b"])
    }

    @Test("空选择 → 空变更集合")
    func emptySelection() throws {
        let toChange = try FavoriteBatchLogic.stableIdsNeedingChange(
            [],
            desired: true,
            isFavorite: { _ in false }
        )
        #expect(toChange.isEmpty)
    }

    @Test("重复 id 去重，且保持传入顺序")
    func deduplicatesAndKeepsOrder() throws {
        let toChange = try FavoriteBatchLogic.stableIdsNeedingChange(
            ["b", "a", "b", "a", "c"],
            desired: true,
            isFavorite: { _ in false }
        )
        #expect(toChange == ["b", "a", "c"])
    }

    @Test("查询抛错时向上传播（不静默吞掉 DB 错误）")
    func propagatesLookupError() {
        struct LookupError: Error {}
        #expect(throws: LookupError.self) {
            try FavoriteBatchLogic.stableIdsNeedingChange(
                ["a"],
                desired: true,
                isFavorite: { _ in throw LookupError() }
            )
        }
    }

    @Test("查询次数 = 去重后的选择数（每个 id 只查一次）")
    func queriesEachIdOnce() throws {
        var callCount = 0
        _ = try FavoriteBatchLogic.stableIdsNeedingChange(
            ["a", "a", "b", "c", "c", "c"],
            desired: true,
            isFavorite: { _ in
                callCount += 1
                return false
            }
        )
        #expect(callCount == 3)
    }
}
