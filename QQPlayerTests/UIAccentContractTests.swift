//
//  UIAccentContractTests.swift
//  QQPlayerTests
//
//  强调色「防裸用」形状契约（2026-09-15 UI 设计令牌 B1，见 docs/ui-design-tokens.md §5）。
//  同文件后续章节：B2a 圆角 / 字号防裸值（`UIGeometryContract`），
//  B2c-a 间距防裸值（`UISpacingContract`）——三章共用同一套扫描纯函数，不另起测试文件。
//
//  背景：强调色的**名单**一直是唯一的（macOS `MacAppearance.accentPresets` / iOS
//  `BackgroundColor`），坏的是**传递机制**——2026-09-05 把 22 处 `Color.accentColor`
//  换成环境值后，2026-09-11/12 新增同步页又复发 6 处（macOS 上 `Color.accentColor`
//  跟系统强调色、不跟 App tint）；iOS 侧则完全没有环境值，142 处直读 settings。
//  这类问题单测覆盖不到（是「多写了一套传递路径」），只能用静态形状契约兜住。
//
//  设计要点（照 DisplayScriptContractTests / SyncWiringContractTests 的写法）：
//  - 扫描规则 + 白名单收敛在纯函数 `UIAccentContract.scan(source:filePath:rules:)`，
//    **不碰文件系统** → 测试里能用合成源码自证「能抓到违规」（防契约空转）。
//  - 白名单 fail-closed：没列出的裸用一律算违规；并有单独用例断言「每条白名单条目
//    都还在真实源码里命中」，防止白名单腐烂（代码改了条目没删）。
//  - 注释行不计（文档/说明里出现反例写法不该判违规）。
//

import Foundation
import Testing

@testable import QQPlayer

// SCAN-BEGIN —— 以下到 SCAN-END 之间是纯逻辑（只用 Foundation 字符串 API，不碰文件系统）

enum UIAccentContract {
    /// 白名单条目：文件路径尾段 + 行内容片段 + 理由（理由必写明「为什么这里合法」）
    struct WhitelistEntry {
        let fileSuffix: String
        let lineSnippet: String
        let reason: String
    }

    /// 一条静态规则：禁止的正则 + 合法例外
    struct Rule {
        let name: String
        let pattern: String
        let whitelist: [WhitelistEntry]
    }

    /// 规则 1：macOS 代码不得再出现系统的 `Color.accentColor`（含裸 `.accentColor` 字面量）。
    /// 它跟系统强调色、不跟 App tint（2026-09-05 频谱/列表图标实锤）→ 必须读环境值。
    /// 正则的三处排除（都不是「取系统强调色」）：
    ///  - `self.accentColor` / `Localized.accentColor`：属性名与本地化 key，不是颜色成员；
    ///  - `.accentColorName`：设置字段名；
    ///  - `.accentColor(forKey:)`：预设名单查询入口（合法调用）。
    static let macSystemAccentRule = Rule(
        name: "macOS 强调色走环境值 appAccentColor，不得用 Color.accentColor",
        pattern: #"(?<!Localized)(?<!self)\.accentColor(?![\w(])"#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: "QQPlayer/Models/AppearanceTheme.swift",
                lineSnippet: "static let defaultValue: Color = .accentColor",
                reason: "强调色环境值的默认值：没有任何注入时回落系统强调色（唯一合法处）"
            ),
        ]
    )

    /// 规则 2：iOS 视图不得直读配色设置字段（唯一字段 = `accentColorName`）。
    /// 注入点在 App 根（ContentView），视图统一读 `@Environment(\.appAccentColor)`；要色值走
    /// `IOSAppearance` 名单（唯一取数入口），不在视图里自己查表。
    /// 2026-09-17 设置字段层收口：旧字段 `backgroundColorChoice`（hex）退役，本规则改盯新字段名——
    /// 否则规则会变成「盯一个不存在的字段」的空转。
    static let iosDirectReadRule = Rule(
        name: "iOS 视图读环境值 appAccentColor，不得直读 settings.accentColorName",
        pattern: #"accentColorName"#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: "QQPlayer/Views/Utility/SettingsView.swift",
                lineSnippet: "deleteSettings.accentColorName == preset.key",
                reason: "设置页配色选择器：读当前 token 做选中态（设置页本身要读写这个字段）"
            ),
            WhitelistEntry(
                fileSuffix: "QQPlayer/Views/Utility/SettingsView.swift",
                lineSnippet: "deleteSettings.accentColorName = preset.key",
                reason: "设置页配色选择器：写新 token（iOS 侧唯一写点）"
            ),
        ]
    )

    /// 规则 3：macOS 「当前强调色」只能有一处读取（M2）。
    /// 允许读 `accentColorName` 的只有两者：`MacAppearance`（取值唯一入口）与
    /// `MacSettingsView`（设置页本身要读/写这个字段）。窗口/视图里再自读就是第二条路径。
    /// （`accentColorName` 自 2026-09-17 起是**两端共用的唯一配色字段**，iOS 侧同名约束见规则 2；
    /// 下方 setter 那行是 macOS 侧唯一写点。）
    static let macAccentReadRule = Rule(
        name: "macOS 当前强调色只能由 MacAppearance 唯一读取（设置页读写除外）",
        pattern: #"accentColorName"#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: "QQPlayer/Mac/MacAppearance.swift",
                lineSnippet: "static var currentAccentKey: String { DeleteSettings.load().accentColorName }",
                reason: "全 App 唯一的强调色读取入口（主窗/浮窗/频谱都从 currentAccentColor 取）"
            ),
            WhitelistEntry(
                fileSuffix: "QQPlayer/Mac/MacSettingsView.swift",
                lineSnippet: "let isSelected = deleteSettings.accentColorName == preset.key",
                reason: "设置页强调色选择器：读当前值做选中态"
            ),
            WhitelistEntry(
                fileSuffix: "QQPlayer/Mac/MacSettingsView.swift",
                lineSnippet: "settings.accentColorName = preset.key",
                reason: "设置页强调色选择器：写入新值（唯一写点）"
            ),
        ]
    )

    /// 规则 4：**已退役的配色字段不得复活**（2026-09-17 设置字段层收口）。
    ///
    /// 唯一配色字段 = `DeleteSettings.accentColorName`（token）。旧 iOS 字段 `backgroundColorChoice`
    /// （hex rawValue）只剩「读老数据」一处合法出现（`SettingsModels` 的 `LegacyCodingKeys`）。
    /// 复活 = 又出现第二份配色语义：macOS 读到 iOS 的旧值、或读到从未被写入的默认值（读错字段拿错色）。
    static let retiredColorFieldRule = Rule(
        name: "配色字段唯一 accentColorName，旧字段 backgroundColorChoice 只允许出现在迁移读取处",
        pattern: #"backgroundColorChoice"#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: "QQPlayer/Models/SettingsModels.swift",
                lineSnippet: "case backgroundColorChoice",
                reason: "旧字段名的唯一声明处（LegacyCodingKeys，只为读老数据、不再写回）"
            ),
            WhitelistEntry(
                fileSuffix: "QQPlayer/Models/SettingsModels.swift",
                lineSnippet: "forKey: .backgroundColorChoice",
                reason: "老数据迁移的唯一读取点（decode 时把旧 hex 映射成 token）"
            ),
        ]
    )

    /// 一次扫描的结果
    struct Report {
        var scannedLines = 0
        /// 命中过禁止模式的行数（>0 说明规则确实在匹配真实代码，不是空转）
        var forbiddenLines = 0
        /// 违规行描述：`路径:行号: 行内容 → 违反 <规则名>`
        var violations: [String] = []
        /// 命中的白名单下标（白名单腐烂检测用）
        var whitelistHits: Set<String> = []
    }

    /// 纯函数扫描：源码文本 → 违规列表（不读文件系统，便于合成源码单测）
    static func scan(source: String, filePath: String, rules: [Rule]) -> Report {
        var report = Report()
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            report.scannedLines += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 注释不是代码（文档里出现反例写法不该判违规）
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }

            for rule in rules {
                guard line.range(of: rule.pattern, options: .regularExpression) != nil else { continue }
                report.forbiddenLines += 1
                // 白名单：整行命中即豁免（fileSuffix + lineSnippet 同时匹配才算）
                if let hit = rule.whitelist.firstIndex(where: {
                    filePath.hasSuffix($0.fileSuffix) && line.contains($0.lineSnippet)
                }) {
                    report.whitelistHits.insert("\(rule.name)|\(hit)")
                    continue
                }
                report.violations.append(
                    "\(filePath):\(index + 1): \(trimmed)  → 违反「\(rule.name)」"
                )
            }
        }
        return report
    }
}

