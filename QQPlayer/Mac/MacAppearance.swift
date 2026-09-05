//
//  MacAppearance.swift
//  QQPlayer
//
//  macOS 外观应用：三态主题（NSApp.appearance）与强调色 6 预设
//  （色值对齐 web 版 ACCENT_OPTIONS）。QQPlayerMac target only。
//

import AppKit
import SwiftUI

enum MacAppearance {
    /// 强调色预设（色值对齐 web 版 frontend/src/composables/useSettings.ts ACCENT_OPTIONS）
    static let accentPresets: [(key: String, color: Color)] = [
        ("orange", color(hex: 0xFF7E5F)),
        ("blue", color(hex: 0x5B9DFF)),
        ("green", color(hex: 0x34D399)),
        ("purple", color(hex: 0xA78BFA)),
        ("pink", color(hex: 0xF472B6)),
        ("teal", color(hex: 0x2DD4BF)),
    ]

    /// 未知 key 回退橙色（web 版默认 accent=orange）。
    static func accentColor(forKey key: String) -> Color {
        accentPresets.first { $0.key == key }?.color ?? accentPresets[0].color
    }

    /// 全局外观应用：NSApp.appearance 控制所有窗口（主窗/设置窗/sheet）立即生效；
    /// system = nil（跟随系统立即恢复）。2026-09-02 用户实测 preferredColorScheme
    /// 只作用于挂载视图且 .dark→nil 不重新解析，故用 NSApp。
    static func apply(theme: AppearanceTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    private static func color(hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - App 强调色环境值（macOS 上 Color.accentColor 跟随系统强调色而非 App
// tint，显式使用处不随设置变化——2026-09-05 频谱/列表图标实锤）。自定义环境值
// appAccentColor 由 App 根视图注入（随 DeleteSettings 刷新），内容区统一读它。

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}
