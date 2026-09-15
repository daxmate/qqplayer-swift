//
//  UIAccentContractTests.swift
//  QQPlayerTests
//
//  强调色「防裸用」形状契约（2026-09-15 UI 设计令牌 B1，见 docs/ui-design-tokens.md §5）。
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

    /// 规则 2：iOS 视图不得直读设置里的强调色。
    /// 注入点在 App 根（ContentView），视图统一读 `@Environment(\.appAccentColor)`。
    static let iosDirectReadRule = Rule(
        name: "iOS 视图读环境值 appAccentColor，不得直读 settings.backgroundColorChoice.color",
        pattern: #"backgroundColorChoice\.color"#,
        whitelist: [
            // 注入点 ContentView.swift 与其它非视图消费点（锁屏 Now Playing 取 hex、
            // iCloud 备份取 rawValue）都不在 Views/** 扫描范围内，故无条目。
        ]
    )

    /// 规则 3：macOS 「当前强调色」只能有一处读取（M2）。
    /// 允许读 `accentColorName` 的只有两者：`MacAppearance`（取值唯一入口）与
    /// `MacSettingsView`（设置页本身要读/写这个字段）。窗口/视图里再自读就是第二条路径。
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
    /// 这种语义错的令牌。残余（实参非开头处的尺寸字面量：三元分支 `? 22 : 19`、`min(80, …)` 的 80 等）
    /// 列在 docs/ui-design-tokens.md §3 M4，归 B2b。
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
            guard name.hasPrefix("radius") || name.hasPrefix("font") else { continue }
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
            "        Text(\"a\").foregroundColor(settings.backgroundColorChoice.color)",
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
            "        /// 反例说明：不要写 settings.backgroundColorChoice.color",
            "    }",
            "}",
            "struct W: View {",
            "    let isSelected = deleteSettings.accentColorName == preset.key",
            "    var body: some View { Text(\"c\") }",
            "}",
        ].joined(separator: "\n")
        let report = UIAccentContract.scan(
            source: source,
            filePath: "QQPlayer/Mac/MacSettingsView.swift",
            rules: [UIAccentContract.macSystemAccentRule, UIAccentContract.iosDirectReadRule, UIAccentContract.macAccentReadRule]
        )
        let settingsWhitelisted = report.whitelistHits.contains("\(UIAccentContract.macAccentReadRule.name)|1")
        #expect(report.violations.isEmpty, "\(report.violations)")
        #expect(settingsWhitelisted, "设置页那行应命中白名单（证明白名单匹配的是行内容而非只按文件）")
    }

    // MARK: 真实源码扫描

    @Test("macOS 无 Color.accentColor（白名单外出现即红）")
    func macHasNoNakedSystemAccent() {
        let files = UIAccentContract.swiftFiles(under: UIAccentContract.macScanPaths, repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [UIAccentContract.macSystemAccentRule])
        #expect(result.forbiddenLines > 0, "扫描没匹配到任何 .accentColor = 规则空转（模式或路径写错了）")
        #expect(result.violations.isEmpty, "macOS 出现 Color.accentColor（改读 @Environment(\\.appAccentColor)，或补白名单说明理由）：\n\(result.violations.joined(separator: "\n"))")
    }

    @Test("iOS 视图层无直读 backgroundColorChoice.color")
    func iosViewsHaveNoDirectSettingsRead() {
        let files = UIAccentContract.swiftFiles(under: UIAccentContract.iosViewScanPaths, repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [UIAccentContract.iosDirectReadRule])
        #expect(result.violations.isEmpty, "iOS 视图直读强调色设置（改读 @Environment(\\.appAccentColor)）：\n\(result.violations.joined(separator: "\n"))")

        // 规则非空转：同一模式在注入点（ContentView）确实命中（否则是模式/路径写错了）
        let injection = Self.repoRoot.appendingPathComponent(UIAccentContract.iosInjectionFile)
        let injectionResult = Self.scanFiles([injection], rules: [UIAccentContract.iosDirectReadRule])
        #expect(injectionResult.forbiddenLines > 0, "扫描没匹配到任何 backgroundColorChoice.color = 规则空转")
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
        #expect(radiusTokens.count >= 15, "圆角令牌数异常（B2a 实测 15 种）：\(radiusTokens.count)")
        #expect(fontTokens.count >= 26, "字号令牌数异常（B2a 实测 26 种）：\(fontTokens.count)")

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
