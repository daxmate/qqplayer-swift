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
/// **B2a（同值令牌化，零视觉变化）**：每个令牌的值 = 迁移前那处裸字面量（实测圆角 15 种 / 152 处、
/// 字号 26 种 / 115 处）。**B2b（归一，有视觉变化，用户 2026-09-16 拍板）**：把零散档并到刻度上——
/// 圆角 `0.5→0 / 5→4 / 7→6 / 14→12 / 25→24`，字号 `11→12 / 12.5→12`；
/// 并档口径 = 就近取整，两侧等距取较小整数（`docs/ui-design-tokens.md` §B2b）。
/// 归一后：**圆角 11 种 / 152 处，字号 24 种 / 116 处**。
///
/// 命名规则：**按值命名**，小数点写成 `_`（Swift 标识符不允许 `.`）：`radius12_5 = 12.5`。
/// 名字与值必须自洽——`UIAccentContractTests` 里有断言逐条比对「名字解出来的数 == 值」：
/// 拼错名字（`radius1_5` 写成 `radius15`）会让值静默变成另一个数，编译器与截图都发现不了。
///
/// 形状守卫：`QQPlayer/**` 内不得再出现裸 `cornerRadius: <数字>` / `.cornerRadius(<数字>)` /
/// `.system(size: <数字>`（本轮迁移 152 + 115 处 → 裸值 0 处，见 `UIAccentContractTests`）。
/// 令牌定义本身不匹配上述调用点模式 ⇒ 该规则的白名单为空（不是漏配）。
enum DesignTokens {
    // MARK: 圆角（C10：归一后 11 种 / 152 处，B2b 2026-09-16）

    /// 直角（语义：无圆角）。
    /// 改前 1 处；B2b 并由 `0.5`（+1 处，小数档就近取整 → 等距取较小整数）。
    static let radius0: CGFloat = 0
    /// 改前 2 处。
    static let radius2: CGFloat = 2
    /// 改前 8 处；B2b 并由 `5`（+3 处，4|6 等距 → 取较小）。
    static let radius4: CGFloat = 4
    /// 改前 19 处；B2b 并由 `7`（+2 处，6|8 等距 → 取较小）。
    static let radius6: CGFloat = 6
    /// 改前 32 处。
    static let radius8: CGFloat = 8
    /// 改前 11 处。
    static let radius10: CGFloat = 10
    /// 改前 43 处；B2b 并由 `14`（+3 处，12|16 等距 → 取较小）。
    static let radius12: CGFloat = 12
    /// 改前 10 处。
    static let radius16: CGFloat = 16
    /// 改前 1 处。
    static let radius20: CGFloat = 20
    /// B2b 新增档位（改前 0 处）；由 `25` 就近取整而来（+2 处）。
    static let radius24: CGFloat = 24
    /// 改前 14 处（大卡面 / 歌词卡片）。
    static let radius28: CGFloat = 28

    // MARK: 字号（C12：归一后 24 种 / 116 处，B2b 2026-09-16）

    /// 改前 1 处。
    static let font8: CGFloat = 8
    /// 改前 1 处。
    static let font9: CGFloat = 9
    /// 小字档唯一刻度（语义：辅助说明 / 桌面歌词角标）。
    /// 改前 3 处；B2b 并由 `11`（+2 处）与 `12.5`（+2 处，小数档就近取整）。
    static let font12: CGFloat = 12
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

    // MARK: 间距（C11：18 档 / 845 处，B2c-b 第 1 笔 2026-09-17）

    /// 三类调用点的字面量都收敛到这里：`.padding`（含边参数写法）/ 容器 `spacing:` /
    /// `Spacer(minLength:)`。刻度 = 4pt 基准建议刻度（用户拍板表见
    /// `docs/ui-design-tokens.md` §「间距归一对照表（B2c-b）」）。
    /// 第 1 笔并掉「位移 ≤2pt」的微调档；`space14 → space12` 是中等视觉影响，单独第 2 笔，
    /// 故本笔它仍是合法刻度（下一笔会连定义一起删）。
    /// 注释口径：`改前 N 处` = B2c-a 迁移前裸字面量实测；`归一后 N 处` = 本笔实测引用数
    /// （含表达式内字面量令牌化进来的那些）。
    /// `0` —— 改前 69 处 → 归一后 70 处（spacing 57 / Spacer.minLength 12）。
    static let space0: CGFloat = 0
    /// `2` —— 改前 63 处 → 归一后 76 处（含 `1 → 2` 11 处、`1.5 → 2` 1 处；padding 31 / spacing 45）。
    static let space2: CGFloat = 2
    /// `4` —— 改前 65 处 → 归一后 92 处（含 `3 → 4` 11 处、`5 → 4` 12 处；padding 45 / spacing 46 / Spacer.minLength 1）。
    static let space4: CGFloat = 4
    /// `6` —— 改前 44 处 → 归一后 44 处（未并档；padding 19 / spacing 24 / Spacer.minLength 1）。
    static let space6: CGFloat = 6
    /// `8` —— 改前 154 处 → 归一后 160 处（含 `7 → 8` 2 处、`9 → 8` 3 处；padding 67 / spacing 93）。
    static let space8: CGFloat = 8
    /// `10` —— 改前 64 处 → 归一后 64 处（未并档；padding 19 / spacing 45）。
    static let space10: CGFloat = 10
    /// `12` —— 改前 103 处 → 归一后 103 处（未并档；第 2 笔会把 `space14` 的 29 处并进来）。
    static let space12: CGFloat = 12
    /// `14` —— 改前 28 处 → 归一后 29 处（**第 2 笔并到 `space12`**；中等视觉影响，单独成笔）。
    static let space14: CGFloat = 14
    /// `16` —— 改前 92 处 → 归一后 97 处（含 `18 → 16` 2 处 + 表达式内 3 处；padding 60 / spacing 34）。
    static let space16: CGFloat = 16
    /// `20` —— 改前 42 处 → 归一后 44 处（含 `22 → 20` 1 处 + 表达式内 1 处；padding 29 / spacing 12 / Spacer.minLength 2）。
    static let space20: CGFloat = 20
    /// `24` —— 改前 18 处 → 归一后 25 处（含 `25 → 24` 1 处、`26 → 24` 3 处、`28 → 24` 1 处 + 表达式内 1 处）。
    static let space24: CGFloat = 24
    /// `32` —— 改前 10 处 → 归一后 13 处（含 `30 → 32` 2 处 + 表达式内 1 处；padding 9 / spacing 3）。
    static let space32: CGFloat = 32
    /// `40` —— 改前 8 处 → 归一后 12 处（含 `44 → 40` 3 处 + 表达式内 1 处；全部是 padding）。
    static let space40: CGFloat = 40
    /// `48` —— 改前 0 处（**本笔新增档位**）→ 归一后 2 处，收 `50 → 48` 1 处、`56 → 48` 1 处。
    static let space48: CGFloat = 48
    /// `64` —— 改前 1 处 → 归一后 4 处（含 `60 → 64` 3 处；全部是 padding）。
    static let space64: CGFloat = 64
    /// `100` —— 7 处。大留白（多为底部播放条让位），语义特殊，**归一不动**。
    static let space100: CGFloat = 100
    /// `110` —— 1 处。同上（大留白）。
    static let space110: CGFloat = 110
    /// `120` —— 2 处。同上（大留白）。
    static let space120: CGFloat = 120
}
