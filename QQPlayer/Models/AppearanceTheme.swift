//
//  AppearanceTheme.swift
//  QQPlayer
//
//  外观三态主题（跟随系统/深色/浅色）：纯逻辑枚举，跨 iOS/macOS 共享。
//  macOS 设置页写入 DeleteSettings.appearanceTheme（String），应用逻辑在
//  Mac/MacAppearance.swift（NSApp.appearance）。iOS 侧仍用 forceDarkMode。
//

import Foundation

/// 外观主题三态（对齐 web 版 theme: dark/light/auto 语义）。
enum AppearanceTheme: String, CaseIterable {
    case system
    case dark
    case light

    /// 旧数据兼容：appearanceTheme 从未写入（nil 或非法值）时，用
    /// forceDarkMode 推导（老用户强制深色=true → 深色，否则跟随系统）。
    static func resolved(raw: String?, forceDarkMode: Bool) -> AppearanceTheme {
        guard let raw, let theme = AppearanceTheme(rawValue: raw) else {
            return forceDarkMode ? .dark : .system
        }
        return theme
    }
}
