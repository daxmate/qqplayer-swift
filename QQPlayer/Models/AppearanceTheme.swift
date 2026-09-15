//
//  AppearanceTheme.swift
//  QQPlayer
//
//  外观三态主题（跟随系统/深色/浅色）：纯逻辑枚举，跨 iOS/macOS 共享。
//  macOS 设置页写入 DeleteSettings.appearanceTheme（String），应用逻辑在
//  Mac/MacAppearance.swift（NSApp.appearance）。iOS 侧仍用 forceDarkMode。
//
//  另含两端共用的两项「强调色」基础设施（2026-09-15 UI 令牌 B1 收口）：
//  ① 唯一 hex→Color 解析入口 `Color(hex:)`（原 macOS/iOS 各一套 → 合一处，M3）；
//  ② 唯一强调色环境值 `appAccentColor`（原定义在 Mac 专属文件里 → 移到这里，
//     两端同名同定义；注入点：macOS `QQPlayerMacApp` / iOS `ContentView`，I1）。
//

import Foundation
import SwiftUI

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

// MARK: - 唯一 hex→Color 解析入口（M3）

extension Color {
    /// 十六进制字符串 → Color（sRGB）。**全仓唯一的 hex 解析实现**。
    /// 支持 3 位（RGB 12-bit）/ 6 位（RGB 24-bit）/ 8 位（ARGB）；非法输入 → 透明。
    /// 调用方：`BackgroundColor.color`（iOS 强调色名单）、`MacAppearance.accentPresets`（macOS 名单）。
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - App 强调色环境值（iOS / macOS 同一环境值名、同一定义）

/// 强调色的值不在这里定（macOS 色名单在 `MacAppearance.accentPresets`，iOS 在
/// `BackgroundColor`）——这里只定**传递机制**：两端 App 根视图各注入一次，视图统一读它。
/// macOS 上必须显式注入的原因见 `MacAppearance`（`Color.accentColor` 跟随系统强调色而非 App tint）。
private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}

// MARK: - 几何 / 排版令牌（C10 / C12，B2a 2026-09-15）

/// 圆角 / 字号刻度的**唯一列举处**（`docs/ui-design-tokens.md` §2 C10/C12）。
///
/// 本轮（B2a）只做「同值令牌化」：每个令牌的值 = 迁移前那处裸字面量，**逐字相同、零视觉变化**；
/// 不做归一（把 5/7/9/11/14 这类零散值并档是 B2b，待用户拍板）。令牌的作用是把「现在到底有多少种取值」
/// 从「只能靠 grep 盘点」变成一处可列——改前实测圆角 15 种 / **152 处**、字号 26 种 / **115 处**
/// （文档最初记的 12 种 / 25 种是漏项版，且漏了 `.cornerRadius(12)` 这种不带冒号的写法）。
///
/// 命名规则：**按值命名**，小数点写成 `_`（Swift 标识符不允许 `.`）：`radius12_5 = 12.5`。
/// 名字与值必须自洽——`UIAccentContractTests` 里有断言逐条比对「名字解出来的数 == 值」：
/// 拼错名字（`radius1_5` 写成 `radius15`）会让值静默变成另一个数，编译器与截图都发现不了。
///
/// 形状守卫：`QQPlayer/**` 内不得再出现裸 `cornerRadius: <数字>` / `.cornerRadius(<数字>)` /
/// `.system(size: <数字>`（本轮迁移 152 + 115 处 → 裸值 0 处，见 `UIAccentContractTests`）。
/// 令牌定义本身不匹配上述调用点模式 ⇒ 该规则的白名单为空（不是漏配）。
enum DesignTokens {
    // MARK: 圆角（C10：15 种 / 152 处，值 = 迁移前裸字面量）

    /// `0` —— 改前 1 处。
    static let radius0: CGFloat = 0
    /// `0.5` —— 改前 1 处。
    static let radius0_5: CGFloat = 0.5
    /// `2` —— 改前 2 处。
    static let radius2: CGFloat = 2
    /// `4` —— 改前 8 处。
    static let radius4: CGFloat = 4
    /// `5` —— 改前 3 处。
    static let radius5: CGFloat = 5
    /// `6` —— 改前 19 处。
    static let radius6: CGFloat = 6
    /// `7` —— 改前 2 处。
    static let radius7: CGFloat = 7
    /// `8` —— 改前 32 处。
    static let radius8: CGFloat = 8
    /// `10` —— 改前 11 处。
    static let radius10: CGFloat = 10
    /// `12` —— 改前 43 处。
    static let radius12: CGFloat = 12
    /// `14` —— 改前 3 处。
    static let radius14: CGFloat = 14
    /// `16` —— 改前 10 处。
    static let radius16: CGFloat = 16
    /// `20` —— 改前 1 处。
    static let radius20: CGFloat = 20
    /// `25` —— 改前 2 处。
    static let radius25: CGFloat = 25
    /// `28` —— 改前 14 处。
    static let radius28: CGFloat = 28

    // MARK: 字号（C12：26 种 / 115 处，值 = 迁移前裸字面量）