// MARK: - 圆角 / 字号「防裸值」规则（B2a 2026-09-15）

/// 几何 / 排版令牌的形状契约（扫描机制与 `UIAccentContract` 共用同一套纯函数）。
///
/// 背景：圆角与字号从来没有令牌——B2a 迁移前实测圆角 **15 种取值 / 152 处**、字号 **26 种 / 115 处**，
/// 只能靠 grep 盘点，「现在到底有哪些取值」没人说得清（文档最初记的 12 / 25 是漏项版）。
/// B2a 把它们收成 `DesignTokens.radius* / font*`（**同值令牌化，零视觉变化**）。
/// 这条契约保证它**不会再散回去**：这类问题测行为测不到（多写一套字面量不改变任何行为），
/// 只能用静态形状契约兜住，且 fail-closed（没列白名单的裸值一律算违规）。
///
/// 比强调色那套多一条断言：**令牌名 ↔ 值自洽**。令牌按值命名（`radius12_5 = 12.5`），
/// 名字拼错（`radius1_5` 误写成 `radius15`）会让值静默变成另一个数——编译器、lint、截图都发现不了。
///
/// 已知边界（line-based 扫描的固有局限，与 B1 同款）：只认同一行内的写法；
/// `cornerRadius:` 与数字分行的写法抓不到（当前代码 0 处，实测）。
enum UIGeometryContract {
    /// 规则 1：圆角不得再写字面量，含 `.cornerRadius(12)` 这种不带冒号的旧修饰符写法。
    /// 正则要求「数字后紧跟 `,` 或 `)`」⇒ 非字面量不误判（`cornerRadius: cornerRadius`、
    /// `cornerRadius: barWidth / 2`、三元表达式），令牌引用（`DesignTokens.radius8`）也不会自匹配。
    static let nakedRadiusRule = UIAccentContract.Rule(
        name: "圆角走 DesignTokens.radius*，不得写字面量",
        pattern: #"(?:cornerRadius:\s*|\.cornerRadius\(\s*)-?\d+(?:\.\d+)?\s*[,)]"#,
        whitelist: [
            // 令牌定义在 Models/AppearanceTheme.swift，但那里是 `static let radius12: CGFloat = 12`，
            // 不匹配本模式（模式锚在调用点形态 `cornerRadius:` / `.cornerRadius(`）⇒ 实测命中 0 次，
            // 故白名单为空。空白的理由是「不需要」，不是「忘了写」。
        ]
    )

    /// 规则 2：字号不得再写 `Font.system(size: <字面量>)`（`.font(.system(...))` 与 `return .system(...)` 同属此形态）。
    /// 同样要求「数字后紧跟 `,` 或 `)`」⇒ `size: fontSize` / `size: 17 * fontScale` / `size: DesignTokens.font12`
    /// 都不算违规（表达式里的字号字面量本轮刻意不动，清单见 docs/ui-design-tokens.md）。
    static let nakedFontSizeRule = UIAccentContract.Rule(
        name: "字号走 DesignTokens.font*，不得写 Font.system(size: <字面量>)",
        pattern: #"\.system\(size:\s*-?\d+(?:\.\d+)?\s*[,)]"#,
        whitelist: []
    )

    /// 规则 3：**字面量参与运算**也要令牌化（`size: 17 * fontScale` —— 值来源仍是字面量，属同一缺口）。
    /// 正则锚在「实参**开头就是数字**后紧跟算术运算符」⇒ 结构化排除误伤：变量左操作数
    /// （`size: size * scale` / `size: base / 2`）与已令牌化写法（`size: DesignTokens.font17 * scale`）
    /// 都不命中。
    /// **刻意不做「实参任意位置出现数字」的宽匹配**：`fontSize * 0.45`、`max(size * 0.3, 10)` 里的
    /// 0.45 / 0.3 是**比例常数**（不是字号），宽匹配会把它们误判成裸值、逼着写成 `DesignTokens.font45`
    /// 这种语义错的令牌。残余（实参非开头处、且是该实参的**夹取边界**：`min(80, …)` 的 80、
    /// `max(size * 0.3, 10)` 的 10）列在 docs/ui-design-tokens.md §B2b 作为**刻意保留的例外**。
    /// （「纯档位三元」`? 22 : 19`、`? 6 : 12` 已在 B2b 2026-09-16 令牌化，值与归一档位一致、零视觉变化。）
    static let nakedFontSizeArithmeticRule = UIAccentContract.Rule(
        name: "字号实参开头的字面量参与运算（size: 17 * fontScale）也要令牌化",
        pattern: #"\.system\(size:\s*-?\d+(?:\.\d+)?\s*[*/+\-]"#,
        whitelist: []
    )

    /// 规则 4：圆角字面量参与运算（`cornerRadius: 8 * scale`），与规则 3 同形。实测当前 0 处（预防性）。
    static let nakedRadiusArithmeticRule = UIAccentContract.Rule(
        name: "圆角实参开头的字面量参与运算也要令牌化",
        pattern: #"(?:cornerRadius:\s*|\.cornerRadius\(\s*)-?\d+(?:\.\d+)?\s*[*/+\-]"#,
        whitelist: []
    )

