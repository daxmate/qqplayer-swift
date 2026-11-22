//
//  PlayerGlassSetting.swift
//  QQPlayer
//
//  「封面毛玻璃背景」开关的单一事实源（iOS + macOS 共用）。
//
//  设计要点：
//  - 键只有一份（`storageKey`），两端设置页 / 播放页都引用它，不各写字面量。
//  - 默认值只有一份：App 启动时 `registerDefaults` 注册「开」，
//    因此「没写过这个键」= 开；两端也不会各写一套 @AppStorage 默认值。
//  - 回落判定抽成纯函数 `isActive`，三个条件（开关关 / 无封面 / 降低透明度）各自可测。
//

import Foundation

enum PlayerGlassBackground {
    /// UserDefaults 键（两端共用，唯一）
    static let storageKey = "qqplayer.playerGlassBackground"

    /// 默认开
    static let enabledByDefault = true

    /// App 启动时调用一次：没写过该键的用户读到「开」
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [storageKey: enabledByDefault])
    }

    /// 当前是否开启（已注册默认值 ⇒ 未写过 = true）
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    /// 是否真的启用毛玻璃背景：**任一回落条件成立都不用**。
    /// - Parameters:
    ///   - isEnabled: 设置开关
    ///   - hasArtwork: 当前曲目是否有封面（无封面无法铺底）
    ///   - reduceTransparency: 系统「降低透明度」辅助功能开关
    static func isActive(isEnabled: Bool, hasArtwork: Bool, reduceTransparency: Bool) -> Bool {
        guard isEnabled, hasArtwork, !reduceTransparency else { return false }
        return true
    }
}