    /// `8` —— 改前 1 处。
    static let font8: CGFloat = 8
    /// `9` —— 改前 1 处。
    static let font9: CGFloat = 9
    /// `11` —— 改前 2 处。
    static let font11: CGFloat = 11
    /// `12` —— 改前 3 处。
    static let font12: CGFloat = 12
    /// `12.5` —— 改前 2 处。
    static let font12_5: CGFloat = 12.5
    /// `13` —— 改前 5 处。
    static let font13: CGFloat = 13
    /// `14` —— 改前 9 处。
    static let font14: CGFloat = 14
    /// `15` —— 改前 4 处。
    static let font15: CGFloat = 15
    /// `16` —— 改前 11 处。
    static let font16: CGFloat = 16
    /// `17` —— 改前 4 处。
    static let font17: CGFloat = 17
    /// `18` —— 改前 5 处。
    static let font18: CGFloat = 18
    /// `19` —— 改前 1 处。
    static let font19: CGFloat = 19
    /// `20` —— 改前 7 处。
    static let font20: CGFloat = 20
    /// `22` —— 改前 5 处。
    static let font22: CGFloat = 22
    /// `24` —— 改前 2 处。
    static let font24: CGFloat = 24
    /// `26` —— 改前 6 处。
    static let font26: CGFloat = 26
    /// `30` —— 改前 3 处。
    static let font30: CGFloat = 30
    /// `32` —— 改前 1 处。
    static let font32: CGFloat = 32
    /// `36` —— 改前 7 处。
    static let font36: CGFloat = 36
    /// `40` —— 改前 21 处。
    static let font40: CGFloat = 40
    /// `44` —— 改前 3 处。
    static let font44: CGFloat = 44
    /// `50` —— 改前 4 处。
    static let font50: CGFloat = 50
    /// `52` —— 改前 2 处。
    static let font52: CGFloat = 52
    /// `60` —— 改前 4 处。
    static let font60: CGFloat = 60
    /// `64` —— 改前 1 处。
    static let font64: CGFloat = 64
    /// `70` —— 改前 1 处。
    static let font70: CGFloat = 70

    // MARK: 间距（C11：33 种 / 829 处，值 = 迁移前裸字面量，B2c-a 2026-09-16）

    /// 副标题：`padding`（含边参数写法）/ 容器 `spacing:` / `Spacer(minLength:)` 三类调用点的字面量。
    /// 每行注释里的「改前 N 处」是迁移前实测（口径 = B2c 迁移脚本同一套正则），
    /// 供下一阶段（B2c-b 归一）直接读数，不必再 grep。
    /// `0` —— 改前 69 处（spacing 57 / Spacer.minLength 12）。
    static let space0: CGFloat = 0
    /// `1` —— 改前 11 处（padding 5 / spacing 6）。
    static let space1: CGFloat = 1
    /// `1.5` —— 改前 1 处（padding 1）。
    static let space1_5: CGFloat = 1.5
    /// `2` —— 改前 63 处（padding 24 / spacing 39）。
    static let space2: CGFloat = 2
    /// `3` —— 改前 11 处（padding 3 / spacing 8）。
    static let space3: CGFloat = 3
    /// `4` —— 改前 65 处（padding 32 / spacing 32 / Spacer.minLength 1）。
    static let space4: CGFloat = 4
    /// `5` —— 改前 12 处（padding 10 / spacing 2）。
    static let space5: CGFloat = 5
    /// `6` —— 改前 44 处（padding 19 / spacing 24 / Spacer.minLength 1）。
    static let space6: CGFloat = 6
    /// `7` —— 改前 2 处（padding 2）。
    static let space7: CGFloat = 7
    /// `8` —— 改前 154 处（padding 62 / spacing 92）。
    static let space8: CGFloat = 8
    /// `9` —— 改前 3 处（padding 3）。
    static let space9: CGFloat = 9
    /// `10` —— 改前 64 处（padding 19 / spacing 45）。
    static let space10: CGFloat = 10
    /// `12` —— 改前 103 处（padding 41 / spacing 61 / Spacer.minLength 1）。
    static let space12: CGFloat = 12
    /// `14` —— 改前 28 处（padding 15 / spacing 13）。
    static let space14: CGFloat = 14
    /// `16` —— 改前 92 处（padding 58 / spacing 34）。
    static let space16: CGFloat = 16
    /// `18` —— 改前 2 处（padding 2）。
    static let space18: CGFloat = 18
    /// `20` —— 改前 42 处（padding 28 / spacing 12 / Spacer.minLength 2）。
    static let space20: CGFloat = 20
    /// `22` —— 改前 1 处（padding 1）。
    static let space22: CGFloat = 22
    /// `24` —— 改前 18 处（padding 13 / spacing 3 / Spacer.minLength 2）。
    static let space24: CGFloat = 24
    /// `25` —— 改前 1 处（spacing 1）。
    static let space25: CGFloat = 25
    /// `26` —— 改前 3 处（padding 2 / spacing 1）。
    static let space26: CGFloat = 26
    /// `28` —— 改前 1 处（spacing 1）。
    static let space28: CGFloat = 28
    /// `30` —— 改前 2 处（padding 2）。
    static let space30: CGFloat = 30
    /// `32` —— 改前 10 处（padding 7 / spacing 3）。
    static let space32: CGFloat = 32
    /// `40` —— 改前 8 处（padding 8）。
    static let space40: CGFloat = 40
    /// `44` —— 改前 3 处（padding 3）。
    static let space44: CGFloat = 44
    /// `50` —— 改前 1 处（padding 1）。
    static let space50: CGFloat = 50
    /// `56` —— 改前 1 处（padding 1）。
    static let space56: CGFloat = 56
    /// `60` —— 改前 3 处（padding 3）。
    static let space60: CGFloat = 60
    /// `64` —— 改前 1 处（padding 1）。
    static let space64: CGFloat = 64
    /// `100` —— 改前 7 处（padding 7）。
    static let space100: CGFloat = 100
    /// `110` —— 改前 1 处（padding 1）。
    static let space110: CGFloat = 110
    /// `120` —— 改前 2 处（padding 2）。
    static let space120: CGFloat = 120
}