    /// 全部规则（扫描真实源码用）：新增规则必须登记到这里，否则它只服务合成用例、守卫空转
    static let allRules = [nakedRadiusRule, nakedFontSizeRule, nakedRadiusArithmeticRule, nakedFontSizeArithmeticRule]

    /// 一条令牌定义：`static let radius12_5: CGFloat = 12.5` → name `radius12_5` / value `12.5`
    struct Token: Equatable {
        let name: String
        let value: String

        /// 名字里编码的数（`radius12_5` → `12.5`）。与 `value` 不等 = 名字拼错
        var valueEncodedInName: String {
            name.drop { !$0.isNumber }.replacingOccurrences(of: "_", with: ".")
        }
    }

    /// 纯函数：解析令牌定义文件源码（不碰文件系统）。
    /// 形态不符的行直接跳过——测试里另有「定义集合 == 引用集合」兜住漏解析（解析漏了必然不等）。
    static func parseTokens(source: String) -> [Token] {
        var result: [Token] = []
        for line in source.components(separatedBy: .newlines) {
            // static let <name>: CGFloat = <value>
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 6, parts[0] == "static", parts[1] == "let",
                  parts[3] == "CGFloat", parts[4] == "=", parts[2].hasSuffix(":")
            else { continue }
            let name = String(parts[2].dropLast())
            // 三类令牌同住 `enum DesignTokens`：B2a 圆角 / 字号 + B2c-a 间距
            guard name.hasPrefix("radius") || name.hasPrefix("font") || name.hasPrefix("space") else { continue }
            result.append(Token(name: name, value: String(parts[5])))
        }
        return result
    }

    /// 纯函数：挑出「名字编码的数 != 定义值」的令牌（防拼错名静默改值）
    static func selfInconsistent(_ tokens: [Token]) -> [String] {
        tokens
            .filter { $0.valueEncodedInName != $0.value }
            .map { "\($0.name) = \($0.value)（名字编码的是 \($0.valueEncodedInName)）" }
    }
}

// MARK: - 间距「防裸值」规则（B2c-a 2026-09-16）

/// 间距令牌（C11）的形状契约。扫描机制与 `UIAccentContract` / `UIGeometryContract` 共用同一套纯函数。
///
/// 背景：间距从来没有令牌。B2c-a 迁移前实测 **829 处 / 33 种取值**——`.padding(<数>)` 33 处、
/// `.padding(.<边>, <数>)` 343 处、容器 `spacing:` / `GridItem(spacing:)` 434 处、
/// `Spacer(minLength:)` 19 处（`docs/ui-design-tokens.md` §3 M4 旧记录写 376 + 416 + 21，是漏项版）。
/// 「这一屏留白到底几 pt」只能靠 grep 盘点 ⇒ B2c-a 收成 `DesignTokens.space*`
/// （**同值令牌化，零视觉变化**：每个令牌的值 = 迁移前那处裸字面量，逐字相同），本条契约保证它不散回去。
///
/// 与 B2a 同款 fail-closed 难点：这条规则的目标状态就是 **0 命中** ⇒ 不能用「命中数 > 0」证明非空转，
/// 改用 ① 合成源码正反例（裸值恰好被抓、令牌/变量/表达式/注释不误报）；② 令牌引用条数下限 + 定义↔引用一一对应。
///
/// 刻意**不抓**的形态（本阶段边界，「不迁移清单」见 `docs/ui-design-tokens.md` §3 M4）：
/// - `.padding()` 空参（= 系统默认 16）、`.padding(.horizontal)` 仅边参数——没有数值可令牌化；
/// - 变量 / 表达式：`spacing: someVar`、`spacing: Self.spacing`、`.padding(compact ? 20 : 44)`、
///   `spacing: … ? 12 : 16`、`.padding(.horizontal, max(16, …))`（这些是 B2c-b 归一的输入）；
/// - 声明而非调用点：`let spacing: CGFloat = 2`、`static let spacing: CGFloat = 12`、`spacing: CGFloat = spacing`。
///
/// 已知边界（line-based 扫描的固有局限，与 B1/B2a 同款）：只认同一行内的写法；
/// `spacing:` 与数字分行的写法抓不到（当前代码 0 处，实测）。
///
/// 阈值纪律：本轮每条令牌定义行都会自匹配吗？不会——`static let space8: CGFloat = 8` 里没有
/// `padding(` / `spacing:` / `SpaceSpacer(minLength:` 这些调用点形态，实测命中 0 次 ⇒ **白名单为空是正常的**，
/// 不是漏配（B2a 同款结论）。
///
/// 未来若新增 `QQPlayer/**` 之外的 SwiftUI 代码（`Share/` / `PlayerWidget/`），属另一 target 的归属问题，
/// 记「范围外」而不是硬迁。
enum UISpacingContract {
    /// 规则 1：`.padding(<字面量>)`。
    /// 正则要求「数字后紧跟 `)`」⇒ `.padding()` / `.padding(.horizontal)` / `.padding(DesignTokens.space8)` /
    /// `.padding(compact ? 20 : 44)` / `.padding(max(16, …))` 都不命中（它们是别的形态，不是要迁移的裸值）。
    static let nakedPaddingRule = UIAccentContract.Rule(
        name: "内边距走 DesignTokens.space*，不得写 .padding(<字面量>)",
        pattern: #"\.padding\(\s*-?\d+(?:\.\d+)?\s*\)"#,
        whitelist: []
    )

    /// 规则 2：`.padding(.<边>, <字面量>)`。**边参数与数值是两个维度**，只有数值该令牌化；
    /// 仅边参数（`.padding(.horizontal)`）与令牌实参都不命中。
    static let nakedPaddingEdgeRule = UIAccentContract.Rule(
        name: "内边距走 DesignTokens.space*，不得写 .padding(.<边>, <字面量>)",
        pattern: #"\.padding\(\s*\.(?:horizontal|vertical|top|leading|trailing|bottom)\s*,\s*-?\d+(?:\.\d+)?\s*\)"#,
        whitelist: []
    )

    /// 规则 3：容器间距 —— `VStack/HStack/LazyVStack/LazyVGrid(spacing:)` 与 `GridItem(spacing:)`
    /// （`Grid(horizontalSpacing:verticalSpacing:)` 同形，当前仓库 0 处，预防性覆盖）。
    /// 要求「数字后紧跟 `,` / `)` / 行尾」⇒ `spacing: someVar` / `spacing: 12 * scale` /
    /// `spacing: … ? 12 : 16` / `let spacing: CGFloat = 2` 全不命中。
    static let nakedSpacingRule = UIAccentContract.Rule(
        name: "容器间距走 DesignTokens.space*，不得写 spacing: <字面量>",
        pattern: #"(?:horizontalSpacing|verticalSpacing|spacing):\s*-?\d+(?:\.\d+)?\s*(?:[,)]|$)"#,
        whitelist: []
    )

