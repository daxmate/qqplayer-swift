//  FavoriteBatchLogic.swift
//  QQPlayer
//
//  批量「加入喜欢 / 移出喜欢」的决策纯逻辑（审计 B5 · 🔴-1）。
//
//  背景：菜单文案是「加入喜欢」，而视图层曾逐曲调用 AppCoordinator.toggleFavorite（取反）。
//  混合选择（有已喜欢的曲目）时，已喜欢的那几首会被**取消喜欢** —— 与文案承诺相反，
//  且用户无提示。收敛为：文案决定目标状态（幂等），只对"需要变更"的曲目写库。
//
//  纯逻辑（闭包注入查询），不依赖 DB / 视图，可直接单测。

import Foundation

enum FavoriteBatchLogic {
    /// 菜单文案 → 目标收藏状态。
    /// - Parameter isLikedContext: true = 当前列表是「喜欢的歌曲」（文案为"移出喜欢"）。
    /// - Returns: 「加入喜欢」= 全部设为已喜欢（幂等，不是取反）；「移出喜欢」= 全部取消。
    static func desiredState(isLikedContext: Bool) -> Bool {
        !isLikedContext
    }

    /// 幂等规划：返回**需要写库**的 stableId（已处于目标状态的跳过），保持传入顺序并去重。
    /// - Parameters:
    ///   - stableIds: 选中曲目（可能含重复，来自 UI 集合/数组）
    ///   - desired: 目标状态（true = 已喜欢）
    ///   - isFavorite: 当前状态查询（注入 DB 查询，便于单测）
    static func stableIdsNeedingChange(
        _ stableIds: [String],
        desired: Bool,
        isFavorite: (String) throws -> Bool
    ) rethrows -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for stableId in stableIds where seen.insert(stableId).inserted {
            if try isFavorite(stableId) != desired {
                result.append(stableId)
            }
        }
        return result
    }
}
