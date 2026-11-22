//
//  AppAppearanceStyleTests.swift
//  QQPlayerTests
//
//  显示风格（毛玻璃 / 经典）的纯逻辑 + 形状契约（不依赖 UI / 模拟器截图）：
//    1. 三态解析：未写过 = 毛玻璃（默认，fail-closed）/ true = 毛玻璃 / false = 经典
//    2. 与既有 key 的一致性：唯一持久化仍是 `qqplayer.playerGlassBackground`（true = glass）
//    3. `PlayerGlassBackground` 薄封装与 `AppAppearanceStyle` 永远一致（旧调用点不用改名）
//    4. 形状：全仓只有一处「风格生效吗」的实现，装饰底在玻璃风格下让位
//
//  为什么用静态形状契约：这类问题（又写一套读 key 的判定 / 装饰底不让位）不改任何行为，
//  行为测试测不到；照 `UIAccentContract` 的写法复用同一套扫描函数（不另造扫描器）。
//

import Foundation
@testable import QQPlayer
import Testing

// MARK: - 纯逻辑

struct AppAppearanceStyleTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppAppearanceStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("未写过该键 = 毛玻璃（默认风格，fail-closed）")
    func defaultIsGlass() {
        let defaults = makeDefaults()

        #expect(AppAppearanceStyle.current(defaults) == .glass)
        // 默认值只有一份：与 `PlayerGlassBackground.enabledByDefault` 同源，不能各写一套
        #expect(AppAppearanceStyle(glassEnabled: PlayerGlassBackground.enabledByDefault) == .glass)
    }

    @Test("写 true = 毛玻璃，写 false = 经典（与既有 key 一致）")
    func explicitValuesWin() {
        let defaults = makeDefaults()

        defaults.set(true, forKey: PlayerGlassBackground.storageKey)
        #expect(AppAppearanceStyle.current(defaults) == .glass)

        defaults.set(false, forKey: PlayerGlassBackground.storageKey)
        #expect(AppAppearanceStyle.current(defaults) == .classic)
    }

    @Test("store 往返一致，且写的仍是同一个 key")
    func storeRoundTripsOnSameKey() {
        let defaults = makeDefaults()

        AppAppearanceStyle.store(.classic, in: defaults)
        #expect(defaults.bool(forKey: PlayerGlassBackground.storageKey) == false)
        #expect(AppAppearanceStyle.current(defaults) == .classic)

        AppAppearanceStyle.store(.glass, in: defaults)
        #expect(defaults.bool(forKey: PlayerGlassBackground.storageKey) == true)
        #expect(AppAppearanceStyle.current(defaults) == .glass)

        #expect(AppAppearanceStyle.glass.glassEnabled)
        #expect(!AppAppearanceStyle.classic.glassEnabled)
    }

    @Test("PlayerGlassBackground.isEnabled 薄封装与风格判定永远一致")
    func legacyWrapperAgreesWithStyle() {
        let defaults = makeDefaults()

        #expect(PlayerGlassBackground.isEnabled(defaults) == (AppAppearanceStyle.current(defaults) == .glass))

        AppAppearanceStyle.store(.classic, in: defaults)
        #expect(PlayerGlassBackground.isEnabled(defaults) == false)
        #expect(PlayerGlassBackground.isActive(isEnabled: PlayerGlassBackground.isEnabled(defaults), hasArtwork: true, reduceTransparency: false) == false)

        AppAppearanceStyle.store(.glass, in: defaults)
        #expect(PlayerGlassBackground.isEnabled(defaults) == true)
        #expect(PlayerGlassBackground.isActive(isEnabled: PlayerGlassBackground.isEnabled(defaults), hasArtwork: true, reduceTransparency: false) == true)
    }

    @Test("降低透明度 → 回落经典（持久化不受影响）")
    func reduceTransparencyFallsBackToClassic() {
        let defaults = makeDefaults()
        AppAppearanceStyle.store(.glass, in: defaults)

        #expect(AppAppearanceStyle.resolved(stored: .glass, reduceTransparency: true) == .classic)
        #expect(AppAppearanceStyle.resolved(stored: .glass, reduceTransparency: false) == .glass)
        #expect(AppAppearanceStyle.resolved(stored: .classic, reduceTransparency: false) == .classic)
        // 回落只影响「生效」，不改用户选的值
        #expect(AppAppearanceStyle.current(defaults) == .glass)
    }
}

// SCAN-BEGIN —— 纯逻辑（只用 Foundation 字符串 API，不碰文件系统）