    /// 规则 4：`Spacer(minLength: <字面量>)`。
    static let nakedSpacerMinLengthRule = UIAccentContract.Rule(
        name: "Spacer(minLength:) 走 DesignTokens.space*，不得写字面量",
        pattern: #"Spacer\(\s*minLength:\s*-?\d+(?:\.\d+)?\s*[,)]"#,
        whitelist: []
    )

    /// 规则 5：**字面量参与运算**（`.padding(8 * scale)` / `spacing: 12 * scale` / `Spacer(minLength: 8 * scale)`）。
    /// 值来源仍是字面量，属同一缺口。正则锚在「实参**开头就是数字**后紧跟算术运算符」⇒ 结构化排除误伤：
    /// 变量左操作数（`.padding(size * 0.5)`）、令牌参与运算（`.padding(DesignTokens.space8 * scale)`）、
    /// 自定义函数实参（`.padding(.vertical, LyricLineEmphasis.linePadding(…))`）都不命中。
    /// **刻意不做「实参任意位置出现数字」的宽匹配**（B2a 同款理由）：`size * 0.5` 里的比例常数不是间距，
    /// 宽匹配会逼出 `DesignTokens.space0_5` 这种语义错的令牌。实测当前 0 处（预防性，与 B2a 的圆角同形规则一致）。
    static let nakedSpacingArithmeticRule = UIAccentContract.Rule(
        name: "间距实参开头的字面量参与运算（padding(8 * scale)）也要令牌化",
        pattern: #"(?:\.padding\(\s*(?:\.(?:horizontal|vertical|top|leading|trailing|bottom)\s*,\s*)?|(?:horizontalSpacing|verticalSpacing|spacing):\s*|Spacer\(\s*minLength:\s*)-?\d+(?:\.\d+)?\s*[*/+\-]"#,
        whitelist: []
    )

    /// 全部规则（扫描真实源码用）：新增规则必须登记到这里，否则它只服务合成用例、守卫空转
    static let allRules = [
        nakedPaddingRule, nakedPaddingEdgeRule, nakedSpacingRule, nakedSpacerMinLengthRule, nakedSpacingArithmeticRule,
    ]

    /// 令牌引用条数下限（非空兜底：正则写坏时前面的断言会假绿）
    static let minimumReferenceCount = 700
}

// SCAN-END

extension UIAccentContract {
    /// 规则 1 / 3 的扫描范围：macOS 视图与装配代码 + 强调色环境值定义文件
    /// （环境值定义在共享文件里，仅那一处允许出现 `.accentColor` 默认值）。
    static let macScanPaths = ["QQPlayer/Mac", "QQPlayer/Models/AppearanceTheme.swift"]

    /// 规则 2 的扫描范围：iOS 视图层。
    static let iosViewScanPaths = ["QQPlayer/Views"]

    /// iOS 注入点所在文件（规则 2 的「非空转」佐证：这个模式仍在注入点命中）
    static let iosInjectionFile = "QQPlayer/ContentView.swift"

    /// 递归收集 .swift（文件系统访问只在这个辅助函数里，核心扫描保持纯净）
    static func swiftFiles(under relativePaths: [String], repoRoot: URL) -> [URL] {
        var result: [URL] = []
        let fileManager = FileManager.default
        for path in relativePaths {
            let base = repoRoot.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                result.append(base)
                continue
            }
            guard let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// App 源码（不含测试：测试里会出现「反例写法」字符串，不该自判）
    static func appSourceFiles(repoRoot: URL) -> [URL] {
        swiftFiles(under: ["QQPlayer"], repoRoot: repoRoot)
    }
}

// MARK: - 测试

struct UIAccentContractTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    static func scanFiles(_ urls: [URL], rules: [UIAccentContract.Rule]) -> (violations: [String], forbiddenLines: Int, hits: Set<String>) {
        var violations: [String] = []
        var forbiddenLines = 0
        var hits: Set<String> = []
        for file in urls {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let report = UIAccentContract.scan(source: source, filePath: Self.relativePath(file), rules: rules)
            violations.append(contentsOf: report.violations)
            forbiddenLines += report.forbiddenLines
            hits.formUnion(report.whitelistHits)
        }
        return (violations, forbiddenLines, hits)
    }

