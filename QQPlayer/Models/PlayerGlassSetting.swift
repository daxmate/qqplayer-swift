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
//  2026-11-22（iOS 整屏毛玻璃）：这个开关的语义升格为**二选一显示风格**
//  （毛玻璃 / 经典 = 继承上游的强调色形状背景）。
//  风格判定收口到 `AppAppearanceStyle`，`PlayerGlassBackground` 保留为薄封装
//  （既有调用点与契约测试不用改名）；持久化仍只有这一个 key，true = 毛玻璃。
//  视图不要自己 `bool(forKey:)` 判定风格 —— 用注入的环境值 `appAppearanceStyle`。
//

import Foundation
import SwiftUI

// MARK: - 显示风格（唯一判定入口）

/// App 显示风格：毛玻璃（整屏封面玻璃底）/ 经典（继承上游的强调色形状底）。
///
/// **唯一持久化**仍是 `PlayerGlassBackground.storageKey`（`true` = glass），
/// 默认 = glass（与既有默认值一致，老用户不会被翻外观）。
enum AppAppearanceStyle: String, CaseIterable, Identifiable {
    case glass
    case classic

    var id: String { rawValue }

    /// 默认风格（= key 的历史默认 true）
    static let standard: AppAppearanceStyle = .glass

    init(glassEnabled: Bool) {
        self = glassEnabled ? .glass : .classic
    }

    /// 持久化口径（true = glass）
    var glassEnabled: Bool { self == .glass }

    /// 唯一读入口：未写过该键 → 默认风格（fail-closed，不因漏注册而翻成经典）
    static func current(_ defaults: UserDefaults = .standard) -> AppAppearanceStyle {
        guard let stored = defaults.object(forKey: PlayerGlassBackground.storageKey) as? Bool else {
            return .standard
        }
        return AppAppearanceStyle(glassEnabled: stored)
    }

    /// 唯一写入口（设置页用；写的就是既有 key）
    static func store(_ style: AppAppearanceStyle, in defaults: UserDefaults = .standard) {
        defaults.set(style.glassEnabled, forKey: PlayerGlassBackground.storageKey)
    }

    /// 生效口径：系统「降低透明度」= 不用玻璃（回落经典；装饰底照旧）。
    static func resolved(stored: AppAppearanceStyle, reduceTransparency: Bool) -> AppAppearanceStyle {
        reduceTransparency ? .classic : stored
    }
}

private struct AppAppearanceStyleKey: EnvironmentKey {
    static let defaultValue: AppAppearanceStyle = .standard
}

extension EnvironmentValues {
    /// 当前生效的显示风格（iOS：`ContentView` 唯一注入；macOS 不使用本环境值）
    var appAppearanceStyle: AppAppearanceStyle {
        get { self[AppAppearanceStyleKey.self] }
        set { self[AppAppearanceStyleKey.self] = newValue }
    }
}

// MARK: - 开关（薄封装）

enum PlayerGlassBackground {
    /// UserDefaults 键（两端共用，唯一）
    static let storageKey = "qqplayer.playerGlassBackground"

    /// 默认开
    static let enabledByDefault = true

    /// App 启动时调用一次：没写过该键的用户读到「开」
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [storageKey: enabledByDefault])
    }

    /// 当前是否开启（已注册默认值 ⇒ 未写过 = true）。
    /// **薄封装**：风格判定唯一实现在 `AppAppearanceStyle`，这里只是历史调用点的兼容入口。
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        AppAppearanceStyle.current(defaults) == .glass
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