enum AppAppearanceContract {
    /// 规则 1：key 字面量只允许出现在唯一持久化声明处（`PlayerGlassSetting.swift`）。
    /// 别处再写一遍字面量 = 第二份持久化语义（改 key 时只改一处，另一处静默读不到）。
    static let storageKeyLiteralRule = UIAccentContract.Rule(
        name: "显示风格 key 字面量只允许在 PlayerGlassSetting.swift（唯一持久化）",
        pattern: #"qqplayer\.playerGlassBackground"#,
        whitelist: [
            UIAccentContract.WhitelistEntry(
                fileSuffix: "QQPlayer/Models/PlayerGlassSetting.swift",
                lineSnippet: #"static let storageKey = "qqplayer.playerGlassBackground""#,
                reason: "唯一 key 声明处（persistence 语义只此一份）"
            ),
        ]
    )

    /// 规则 2：不得再用 `bool(forKey:)` 直读该 key 判风格（唯一判定 = `AppAppearanceStyle`）。
    /// `@AppStorage` 绑定（设置页选择器 / 注入点）不算判定，不拦。
    static let directStyleReadRule = UIAccentContract.Rule(
        name: "风格判定唯一走 AppAppearanceStyle，不得 bool(forKey:) 直读该 key",
        pattern: #"\.bool\(forKey:\s*(?:PlayerGlassBackground\.storageKey|"qqplayer\.playerGlassBackground")"#,
        whitelist: []
    )

    /// 装饰底让位判据：`ScreenSpecificBackgroundView` 的声明段必须读环境值且在玻璃风格下让位。
    /// 纯函数（不碰文件系统）→ 合成源码可正反自证。
    static func decorationViewYieldsToGlass(source: String) -> Bool {
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.contains("struct ScreenSpecificBackgroundView") }) else {
            return false
        }
        // 声明段 = 从 struct 行到下一个**顶格**声明的前一行
        var section: [String] = []
        for line in lines[start...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !section.isEmpty,
               line.hasPrefix("struct ") || line.hasPrefix("enum ") || line.hasPrefix("extension ") || line.hasPrefix("///") {
                break
            }
            section.append(trimmed)
        }
        let body = section.joined(separator: "\n")
        return body.contains("appAppearanceStyle") && body.contains(".glass")
    }
}

// SCAN-END

// MARK: - 形状契约（真实源码）

struct AppAppearanceContractTests {
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

    // MARK: 合成源码自证（防契约空转）

    @Test("合成违规：第二份 key 字面量 / bool(forKey:) 直读必须被抓到")
    func syntheticViolationsAreCaught() {
        let violating = [
            "import Foundation",
            "enum Oops {",
            #"    static let key = "qqplayer.playerGlassBackground""#,
            "    static func isGlass() -> Bool {",
            "        UserDefaults.standard.bool(forKey: PlayerGlassBackground.storageKey)",
            "    }",
            "}",
        ].joined(separator: "\n")

        let literalReport = UIAccentContract.scan(
            source: violating, filePath: "QQPlayer/Views/Oops.swift", rules: [AppAppearanceContract.storageKeyLiteralRule]
        )
        #expect(literalReport.violations.count == 1, "第二份 key 字面量应被抓到：\(literalReport.violations)")

        let readReport = UIAccentContract.scan(
            source: violating, filePath: "QQPlayer/Views/Oops.swift", rules: [AppAppearanceContract.directStyleReadRule]
        )
        #expect(readReport.violations.count == 1, "bool(forKey:) 直读应被抓到：\(readReport.violations)")
    }

    @Test("合成合法：唯一声明处 / 环境值判定 / @AppStorage 绑定都不误报")
    func syntheticLegalSourceIsClean() {
        let legal = [
            "import Foundation",
            "enum PlayerGlassBackground {",
            #"    static let storageKey = "qqplayer.playerGlassBackground""#,
            "}",
            "struct V: View {",
            "    @Environment(\\.appAppearanceStyle) private var appearanceStyle",
            "    @AppStorage(PlayerGlassBackground.storageKey) private var glassEnabled = true",
            "}",
        ].joined(separator: "\n")

        let literalReport = UIAccentContract.scan(
            source: legal, filePath: "QQPlayer/Models/PlayerGlassSetting.swift", rules: [AppAppearanceContract.storageKeyLiteralRule]
        )
        #expect(literalReport.violations.isEmpty, "\(literalReport.violations)")
        #expect(literalReport.whitelistHits == ["\(AppAppearanceContract.storageKeyLiteralRule.name)|0"], "白名单应命中唯一声明处：\(literalReport.whitelistHits)")

        let readReport = UIAccentContract.scan(
            source: legal, filePath: "QQPlayer/ContentView.swift", rules: [AppAppearanceContract.directStyleReadRule]
        )
        #expect(readReport.violations.isEmpty, "\(readReport.violations)")
    }