    static func linesContaining(_ pattern: String, in urls: [URL]) -> [String] {
        var result: [String] = []
        for file in urls {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let relative = Self.relativePath(file)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                if line.range(of: pattern, options: .regularExpression) != nil {
                    result.append("\(relative):\(index + 1): \(trimmed)")
                }
            }
        }
        return result
    }

    // MARK: 地基检查

    @Test("仓库根与扫描范围解析正确（扫描前的地基检查）")
    func scanScopeResolves() {
        let marker = Self.repoRoot.appendingPathComponent("QQPlayer/Models/AppearanceTheme.swift")
        #expect(FileManager.default.fileExists(atPath: marker.path), "仓库根解析错了：\(Self.repoRoot.path)")

        let macFiles = UIAccentContract.swiftFiles(under: UIAccentContract.macScanPaths, repoRoot: Self.repoRoot)
        let iosFiles = UIAccentContract.swiftFiles(under: UIAccentContract.iosViewScanPaths, repoRoot: Self.repoRoot)
        #expect(macFiles.count >= 40, "macOS 扫描范围文件数异常：\(macFiles.count)")
        #expect(iosFiles.count >= 40, "iOS 视图扫描范围文件数异常：\(iosFiles.count)")
    }

    // MARK: 契约自证有效（合成源码）

    @Test("合成违规源码必须被抓到（契约自证有效的关键用例）")
    func syntheticViolationsAreCaught() {
        let macSnippets = [
            ".foregroundStyle(selected ? Color.accentColor : Color.secondary)",
            ".fill(Color.accentColor.opacity(0.12))",
            ".foregroundStyle(selected ? .accentColor : .secondary)",
        ]
        for snippet in macSnippets {
            let source = ["import SwiftUI", "", "struct V: View {", "    var body: some View {", snippet, "    }", "}"].joined(separator: "\n")
            let report = UIAccentContract.scan(source: source, filePath: "QQPlayer/Mac/MacTmp.swift", rules: [UIAccentContract.macSystemAccentRule])
            #expect(report.violations.count == 1, "\(snippet) 应被抓到，实际：\(report.violations)")
            #expect(report.violations.first?.contains("QQPlayer/Mac/MacTmp.swift:5:") == true, "违规行应带行号：\(report.violations)")
        }

        let iosSource = [
            "import SwiftUI",
            "struct V: View {",
            "    @State private var settings = DeleteSettings.load()",
            "    var body: some View {",
            "        Text(\"a\").foregroundColor(IOSAppearance.accentColor(forKey: settings.accentColorName))",
            "    }",
            "}",
        ].joined(separator: "\n")
        let iosReport = UIAccentContract.scan(source: iosSource, filePath: "QQPlayer/Views/Tmp.swift", rules: [UIAccentContract.iosDirectReadRule])
        #expect(iosReport.violations.count == 1, "iOS 直读应被抓到，实际：\(iosReport.violations)")

        let macReadSource = "    @State private var accentColor: Color = MacAppearance.accentColor(forKey: DeleteSettings.load().accentColorName)"
        let readReport = UIAccentContract.scan(source: macReadSource, filePath: "QQPlayer/Mac/MacTmp.swift", rules: [UIAccentContract.macAccentReadRule])
        #expect(readReport.violations.count == 1, "窗口里自读 accentColorName 应被抓到，实际：\(readReport.violations)")
    }

    @Test("合成合法源码不报（环境值读取 / 唯一入口 / 设置页读写 / 注释 / 无关颜色）")
    func syntheticLegalSourceIsClean() {
        let source = [
            "import SwiftUI",
            "struct V: View {",
            "    @Environment(\\.appAccentColor) private var accentColor",
            "    @State private var accentColor: Color = MacAppearance.currentAccentColor",
            "    let preset = MacAppearance.accentColor(forKey: key)",
            "    var body: some View {",
            "        Text(\"a\").foregroundStyle(accentColor)",
            "        Text(\"b\").tint(.red)",
            "        Text(Localized.accentColor)",
            "        // 反例说明：不要写 Color.accentColor",
            "        /// 反例说明：不要写 settings.accentColorName",
            "    }",
            "}",
            "struct W: View {",
            "    let isSelected = deleteSettings.accentColorName == preset.key",
            "    var body: some View { Text(\"c\") }",
            "}",
        ].joined(separator: "\n")
        // 按端分开扫：规则分端靠**扫描范围**（Views/** vs Mac/**），不靠正则——
        // iOS 规则的模式是「字段名」，拿它扫 Mac 文件会把 Mac 设置页那行误判成违规。
        let report = UIAccentContract.scan(
            source: source,
            filePath: "QQPlayer/Mac/MacSettingsView.swift",
            rules: [UIAccentContract.macSystemAccentRule, UIAccentContract.macAccentReadRule]
        )
        let settingsWhitelisted = report.whitelistHits.contains("\(UIAccentContract.macAccentReadRule.name)|1")
        #expect(report.violations.isEmpty, "\(report.violations)")
        #expect(settingsWhitelisted, "设置页那行应命中白名单（证明白名单匹配的是行内容而非只按文件）")

        // 同一份合成源码换成 Views 路径 + iOS 规则：设置页读那行应走 iOS 规则白名单
        let iosReport = UIAccentContract.scan(
            source: source,
            filePath: "QQPlayer/Views/Utility/SettingsView.swift",
            rules: [UIAccentContract.iosDirectReadRule]
        )
        #expect(iosReport.violations.isEmpty, "iOS 规则扫 Views 范围时应放行设置页读写：\(iosReport.violations)")
        #expect(iosReport.whitelistHits.contains("\(UIAccentContract.iosDirectReadRule.name)|0"),
                "设置页读那行应命中 iOS 规则白名单：\(iosReport.whitelistHits)")
    }

    // MARK: 真实源码扫描

    @Test("macOS 无 Color.accentColor（白名单外出现即红）")
    func macHasNoNakedSystemAccent() {
        let files = UIAccentContract.swiftFiles(under: UIAccentContract.macScanPaths, repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [UIAccentContract.macSystemAccentRule])
        #expect(result.forbiddenLines > 0, "扫描没匹配到任何 .accentColor = 规则空转（模式或路径写错了）")
        #expect(result.violations.isEmpty, "macOS 出现 Color.accentColor（改读 @Environment(\\.appAccentColor)，或补白名单说明理由）：\n\(result.violations.joined(separator: "\n"))")
    }

    @Test("iOS 视图层无直读 accentColorName（配色字段唯一入口）")
    func iosViewsHaveNoDirectSettingsRead() {
        let files = UIAccentContract.swiftFiles(under: UIAccentContract.iosViewScanPaths, repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [UIAccentContract.iosDirectReadRule])
        #expect(result.violations.isEmpty, "iOS 视图直读强调色设置（改读 @Environment(\\.appAccentColor)）：\n\(result.violations.joined(separator: "\n"))")

        // 规则非空转：同一模式在注入点（ContentView）确实命中（否则是模式/路径写错了）
        let injection = Self.repoRoot.appendingPathComponent(UIAccentContract.iosInjectionFile)
        let injectionResult = Self.scanFiles([injection], rules: [UIAccentContract.iosDirectReadRule])
        #expect(injectionResult.forbiddenLines > 0, "扫描没匹配到任何 accentColorName = 规则空转")
    }

    @Test("macOS 当前强调色读取点唯一（MacAppearance + 设置页）")
    func macAccentReadIsSingleSourced() {
        let files = UIAccentContract.swiftFiles(under: UIAccentContract.macScanPaths, repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [UIAccentContract.macAccentReadRule])
        #expect(result.forbiddenLines > 0, "扫描没匹配到任何 accentColorName = 规则空转")
        #expect(result.violations.isEmpty, "窗口/视图自读 accentColorName（改读 MacAppearance.currentAccentColor / currentAccentKey）：\n\(result.violations.joined(separator: "\n"))")
    }

    @Test("白名单没有腐烂：每条都还在真实源码里命中")
    func whitelistEntriesAreAllLive() {
        let macFiles = UIAccentContract.swiftFiles(under: UIAccentContract.macScanPaths, repoRoot: Self.repoRoot)
        let iosFiles = UIAccentContract.swiftFiles(under: UIAccentContract.iosViewScanPaths, repoRoot: Self.repoRoot)
        let rules = [UIAccentContract.macSystemAccentRule, UIAccentContract.iosDirectReadRule, UIAccentContract.macAccentReadRule]
        let result = Self.scanFiles(macFiles + iosFiles, rules: rules)
        let expected = rules.flatMap { rule in
            rule.whitelist.indices.map { "\(rule.name)|\($0)" }
        }
        let dead = expected.filter { !result.hits.contains($0) }
        #expect(dead.isEmpty, "白名单条目已不再命中（代码改了 → 条目要同步删/改）：\n\(dead.joined(separator: "\n"))")
    }

    // MARK: 唯一入口（形状：这件事只有一处实现）

    @Test("hex→Color 解析唯一：全仓只有一处 init(hex:) 声明，且没有第二套 color(hex:)")
    func hexParsingHasExactlyOneImplementation() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        let initHexDeclarations = Self.linesContaining(#"init\(hex:"#, in: files)
        let otherHexHelpers = Self.linesContaining(#"func color\(hex:|init\(hexValue:"#, in: files)

        #expect(initHexDeclarations.count == 1, "hex→Color 解析必须只有一处（唯一入口 Models/AppearanceTheme.swift）：\n\(initHexDeclarations.joined(separator: "\n"))")
        #expect(initHexDeclarations.first?.contains("QQPlayer/Models/AppearanceTheme.swift") == true, "唯一实现应在共享文件里（iOS/macOS 都要能用）：\(initHexDeclarations)")
        #expect(otherHexHelpers.isEmpty, "出现第二套 hex→Color 构造（应改为调用 Color(hex:)）：\n\(otherHexHelpers.joined(separator: "\n"))")
    }

    @Test("强调色环境值只有一处定义，且 iOS 注入点唯一")
    func accentEnvironmentValueHasExactlyOneDefinition() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        let definitions = Self.linesContaining(#"var appAccentColor: Color \{"#, in: files)
        #expect(definitions.count == 1, "环境值定义必须唯一：\n\(definitions.joined(separator: "\n"))")
        #expect(definitions.first?.hasPrefix("QQPlayer/Models/AppearanceTheme.swift") == true, "唯一定义应在共享文件里：\(definitions)")

        // iOS 注入点唯一（= ContentView）；macOS 侧文件（`Mac/**` 与 App 入口 QQPlayerMacApp.swift）
        // 与 Views/** 里的预览注入（.environment(\.appAccentColor, …)）都是各自合法的 seam，不算 iOS 注入点
        let injectionLines = Self.linesContaining(#"\.environment\(\\\.appAccentColor,"#, in: files)
        let iosInjections = injectionLines.filter {
            !$0.hasPrefix("QQPlayer/Mac/")
                && !$0.hasPrefix("QQPlayer/QQPlayerMacApp.swift")
                && !$0.hasPrefix("QQPlayer/Views/")
        }
        #expect(iosInjections.count == 1, "iOS 强调色注入点必须唯一（目前 = ContentView）：\(iosInjections)")
        #expect(iosInjections.first?.hasPrefix(UIAccentContract.iosInjectionFile) == true, "iOS 注入点应是 App 根 ContentView：\(iosInjections)")
    }

    @Test("配色设置字段唯一：两端设置页写的是同一个字段，且字段声明只有一处")
    func colorSettingFieldIsSingleAcrossPlatforms() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)

        // 字段声明唯一（旧 iOS 字段 backgroundColorChoice 已退役，正则见 retiredColorFieldRule）
        let declarations = Self.linesContaining(#"var accentColorName\s*:"#, in: files)
        #expect(declarations.count == 1, "配色设置字段声明必须唯一：\n\(declarations.joined(separator: "\n"))")
        #expect(declarations.first?.hasPrefix("QQPlayer/Models/SettingsModels.swift") == true, "字段应定义在共享设置模型里：\(declarations)")

        // 写点：iOS 设置页 / macOS 设置页各一处，写的都是同一个字段名（`[^=]` 排除 `==` 比较）
        let writes = Self.linesContaining(#"(?:deleteSettings|settings)\.accentColorName\s*=[^=]"#, in: files)
        #expect(writes.count == 2, "配色写点应只有两处（iOS / macOS 设置页）：\n\(writes.joined(separator: "\n"))")
        #expect(writes.contains { $0.hasPrefix("QQPlayer/Views/Utility/SettingsView.swift") }, "iOS 设置页应写 accentColorName：\(writes)")
        #expect(writes.contains { $0.hasPrefix("QQPlayer/Mac/MacSettingsView.swift") }, "macOS 设置页应写 accentColorName：\(writes)")
    }

    @Test("已退役的配色字段不得复活（唯一配色字段 = accentColorName）")
    func retiredColorFieldDoesNotComeBack() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [UIAccentContract.retiredColorFieldRule])
        #expect(result.forbiddenLines > 0, "扫描没匹配到任何 backgroundColorChoice = 规则空转（模式或路径写错了）")
        #expect(result.violations.isEmpty, "旧配色字段复活（唯一字段是 accentColorName）：\n\(result.violations.joined(separator: "\n"))")
        #expect(result.hits.count == UIAccentContract.retiredColorFieldRule.whitelist.count,
                "旧字段白名单条目没全部命中（代码改了 → 条目要同步改）：\(result.hits)")
    }
}

