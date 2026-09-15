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
    /// 强调色预设（色值对齐 web 版 frontend/src/composables/useSettings.ts ACCENT_OPTIONS）。
    /// 色值解析走全仓唯一的 `Color(hex:)`（Models/AppearanceTheme.swift，M3）。
    static let accentPresets: [(key: String, color: Color)] = [
        ("orange", Color(hex: "FF7E5F")),
        ("blue", Color(hex: "5B9DFF")),
        ("green", Color(hex: "34D399")),
        ("purple", Color(hex: "A78BFA")),
        ("pink", Color(hex: "F472B6")),
        ("teal", Color(hex: "2DD4BF")),
    ]

    /// 未知 key 回退橙色（web 版默认 accent=orange）。
    static func accentColor(forKey key: String) -> Color {
        accentPresets.first { $0.key == key }?.color ?? accentPresets[0].color
    }

    // MARK: - 当前强调色（全 App 唯一读取入口）

    /// 当前强调色 key（from `DeleteSettings.accentColorName`）。
    /// **不要在视图/窗口里再写 `DeleteSettings.load().accentColorName`**——主窗（QQPlayerMacApp）
    /// 与桌面浮窗（DesktopWindowsManager）都从这里取，保证同源（M2）。
    static var currentAccentKey: String { DeleteSettings.load().accentColorName }

    /// 当前强调色色值（= `currentAccentKey` 经预设名单解析）。
    static var currentAccentColor: Color { accentColor(forKey: currentAccentKey) }

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

}

// 强调色传递（2026-09-15 B1 收口）：环境值 `appAccentColor` 的定义已移到共享文件
// Models/AppearanceTheme.swift（iOS 也要用同一个环境值名）。
// 为何 macOS 不能直接用 `Color.accentColor`：它跟随系统强调色而非 App tint，
// 显式使用处不随设置变化——2026-09-05 频谱/列表图标实锤。故 App 根视图
// （QQPlayerMacApp）与桌面浮窗（MacDesktopWindowsManager）显式注入，内容区统一读环境值。