    @Test("装饰底让位判据自证：有环境值判定 = 让位，没有 = 不让位")
    func decorationYieldPredicateIsNotVacuous() {
        let yielding = [
            "struct ScreenSpecificBackgroundView: View {",
            "    @Environment(\\.appAppearanceStyle) private var appearanceStyle",
            "    var body: some View {",
            "        if appearanceStyle == .glass { Color.clear } else { design }",
            "    }",
            "}",
        ].joined(separator: "\n")
        #expect(AppAppearanceContract.decorationViewYieldsToGlass(source: yielding))

        let notYielding = [
            "struct ScreenSpecificBackgroundView: View {",
            "    var body: some View { design }",
            "}",
        ].joined(separator: "\n")
        #expect(!AppAppearanceContract.decorationViewYieldsToGlass(source: notYielding))
    }

    // MARK: 真实源码

    @Test("显示风格 key 字面量只在唯一持久化声明处")
    func storageKeyLiteralIsSingle() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [AppAppearanceContract.storageKeyLiteralRule])
        #expect(result.forbiddenLines > 0, "扫描没匹配到任何 key 字面量 = 规则空转（模式写错了）")
        #expect(result.violations.isEmpty, "出现第二份 key 字面量（改用 PlayerGlassBackground.storageKey）：\n\(result.violations.joined(separator: "\n"))")
        #expect(result.hits.count == 1, "唯一声明处应命中白名单：\(result.hits)")
    }

    @Test("没有第二处 bool(forKey:) 直读该 key 判风格")
    func noDirectStyleRead() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [AppAppearanceContract.directStyleReadRule])
        #expect(result.violations.isEmpty, "出现第二套风格判定（改走 AppAppearanceStyle / 环境值 appAppearanceStyle）：\n\(result.violations.joined(separator: "\n"))")
    }

    @Test("装饰底在玻璃风格下让位（ScreenSpecificBackgroundView 读环境值）")
    func decorationYieldsToGlass() throws {
        let file = Self.repoRoot.appendingPathComponent("QQPlayer/Views/Utility/BackgroundTextureView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains("struct ScreenSpecificBackgroundView"), "装饰底视图不见了（文件/类型改名？）：\(file.path)")
        #expect(AppAppearanceContract.decorationViewYieldsToGlass(source: source),
                "ScreenSpecificBackgroundView 没在玻璃风格下让位（玻璃会叠上第二层装饰底）")
    }

    @Test("整屏玻璃只有一份实现，装配点 = 根部 + 全屏播放页")
    func glassLayerHasSingleImplementation() {
        let files = UIAccentContract.appSourceFiles(repoRoot: Self.repoRoot)

        let implementations = Self.linesContaining(#"struct IOSWindowGlass:"#, in: files)
        #expect(implementations.count == 1, "整屏玻璃底必须只有一份实现：\n\(implementations.joined(separator: "\n"))")
        #expect(implementations.first?.hasPrefix("QQPlayer/Views/Utility/IOSWindowGlass.swift") == true,
                "唯一实现应在 IOSWindowGlass.swift：\(implementations)")

        let layerImplementations = Self.linesContaining(#"struct IOSWindowGlassLayer:"#, in: files)
        #expect(layerImplementations.count == 1, "装载层必须只有一份实现：\n\(layerImplementations.joined(separator: "\n"))")

        // 装配点：根部 ContentView 一次；播放页是独立 presentation，另一次
        let rootAssemblies = Self.linesContaining(#"IOSWindowGlassLayer\(track:"#, in: [
            Self.repoRoot.appendingPathComponent("QQPlayer/ContentView.swift"),
        ])
        #expect(rootAssemblies.count == 1, "根装配点应唯一（ContentView）：\(rootAssemblies)")

        let playerAssemblies = Self.linesContaining(#"IOSWindowGlass\(artwork:"#, in: [
            Self.repoRoot.appendingPathComponent("QQPlayer/Views/Player/PlayerView.swift"),
        ])
        #expect(playerAssemblies.count == 1, "播放页装配点应唯一（PlayerView，fullScreenCover 内）：\(playerAssemblies)")

        // 其它页面不得各自再画一层（扫全仓：除上面三处外不该出现 IOSWindowGlass 构造/声明）
        let allMentions = Self.linesContaining(#"IOSWindowGlass"#, in: files)
        let allowed = ["QQPlayer/Views/Utility/IOSWindowGlass.swift", "QQPlayer/ContentView.swift", "QQPlayer/Views/Player/PlayerView.swift"]
        let strays = allMentions.filter { line in !allowed.contains { line.hasPrefix($0) } }
        #expect(strays.isEmpty, "别处又画了一层整屏玻璃（应共用唯一实现）：\n\(strays.joined(separator: "\n"))")
    }
}