// MARK: - 几何 / 排版令牌测试（B2a 2026-09-15）

struct UIGeometryContractTests {
    static let repoRoot = UIAccentContractTests.repoRoot

    static var tokenFileURL: URL {
        repoRoot.appendingPathComponent("QQPlayer/Models/AppearanceTheme.swift")
    }

    /// 源码里出现的所有 `DesignTokens.<名>`（同一行多个也全取；注释行不计）
    static func tokenNames(in urls: [URL]) -> [String] {
        var names: [String] = []
        for url in urls {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in source.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                var searchRange = line.startIndex ..< line.endIndex
                while let range = line.range(
                    of: #"DesignTokens\.[A-Za-z0-9_]+"#, options: .regularExpression, range: searchRange
                ) {
                    names.append(String(line[range].dropFirst("DesignTokens.".count)))
                    searchRange = range.upperBound ..< line.endIndex
                }
            }
        }
        return names
    }

    @Test("令牌表自洽：名字编码的值 == 定义值，且与代码引用一一对应")
    func tokenTableIsSelfConsistentAndFullyReferenced() throws {
        let source = try String(contentsOf: Self.tokenFileURL, encoding: .utf8)
        let tokens = UIGeometryContract.parseTokens(source: source)
        let radiusTokens = tokens.filter { $0.name.hasPrefix("radius") }
        let fontTokens = tokens.filter { $0.name.hasPrefix("font") }
        let spaceTokens = tokens.filter { $0.name.hasPrefix("space") }
        #expect(radiusTokens.count >= 11, "圆角令牌数异常（B2b 归一后 11 种）：\(radiusTokens.count)")
        #expect(fontTokens.count >= 24, "字号令牌数异常（B2b 归一后 24 种）：\(fontTokens.count)")
        #expect(spaceTokens.count >= 33, "间距令牌数异常（B2c-a 实测 33 种）：\(spaceTokens.count)")

        let inconsistent = UIGeometryContract.selfInconsistent(tokens)
        #expect(inconsistent.isEmpty, "令牌名与值不自洽（拼错名 = 值静默变成另一个数）：\n\(inconsistent.joined(separator: "\n"))")

        let defined = Set(tokens.map(\.name))
        let referenced = Set(Self.tokenNames(in: UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)))
        #expect(
            defined == referenced,
            """
            定义与引用不一致。
            只定义没引用（死令牌 / 解析漏了）：\(defined.subtracting(referenced).sorted())
            引用了没定义（拼错名）：\(referenced.subtracting(defined).sorted())
            """
        )
    }

    /// B2b 2026-09-16 归一后的**目标刻度集合**（归一验收物：刻度只能少、不能再长出零散值）。
    /// 圆角：15 种 → 11 种（`0.5→0`、`5→4`、`7→6`、`14→12`、`25→24`）。
    /// 字号：26 种 → 24 种（`11→12`、`12.5→12`，用户拍板方案 B）。
    /// 改动刻度必须同时改本断言——这是「归一没被新零散值静默回退」的唯一兜底。
    static let expectedRadiusNames: Set<String> = [
        "radius0", "radius2", "radius4", "radius6", "radius8", "radius10",
        "radius12", "radius16", "radius20", "radius24", "radius28",
    ]
    static let expectedFontNames: Set<String> = [
        "font8", "font9", "font12", "font13", "font14", "font15", "font16", "font17",
        "font18", "font19", "font20", "font22", "font24", "font26", "font30", "font32",
        "font36", "font40", "font44", "font50", "font52", "font60", "font64", "font70",
    ]

    @Test("归一后刻度集合 == 预期集合（圆角 11 种 / 字号 24 种，B2b 验收物）")
    func normalizedScaleMatchesExpectedSet() throws {
        let source = try String(contentsOf: Self.tokenFileURL, encoding: .utf8)
        let tokens = UIGeometryContract.parseTokens(source: source)
        let radius = Set(tokens.map(\.name).filter { $0.hasPrefix("radius") })
        let font = Set(tokens.map(\.name).filter { $0.hasPrefix("font") })

        #expect(
            radius == Self.expectedRadiusNames,
            """
            圆角刻度与归一验收物不一致。
            多出（又长回零散值 / 忘了删旧令牌）：\(radius.subtracting(Self.expectedRadiusNames).sorted())
            缺失（被误删）：\(Self.expectedRadiusNames.subtracting(radius).sorted())
            """
        )
        #expect(
            font == Self.expectedFontNames,
            """
            字号刻度与归一验收物不一致。
            多出（又长回零散值 / 忘了删旧令牌）：\(font.subtracting(Self.expectedFontNames).sorted())
            缺失（被误删）：\(Self.expectedFontNames.subtracting(font).sorted())
            """
        )
    }

    @Test("合成源码：裸值 / 字面量运算必须被抓到，令牌 / 变量 / 比例常数 / 注释不误报")
    func syntheticNakedLiteralsAreCaughtAndLegalFormsAreNot() {
        var lines = ["import SwiftUI", "struct Tmp: View {", "    var body: some View {"]
        var expected: [Int] = []
        /// 追加一行；`violating: true` 表示这行必须被判违规（行号自动记录，避免手写行号漂移）
        func add(_ line: String, violating: Bool = false) {
            lines.append(line)
            if violating { expected.append(lines.count) }
        }
        // 该抓：裸字面量
        add("        RoundedRectangle(cornerRadius: 12)", violating: true)
        add("        RoundedRectangle(cornerRadius: 12.5)", violating: true)
        add("        RoundedRectangle(cornerRadius: 8, style: .continuous)", violating: true)
        add("        Color.clear.cornerRadius(6)", violating: true)
        add("        Text(\"a\").font(.system(size: 12))", violating: true)
        add("        Text(\"b\").font(.system(size: 12.5, weight: .semibold))", violating: true)
        // 该抓：字面量参与运算（B2a 补的形态）
        add("        Text(\"f\").font(.system(size: 17 * scale, weight: .medium))", violating: true)
        add("        RoundedRectangle(cornerRadius: 8 * scale)", violating: true)
        // 不该抓：令牌 / 令牌参与运算 / 变量 / 比例常数 / 注释
        add("        RoundedRectangle(cornerRadius: DesignTokens.radius12)")
        add("        Color.clear.cornerRadius(DesignTokens.radius6)")
        add("        Text(\"c\").font(.system(size: DesignTokens.font12))")
        add("        Text(\"g\").font(.system(size: DesignTokens.font17 * scale, weight: .medium))")
        add("        RoundedRectangle(cornerRadius: DesignTokens.radius8 * scale)")
        add("        RoundedRectangle(cornerRadius: cornerRadius)")
        add("        RoundedRectangle(cornerRadius: cornerRadius * scale)")
        add("        Path(roundedRect: rect, cornerRadius: barWidth / 2)")
        add("        Text(\"d\").font(.system(size: fontSize))")
        add("        Text(\"e\").font(.system(size: size * scale))")
        add("        Text(\"h\").font(.system(size: base / 2))")
        add("        Text(\"i\").font(.system(size: fontSize * 0.45))")
        add("        Text(\"j\").font(.system(size: min(80, size * 0.2)))")
        add("        // 反例说明：不要写 cornerRadius: 12 / .system(size: 17 * scale)")
        add("    }")
        add("}")

        let report = UIAccentContract.scan(
            source: lines.joined(separator: "\n"),
            filePath: "QQPlayer/Views/Tmp.swift",
            rules: UIGeometryContract.allRules
        )
        #expect(
            report.violations.count == expected.count,
            "应恰好抓到 \(expected.count) 处，实际 \(report.violations.count)：\n\(report.violations.joined(separator: "\n"))"
        )
        for line in expected {
            #expect(
                report.violations.contains { $0.hasPrefix("QQPlayer/Views/Tmp.swift:\(line):") },
                "第 \(line) 行应被抓到：\(report.violations)"
            )
        }
    }

    @Test("真实源码无裸圆角 / 裸字号字面量（白名单为空，fail-closed）")
    func appSourcesHaveNoNakedGeometryLiterals() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        #expect(files.count >= 250, "扫描范围异常（B2a 实测 QQPlayer/** 301 个 .swift）：\(files.count)")
        #expect(files.contains(Self.tokenFileURL), "令牌定义文件不在扫描范围内：\(Self.tokenFileURL.path)")

        // 非空转佐证：迁移后这些文件里应有成百条令牌引用（B2a 实测 267 条：圆角 152 + 字号 115）
        let references = Self.tokenNames(in: files)
        #expect(references.count >= 200, "源码里的令牌引用过少（\(references.count) 条）= 迁移被整体回退或扫描范围写错")

        let result = UIAccentContractTests.scanFiles(
            files,
            rules: UIGeometryContract.allRules
        )
        #expect(
            result.violations.isEmpty,
            "出现裸几何 / 字号字面量（改用 DesignTokens.radius* / font*；确属合法的补白名单并写明理由）：\n\(result.violations.joined(separator: "\n"))"
        )
    }
}

// MARK: - 间距令牌测试（B2c-a 2026-09-16）

struct UISpacingContractTests {
    static let repoRoot = UIAccentContractTests.repoRoot

    static var tokenFileURL: URL {
        repoRoot.appendingPathComponent("QQPlayer/Models/AppearanceTheme.swift")
    }

    /// 源码里出现的所有 `DesignTokens.space*`（注释行不计；令牌定义行本身不含 `DesignTokens.` 前缀）
    static func spaceTokenNames(in urls: [URL]) -> [String] {
        UIGeometryContractTests.tokenNames(in: urls).filter { $0.hasPrefix("space") }
    }

    @Test("合成源码：裸间距字面量必被抓到，令牌 / 空参 / 仅边 / 变量 / 表达式 / 声明 / 注释不误报")
    func syntheticNakedSpacingLiteralsAreCaughtAndLegalFormsAreNot() {
        var lines = ["import SwiftUI", "struct Tmp: View {", "    var body: some View {"]
        /// 行号 -> 该行应被抓到的处数（行号自动记录，避免手写行号漂移）
        /// 扫描器粒度 = **每行每条规则最多一条违规**（与强调色/几何契约同一套 `scan`），
        /// 故同一行里同规则的多处命中只计 1。
        var expected: [Int: Int] = [:]
        func add(_ line: String, violating: Int = 0) {
            lines.append(line)
            if violating > 0 { expected[lines.count] = violating }
        }
        // 该抓：裸字面量（B2c-a 迁移前全仓实测 33 种取值里的代表形态）
        add("        Text(\"a\").padding(8)", violating: 1)
        add("        Text(\"b\").padding(1.5)", violating: 1)
        add("        Text(\"c\").padding(.horizontal, 16)", violating: 1)
        add("        Text(\"d\").padding(.top, 4)", violating: 1)
        add("        VStack(spacing: 8) { Text(\"e\") }", violating: 1)
        add("        VStack(alignment: .leading, spacing: 12) {", violating: 1)
        add("        HStack(alignment: .center, spacing: 16, content: { Text(\"f\") })", violating: 1)
        add("        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {", violating: 1)
        add("        let cells = [GridItem(.flexible(), spacing: 20)]", violating: 1)
        add("        Grid(horizontalSpacing: 8, verticalSpacing: 12) {", violating: 1)   // 扫描粒度=每行每规则一条，故记 1
        add("        Spacer(minLength: 0)", violating: 1)
        add("        Spacer(minLength: 24),", violating: 1)
        // 该抓：多行写法——值单独一行（`spacing:` 后紧跟数字）
        add("        LazyVGrid(")
        add("            spacing: 16,", violating: 1)
        add("            content: { Text(\"g\") }")
        add("        )")
        // 该抓：实参开头的字面量参与运算（规则 5）
        add("        Text(\"h\").padding(8 * scale)", violating: 1)
        add("        VStack(spacing: 12 * scale) { Text(\"i\") }", violating: 1)
        add("        Spacer(minLength: 8 * scale)", violating: 1)
        // 不该抓：令牌 / 空参 / 仅边 / 变量 / 表达式 / 声明 / 比例常数 / 注释
        add("        Text(\"j\").padding()")
        add("        Text(\"k\").padding(.horizontal)")
        add("        Text(\"l\").padding(DesignTokens.space8)")
        add("        Text(\"m\").padding(.horizontal, DesignTokens.space16)")
        add("        VStack(spacing: DesignTokens.space8) { Text(\"n\") }")
        add("        VStack(spacing: spacing) { Text(\"o\") }")
        add("        VStack(spacing: Self.spacing) { Text(\"p\") }")
        add("        let gridSpacing = SmartPlaylistGridLayout.spacing")
        add("        Text(\"q\").padding(size * 0.5)")
        add("        Text(\"r\").padding(DesignTokens.space8 * scale)")
        add("        Text(\"s\").padding(compact ? 20 : 44)")
        add("        Text(\"t\").padding(.vertical, karaoke.isKaraokeOn ? 18 : (isActive ? 24 : 16))")
        add("        Text(\"u\").padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))")
        add("        Text(\"v\").padding(.horizontal, Self.horizontalPadding)")
        add("        Text(\"w\").padding(.vertical, LyricLineEmphasis.linePadding(emphasis, karaoke: isKaraoke))")
        add("        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {")
        add("        Spacer(minLength: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20)")
        add("        Spacer(minLength: other)")
        add("        let spacing: CGFloat = 2")
        add("        private static let spacing: CGFloat = 12")
        add("        private static var spacing: CGFloat { SmartPlaylistGridLayout.spacing }")
        add("        func f(spacing: CGFloat = spacing) {}")
        add("        // 反例说明：不要写 .padding(8) / VStack(spacing: 8)")
        add("        /// 反例说明：不要写 Spacer(minLength: 0)")
        add("    }")
        add("}")

        let report = UIAccentContract.scan(
            source: lines.joined(separator: "\n"),
            filePath: "QQPlayer/Views/Tmp.swift",
            rules: UISpacingContract.allRules
        )
        let expectedTotal = expected.values.reduce(0, +)
        #expect(
            report.violations.count == expectedTotal,
            "应恰好抓到 \(expectedTotal) 处，实际 \(report.violations.count)：\n\(report.violations.joined(separator: "\n"))"
        )
        for (line, count) in expected {
            let hits = report.violations.filter { $0.hasPrefix("QQPlayer/Views/Tmp.swift:\(line):") }
            #expect(hits.count == count, "第 \(line) 行应抓到 \(count) 处，实际 \(hits.count)：\(report.violations)")
        }
    }

    @Test("真实源码无裸间距字面量（白名单为空，fail-closed）")
    func appSourcesHaveNoNakedSpacingLiterals() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        #expect(files.count >= 250, "扫描范围异常（B2a 实测 QQPlayer/** 301 个 .swift）：\(files.count)")
        #expect(files.contains(Self.tokenFileURL), "令牌定义文件不在扫描范围内：\(Self.tokenFileURL.path)")

        // 非空转佐证：迁移后全仓应有 ≈829 条 DesignTokens.space* 引用（B2c-a 实测 829 处）
        let references = Self.spaceTokenNames(in: files)
        #expect(
            references.count >= UISpacingContract.minimumReferenceCount,
            "源码里的间距令牌引用过少（\(references.count) 条）= 迁移被整体回退或扫描范围写错"
        )

        let result = UIAccentContractTests.scanFiles(files, rules: UISpacingContract.allRules)
        #expect(
            result.violations.isEmpty,
            "出现裸间距字面量（改用 DesignTokens.space*；确属合法的补白名单并写明理由）：\n\(result.violations.joined(separator: "\n"))"
        )
    }

    @Test("间距令牌名 ↔ 值自洽，且每条都被引用（防拼错名静默改值 / 防死令牌）")
    func spacingTokenTableIsSelfConsistentAndFullyReferenced() throws {
        let source = try String(contentsOf: Self.tokenFileURL, encoding: .utf8)
        let tokens = UIGeometryContract.parseTokens(source: source).filter { $0.name.hasPrefix("space") }
        #expect(tokens.count >= 33, "间距令牌数异常（B2c-a 实测 33 种）：\(tokens.count)")

        let inconsistent = UIGeometryContract.selfInconsistent(tokens)
        #expect(
            inconsistent.isEmpty,
            "间距令牌名与值不自洽（拼错名 = 值静默变成另一个间距，编译器与截图都发现不了）：\n\(inconsistent.joined(separator: "\n"))"
        )

        let referenced = Set(Self.spaceTokenNames(in: UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)))
        let dead = tokens.map(\.name).filter { !referenced.contains($0) }
        #expect(dead.isEmpty, "只定义没引用的间距令牌（死令牌，或某处迁移漏做）：\(dead.sorted())")
    }
}
