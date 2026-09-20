//
//  ViewSharedSingletonContractTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  P1 棘轮：**视图层不得直连单例（`<Type>.shared`）**（2026-09-18 立）。
//
//  问题：视图文件里直接写 `PlayerEngine.shared` / `KaraokeController.shared` /
//  `ArtworkManager.shared` / `AppCoordinator.shared` …，当前 48 个视图文件 / 174 处。
//  后果：视图层自己决定「谁的生命周期归谁」——可测性、替换实现、iOS/Mac 行为一致性
//  都被视图文件锁死；同一语义在多处各自对齐（前例：封面解析散落 5 处）。
//
//  本轮**只立棘轮、不动生产代码**：把存量钉成「只能减不能增」的清单。
//  新写视图直连单例 → 本测试立刻红；清掉一处 → 必须同步改基线行
//  （留陈旧行也红，保证名单不腐烂）。
//
//  六条契约（全部 fail-closed：读不到源码/目录 = 红，绝不静默通过）：
//   (a) 新增违规：检测到的视图文件不在基线里 → 红
//   (b) 计数回涨：某文件出现次数 > 基线 → 红
//   (c) 名单不腐烂：基线里的文件计数下降（含归零）或文件已不存在 → 红（该改/删行了）
//   (d) 总数上限：全部视图文件出现次数之和 > 基线 TOTAL → 红
//   (e) 登记条目不空转：登记区 A（系统单例 `#+`）/ B（合法装配点 `#@`）/ C（`#Preview` 脚手架 `#~`）
//       的每条条目必须在源码里仍对得上站点 → 红（防僵尸豁免）
//   (f) 口径自洽：`可迁 TOTAL == TOTAL − Σ(全部登记条目)`，且每类合计行 == 该类条目求和 → 红
//
//  视图层判定（2026-09-20 口径补齐）：
//    ① 全 `QQPlayer/**` 中**声明了 SwiftUI View**（`: View` / `some View`）的文件
//       —— 与 `EnvironmentInjectionContractTests` 同款口径；
//    ② 并集保留 `QQPlayer/Views/**` 全部文件（含 `UIViewRepresentable` / `UIViewControllerRepresentable` /
//       `UIImage` 扩展这类不声明 `: View` 的视图层 helper）——**口径只紧不松**，
//       新口径是并集的一侧，不能因为改口径把既有覆盖丢掉。
//    非视图文件（`Services/**` 中不声明 View 的服务、`Mac/**` 下的服务等）不在范围内。
//
//  **口径事故（本次修）**：原口径是「`QQPlayer/Views/**` 全部 + `QQPlayer/Mac/**` 中的 View 文件」
//  ⇒ **仓库根目录视图（`QQPlayer/ContentView.swift`）与 `QQPlayer/AppIntents/**` 里的 View**
//  完全不在扫描范围，其直连 `.shared` 一处都看不见（实测漏检 2 文件 / 8 处：
//  `ContentView` 7 · `AppIntents/Snippets/SongCardSnippetIntent` 1）。
//  同类口径问题在 `EnvironmentInjectionContractTests` 已修过一次（根目录视图漏检）——
//  两处口径现已对齐，且各自带「口径自证」用例（合成根目录视图必须被抓到）。
//  计数口径：只算**代码行**（`//` 之后剥离、整行注释不计——文档注释里的字面量会误伤自己），
//    粒度为「`<Type>.shared` 的出现次数」，两种写法都算：
//      · 显式 `Foo.shared`（与 `grep -oE '[A-Za-z_]+\.shared'` 同口径）
//      · **前导点简写** `.shared`（2026-09-19 收紧）——`store: T = .shared` /
//        `ObservedObject(wrappedValue: .shared)` / `hostCenter ?? .shared`。
//    此前只认显式写法，于是「把 `Foo.shared` 改写成 `.shared`」就能压低上限 =
//    棘轮可被绕过。收紧后暴露既有存量 4 处（MacSyncView 3 / SyncDeviceNameEditorView 1）。
//
//  **白名单（批 7-A 落地）：系统单例不是债。** `UIApplication` / `WidgetCenter` / `URLSession` /
//  `NSWorkspace` 是 **Apple 系统入口** —— 视图层直接调它就是正确写法，没有「生命周期归谁」可收口
//  ⇒ **不可迁移**，正式登记为白名单（永久留在基线里）。口径拆两行：`# TOTAL:`（**含**系统单例，
//  棘轮上限）+ `# MIGRATABLE TOTAL:`（**可迁预算** = TOTAL − 白名单合计，进度只看这一行）。
//  **白名单只有一份来源**：条目写在基线 TSV 的 `#+` 区（`#+` TAB 类型 TAB 路径 TAB 站点数），
//  本文件从 TSV 读，不另存手工清单（2026-09-15「同一语义只有一处入口」纪律）。
//  ⚠️ 白名单**不是**「以后可以继续往视图里写系统单例」的许可：新增任何 `<Type>.shared`
//  （含这 4 个系统类型）仍被 (a)(b)(d) 三条拦下——白名单只说明「这 11 处不该由我们迁」。
//
//  **合法装配点（批 7-B 落地）：运行期组合根也不是债（备案式，不放宽扫描口径）。**
//  场景根之外还有**运行期组合根**：`MacDesktopWindowsManager` 的手工 `NSHostingView` 浮窗根
//  不继承 App 场景环境，视图读的 `@Environment(T.self)` 必须在那里显式注入
//  ⇒ 那 3 行是「谁装配谁」的正确落点，不是视图层自己决定生命周期。
//  与系统单例**语义不同**（系统入口不归我们管；运行期组合根归我们管，只是本批不上收），
//  故在基线 TSV 里用**独立前缀 `#@` + 独立合计行**登记，且**不放宽扫描口径**
//  （仍计入 `# TOTAL`，只是不再算「可迁」）。
//
//  **`#Preview` 脚手架（批 7-C 落地）：预览装配是「成本」不是「债」。**
//  视图的 `#Preview` 要渲染就必须自己装配真实例（App 根注入不覆盖画布）⇒ `<Type>.shared`
//  出现在预览块里不可避免（`ContentView` / `SettingsView` / `SyncSettingsView` / `LyricsView`，
//  实测 6 处）。旧账本一直把它「如实计在可迁里」但**不登记** ⇒ 可迁预算永远清不到 0。
//  批 7-C 把它收成第三类（前缀 `#~` + 独立合计行 `# PREVIEW TOTAL:`），与 A/B 同款 fail-closed
//  （区缺失 / 为空 → 抛错，不静默放行），且同样**不放宽扫描口径**（仍计入 `# TOTAL`）。
//
//  基线文件：`QQPlayerTests/Fixtures/shared-singleton-baseline.tsv`
//    （`路径<TAB>计数` + `# TOTAL:` + `# MIGRATABLE TOTAL:` + 各类别合计行
//      + `#+` 系统单例条目 + `#@` 合法装配点条目 + `#~` `#Preview` 脚手架条目）。
//  **登记只有一份来源**：两张登记区都写在基线 TSV 里，本文件只解析，不另存手工清单。
//  预算账本 + 分批计划：`QQPlayerTests/Fixtures/shared-singleton-budget-plan.md`
//    （每批迁完必须把 TOTAL 与涉及文件的行值**下调到实测值**——本棘轮只防变差，
//      "变好"靠那份账本驱动）。
//

import Foundation
import Testing

private enum ViewSharedSingletonContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 扫描根目录：全 `QQPlayer/**`（2026-09-20 口径补齐——根目录 / `AppIntents/**` 的视图此前不可见）。
    static let scannedDirectory = "QQPlayer"
    /// 视图层 helper 目录：`QQPlayer/Views/**` 全部文件仍计入（含不声明 `: View` 的视图层 helper）。
    /// **口径只紧不松**：新口径（声明 View 的文件）是并集的一侧，通配保留不放松既有覆盖。
    static let legacyViewDirectory = "QQPlayer/Views"
    static let baselinePath = "QQPlayerTests/Fixtures/shared-singleton-baseline.tsv"

    struct Baseline {
        var total: Int
        /// 可迁预算（= `total` − Σ 全部登记条目）；进度只看这个数。
        var migratableTotal: Int
        /// 全部登记条目（登记区 A + B）；来自基线 TSV，不另存手工清单。
        var registrations: [RegistrationEntry]
        /// 各类别合计行声明的数值（`# SYSTEM-SINGLETON TOTAL:` / `# COMPOSITION-ROOT TOTAL:` / `# PREVIEW TOTAL:`）。
        var categoryTotals: [RegistrationCategory: Int]
        var perFile: [String: Int]

        /// 某类别的登记条目。
        func entries(of category: RegistrationCategory) -> [RegistrationEntry] {
            registrations.filter { $0.category == category }
        }
    }

    /// 登记条目类别：**前缀即类别标记**（`#+` = 系统单例；`#@` = 合法装配点 / 运行期组合根；
    /// `#~` = `#Preview` 脚手架）。
    /// 三类语义不同（系统入口不归我们管 vs 我们的运行期组合根 vs 预览的不可避免装配成本），
    /// 故分开登记、各自合计。
    enum RegistrationCategory: String, CaseIterable {
        case systemSingleton
        case compositionRoot
        case preview

        /// 基线 TSV 里的条目行前缀（类别即前缀，机器可读、各类可区分）。
        var linePrefix: String {
            switch self {
            case .systemSingleton: return "#+"
            case .compositionRoot: return "#@"
            case .preview: return "#~"
            }
        }

        /// 类别合计行标签（`# <标签> TOTAL: N`）。
        var totalLineLabel: String {
            switch self {
            case .systemSingleton: return "SYSTEM-SINGLETON"
            case .compositionRoot: return "COMPOSITION-ROOT"
            case .preview: return "PREVIEW"
            }
        }

        /// 报告用中文名。
        var label: String {
            switch self {
            case .systemSingleton: return "系统单例（`#+`）"
            case .compositionRoot: return "合法装配点 / 运行期组合根（`#@`）"
            case .preview: return "`#Preview` 脚手架（`#~`）"
            }
        }
    }

    /// 登记条目（`#+` / `#@` / `#~` TAB 类型 TAB 相对路径 TAB 站点数）。
    struct RegistrationEntry: Equatable {
        var category: RegistrationCategory
        var type: String
        var relativePath: String
        var count: Int
    }

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case baselineMalformed(String)
        case baselineTotalMissing
        case migratableTotalMissing
        case registrationCategoryEmpty(RegistrationCategory)
        case categoryTotalMissing(RegistrationCategory)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举/读取（fail-closed）：\(path)"
            case .baselineMalformed(let line):
                return "基线格式错误（fail-closed）：\(line)"
            case .baselineTotalMissing:
                return "基线缺少 `# TOTAL: <数字>` 行（fail-closed）"
            case .migratableTotalMissing:
                return "基线缺少 `# MIGRATABLE TOTAL: <数字>` 行（口径拆分，fail-closed）"
            case .registrationCategoryEmpty(let category):
                return "基线缺少 \(category.label) 登记条目（该类别为空，fail-closed：不静默放行）"
            case .categoryTotalMissing(let category):
                return "基线缺少 `# \(category.totalLineLabel) TOTAL: <数字>` 类别合计行（fail-closed）"
            }
        }
    }

    /// 显式写法（与用户侧口径一致：`grep -oE '[A-Za-z_]+\.shared'`）。
    private static let explicitSharedPattern = try! NSRegularExpression(pattern: "[A-Za-z_]+[.]shared")
    /// **前导点简写** `.shared`：点号前不是标识符字符/点，点号后不是标识符字符。
    /// 例：`= .shared` / `: .shared` / `(wrappedValue: .shared)` / `?? .shared` / `foo().shared`。
    /// 与显式写法互斥（`Foo.shared` 的点号前是标识符 → 这里不重复计数）。
    private static let shorthandSharedPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_.])[.]shared(?![A-Za-z0-9_])"
    )
    private static let totalPattern = try! NSRegularExpression(pattern: "^#\\s*TOTAL:\\s*([0-9]+)\\s*$")
    /// 可迁预算行：`# MIGRATABLE TOTAL: N`（与 `# TOTAL:` 互斥——后者要求 `#` 后直接跟 TOTAL）。
    private static let migratableTotalPattern = try! NSRegularExpression(
        pattern: "^#\\s*MIGRATABLE\\s+TOTAL:\\s*([0-9]+)\\s*$"
    )
    /// 登记条目（**唯一实现**，各类别共用一条正则）：**前缀即类别** —— `#+` 系统单例 / `#@` 合法装配点 /
    /// `#~` `#Preview` 脚手架（前缀整段在捕获组 1）；后三段 = TAB 类型名 TAB 相对路径 TAB 该类型在该文件的站点数。
    private static let registrationPattern = try! NSRegularExpression(
        pattern: "^(#[+@~])\\t([A-Za-z_][A-Za-z0-9_]*)\\t([^\\t]+?)\\t([0-9]+)\\s*$"
    )

    /// 类别合计行（`# SYSTEM-SINGLETON TOTAL: N` / `# COMPOSITION-ROOT TOTAL: N` / `# PREVIEW TOTAL: N`）。
    /// 由类别标签拼出（单一来源：标签只在 `totalLineLabel` 定义一次）。
    static func categoryTotalPattern(for category: RegistrationCategory) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^#\\s*\(category.totalLineLabel)\\s+TOTAL:\\s*([0-9]+)\\s*$")
    }

    /// 是否声明了 SwiftUI View（决定该文件算不算视图层）。
    static func declaresSwiftUIView(_ source: String) -> Bool {
        if source.contains(": View") { return true }
        if source.contains("some View") { return true }
        return false
    }

    /// 单行代码里的出现次数（先剥掉 `//` 之后的注释部分）：显式写法 + 前导点简写。
    static func occurrences(inCodeLine line: String) -> Int {
        let code = line.components(separatedBy: "//").first ?? ""
        let range = NSRange(code.startIndex ..< code.endIndex, in: code)
        return explicitSharedPattern.numberOfMatches(in: code, range: range)
            + shorthandSharedPattern.numberOfMatches(in: code, range: range)
    }

    /// 登记条目解析（**唯一实现**：`parseBaseline` 与自证用例共用）；非登记行返回 nil。
    /// 前缀决定类别：`#+` → `.systemSingleton`；`#@` → `.compositionRoot`；`#~` → `.preview`；其它前缀 → nil。
    static func parseRegistrationEntry(for line: String) -> RegistrationEntry? {
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = registrationPattern.firstMatch(in: line, range: range),
              let prefixRange = Range(match.range(at: 1), in: line),
              let typeRange = Range(match.range(at: 2), in: line),
              let pathRange = Range(match.range(at: 3), in: line),
              let countRange = Range(match.range(at: 4), in: line),
              let count = Int(line[countRange]),
              let category = RegistrationCategory.allCases.first(where: {
                  $0.linePrefix == String(line[prefixRange])
              }) else { return nil }
        return RegistrationEntry(
            category: category,
            type: String(line[typeRange]),
            relativePath: String(line[pathRange]),
            count: count
        )
    }

    /// 登记站点核对（登记区 A / B 共用）：某文件里**显式** `<Type>.shared` 的出现次数
    /// （只算代码行，剥 `//` 后注释）。只认显式写法——登记的是具体类型，前导点简写无法归属到某个类型
    /// （简写写法会让本检查判红，这正是 (e) 想要的：站点换了写法就该回来看登记条目）。
    static func registrationSiteCount(type: String, in source: String) -> Int {
        // 编译不出来 = 返回 0 ⇒ 空转检查判红（fail-closed，不静默通过）。
        guard let pattern = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: type))[.]shared"
        ) else { return 0 }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { partial, rawLine in
                let code = String(rawLine).components(separatedBy: "//").first ?? ""
                let range = NSRange(code.startIndex ..< code.endIndex, in: code)
                return partial + pattern.numberOfMatches(in: code, range: range)
            }
    }

    /// 一份源码里的出现次数（只算代码行）。
    static func occurrenceCount(in source: String) -> Int {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + occurrences(inCodeLine: String($1)) }
    }

    /// 口径判定（**唯一实现**：契约与自证共用）：
    /// `QQPlayer/Views/**` 全部 + 其余位置里声明了 SwiftUI View 的文件。
    static func isViewLayerFile(relativePath: String, source: String) -> Bool {
        if relativePath.hasPrefix(legacyViewDirectory + "/") { return true }
        return declaresSwiftUIView(source)
    }

    /// 仓库内全部 `QQPlayer/**` Swift 文件（相对路径 + 源码）。
    /// 逐文件读取，读不出来即抛错（fail-closed，绝不静默当成「没违规」）。
    static func repositoryFiles() throws -> [(relativePath: String, source: String)] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        let prefix = repositoryRoot.path + "/"
        var files: [(relativePath: String, source: String)] = []
        var unreadable: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                files.append((relative, source))
            } else {
                unreadable.append(relative)
            }
        }
        guard unreadable.isEmpty else {
            throw ContractError.directoryUnreadable("以下文件读不到：\(unreadable.sorted())")
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// 检测结果：相对路径 → 出现次数（只含 > 0 的**视图层**文件）。
    /// 纯函数（输入 = 文件清单）——口径自证用例靠它合成根目录视图文件，不必真写盘。
    static func detectedOccurrences(
        in files: [(relativePath: String, source: String)]
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for file in files {
            guard isViewLayerFile(relativePath: file.relativePath, source: file.source) else { continue }
            let count = occurrenceCount(in: file.source)
            guard count > 0 else { continue }
            result[file.relativePath] = count
        }
        return result
    }

    /// 实际检测结果（仓库真实文件）。
    static func detectedOccurrences() throws -> [String: Int] {
        detectedOccurrences(in: try repositoryFiles())
    }

    /// 基线清单解析（**纯函数**：文本 → `Baseline`；读盘在 `baseline()`）。
    /// 解析口径：`路径<TAB>计数`；`#` 开头是注释，其中 `# TOTAL: N` = 棘轮上限、
    /// `# MIGRATABLE TOTAL: N` = 可迁预算、`# <类别> TOTAL: N` = 类别合计、
    /// `#+` / `#@` / `#~` 行 = 登记条目（`#+` 系统单例 / `#@` 合法装配点 / `#~` `#Preview` 脚手架）。
    static func parseBaseline(_ text: String) throws -> Baseline {
        var perFile: [String: Int] = [:]
        var total: Int?
        var migratableTotal: Int?
        var registrations: [RegistrationEntry] = []
        var categoryTotals: [RegistrationCategory: Int] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                if let match = totalPattern.firstMatch(in: line, range: range),
                   let valueRange = Range(match.range(at: 1), in: line) {
                    total = Int(line[valueRange])
                }
                if let match = migratableTotalPattern.firstMatch(in: line, range: range),
                   let valueRange = Range(match.range(at: 1), in: line) {
                    migratableTotal = Int(line[valueRange])
                }
                for category in RegistrationCategory.allCases {
                    let pattern = categoryTotalPattern(for: category)
                    if let match = pattern.firstMatch(in: line, range: range),
                       let valueRange = Range(match.range(at: 1), in: line) {
                        categoryTotals[category] = Int(line[valueRange])
                    }
                }
                if let entry = parseRegistrationEntry(for: line) {
                    registrations.append(entry)
                }
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw ContractError.baselineMalformed(line)
            }
            perFile[String(parts[0]).trimmingCharacters(in: .whitespaces)] = count
        }
        guard let total else { throw ContractError.baselineTotalMissing }
        guard let migratableTotal else { throw ContractError.migratableTotalMissing }
        // fail-closed：**每个登记类别都必须有条目 + 类别合计行**（缺一即红，绝不静默放行）。
        for category in RegistrationCategory.allCases {
            guard registrations.contains(where: { $0.category == category }) else {
                throw ContractError.registrationCategoryEmpty(category)
            }
            guard categoryTotals[category] != nil else {
                throw ContractError.categoryTotalMissing(category)
            }
        }
        return Baseline(
            total: total,
            migratableTotal: migratableTotal,
            registrations: registrations,
            categoryTotals: categoryTotals,
            perFile: perFile
        )
    }

    /// 基线清单（读盘；fail-closed：文件不存在/读不到 = 抛错）。
    static func baseline() throws -> Baseline {
        let url = repositoryRoot.appendingPathComponent(baselinePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContractError.directoryUnreadable(baselinePath)
        }
        return try parseBaseline(try String(contentsOf: url, encoding: .utf8))
    }
}

@Suite("视图层直连单例契约（P1 棘轮）")
struct ViewSharedSingletonContractTests {
    @Test("(d) 总数只能减不能增：视图层 `<Type>.shared` 总计数 ≤ 基线 TOTAL")
    func totalOccurrencesDoNotGrow() throws {
        let detected = try ViewSharedSingletonContract.detectedOccurrences()
        let baseline = try ViewSharedSingletonContract.baseline()
        let actual = detected.values.reduce(0, +)

        #expect(
            actual <= baseline.total,
            """
            视图层 `<Type>.shared` 总计数回涨：基线 TOTAL \(baseline.total) → 实测 \(actual)。
            请改走已有入口 / 依赖注入，不要新增 `X.shared` 直连；确需登记则同步更新基线并说明理由。
            """
        )
    }

    @Test("(a)(b) 不得新增直连文件，且既有文件计数只能减不能增")
    func noNewOrGrownDirectReferences() throws {
        let detected = try ViewSharedSingletonContract.detectedOccurrences()
        let baseline = try ViewSharedSingletonContract.baseline()

        let added = detected.keys.filter { baseline.perFile[$0] == nil }.sorted()
        #expect(
            added.isEmpty,
            "视图层新增了单例直连（基线里没有这些文件）：\(added)"
        )

        let grown = detected.compactMap { relativePath, count -> String? in
            guard let baseCount = baseline.perFile[relativePath], count > baseCount else { return nil }
            return "\(relativePath): \(baseCount) → \(count)"
        }.sorted()
        #expect(grown.isEmpty, "视图层单例直连计数回涨：\(grown)")
    }

    @Test("(c) 基线名单不腐烂：计数下降（含归零）或文件消失必须同步改行")
    func baselineHasNoStaleEntries() throws {
        let detected = try ViewSharedSingletonContract.detectedOccurrences()
        let baseline = try ViewSharedSingletonContract.baseline()

        var missing: [String] = []
        var decreased: [String] = []
        for (relativePath, baseCount) in baseline.perFile {
            let fileURL = ViewSharedSingletonContract.repositoryRoot.appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                missing.append(relativePath)
                continue
            }
            let actual = detected[relativePath] ?? 0
            if actual < baseCount {
                decreased.append("\(relativePath): \(baseCount) → \(actual)")
            }
        }
        #expect(
            missing.isEmpty,
            "基线里的文件已不存在，请删行：\(missing.sorted())"
        )
        #expect(
            decreased.isEmpty,
            """
            基线里这些文件的直连已减少/归零，请同步改行（归零则删行）：
            \(decreased.sorted())
            """
        )
        let baselineTotal = baseline.perFile.values.reduce(0, +)
        #expect(
            baselineTotal == baseline.total,
            "基线自相矛盾：行数合计 \(baselineTotal) ≠ TOTAL \(baseline.total)"
        )
    }

    @Test("(e) 登记条目不空转：系统单例 + 合法装配点 + `#Preview` 脚手架的每条条目必须在源码里仍对得上站点（防僵尸豁免）")
    func registrationEntriesStillHitSource() throws {
        let baseline = try ViewSharedSingletonContract.baseline()
        for category in ViewSharedSingletonContract.RegistrationCategory.allCases {
            #expect(
                !baseline.entries(of: category).isEmpty,
                "\(category.label) 登记区为空（fail-closed）：基线缺少 `\(category.linePrefix)` 条目"
            )
        }

        var stale: [String] = []
        for entry in baseline.registrations {
            let fileURL = ViewSharedSingletonContract.repositoryRoot.appendingPathComponent(entry.relativePath)
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
                stale.append("[\(entry.category.totalLineLabel)] \(entry.type) @ \(entry.relativePath)：文件不存在或读不到")
                continue
            }
            let found = ViewSharedSingletonContract.registrationSiteCount(type: entry.type, in: source)
            if found < entry.count {
                stale.append("[参与类别 \(entry.category.totalLineLabel)] \(entry.type) @ \(entry.relativePath)：登记 \(entry.count) 处，实测 \(found) 处")
            }
        }
        #expect(
            stale.isEmpty,
            """
            登记条目已失效（源码里找不到登记的站点）——请同步改/删条目，别让登记变僵尸豁免：
            \(stale.sorted())
            """
        )
    }

    @Test("(f) 口径自洽：可迁 TOTAL = TOTAL − Σ(全部登记条目)，且每类合计行 == 该类条目求和")
    func migratableTotalMatchesCaliber() throws {
        let baseline = try ViewSharedSingletonContract.baseline()
        let registeredSum = baseline.registrations.map(\.count).reduce(0, +)
        #expect(
            baseline.migratableTotal == baseline.total - registeredSum,
            "可迁 TOTAL 口径不自洽：TOTAL \(baseline.total) − 登记合计 \(registeredSum) ≠ 可迁 TOTAL \(baseline.migratableTotal)"
        )
        for category in ViewSharedSingletonContract.RegistrationCategory.allCases {
            let entrySum = baseline.entries(of: category).map(\.count).reduce(0, +)
            #expect(
                baseline.categoryTotals[category] == entrySum,
                "`# \(category.totalLineLabel) TOTAL:` 合计行与条目求和不一致：声明 \(baseline.categoryTotals[category].map(String.init) ?? "缺失") vs 条目合计 \(entrySum)"
            )
        }
    }

    @Test("自证：登记口径（条目解析 + 类别前缀 + 站点计数只认代码行/显式写法）")
    func registrationCaliberSelfTest() {
        // 站点计数：剥注释；只认显式写法（前导点简写无法归属到具体类型）
        let source = """
        import UIKit
        struct Foo: View {
            // 整行注释里的 UIApplication.shared 不算
            func open(_ url: URL) { UIApplication.shared.open(url) } // 行尾注释 UIApplication.shared 也不算
            func scene() -> UIApplication { UIApplication.shared }
        }
        """
        #expect(ViewSharedSingletonContract.registrationSiteCount(type: "UIApplication", in: source) == 2)
        // 相近类型名不误伤（`Application` 不是 `UIApplication`）
        #expect(ViewSharedSingletonContract.registrationSiteCount(type: "Application", in: source) == 0)
        // 条目解析：`#+` → 系统单例
        #expect(
            ViewSharedSingletonContract.parseRegistrationEntry(
                for: "#+\tUIApplication\tQQPlayer/Views/Artists/ArtistDetailScreen.swift\t2"
            ) == ViewSharedSingletonContract.RegistrationEntry(
                category: .systemSingleton,
                type: "UIApplication",
                relativePath: "QQPlayer/Views/Artists/ArtistDetailScreen.swift",
                count: 2
            )
        )
        // 条目解析：`#@` → 合法装配点（类别由前缀决定，两类可区分）
        #expect(
            ViewSharedSingletonContract.parseRegistrationEntry(
                for: "#@\tPlayerEngine\tQQPlayer/Mac/MacDesktopWindowsManager.swift\t2"
            ) == ViewSharedSingletonContract.RegistrationEntry(
                category: .compositionRoot,
                type: "PlayerEngine",
                relativePath: "QQPlayer/Mac/MacDesktopWindowsManager.swift",
                count: 2
            )
        )
        // 条目解析：`#~` → `#Preview` 脚手架（类别由前缀决定，三类可区分）
        #expect(
            ViewSharedSingletonContract.parseRegistrationEntry(
                for: "#~\tAppCoordinator\tQQPlayer/ContentView.swift\t1"
            ) == ViewSharedSingletonContract.RegistrationEntry(
                category: .preview,
                type: "AppCoordinator",
                relativePath: "QQPlayer/ContentView.swift",
                count: 1
            )
        )
        // 非登记行不得被当成条目（普通文件行 / TOTAL 行 / 可迁行 / 三个类别合计行 / 普通注释）
        for line in [
            "QQPlayer/ContentView.swift\t1",
            "# TOTAL: 21",
            "# MIGRATABLE TOTAL: 1",
            "# SYSTEM-SINGLETON TOTAL: 11",
            "# COMPOSITION-ROOT TOTAL: 3",
            "# PREVIEW TOTAL: 6",
            "# 普通注释",
        ] {
            #expect(ViewSharedSingletonContract.parseRegistrationEntry(for: line) == nil, "误吃：\(line)")
        }
        // 缺字段 / 计数非数字 / 未知前缀 → nil（不静默当 0）
        #expect(ViewSharedSingletonContract.parseRegistrationEntry(for: "#+\tUIApplication\tA.swift") == nil)
        #expect(ViewSharedSingletonContract.parseRegistrationEntry(for: "#+\tUIApplication\tA.swift\tx") == nil)
        #expect(ViewSharedSingletonContract.parseRegistrationEntry(for: "#%\tUIApplication\tA.swift\t1") == nil)
    }

    @Test("自证：类别口径 fail-closed（缺一类别 / 缺合计行 / 缺可迁行 ⇒ 抛错，不静默放行）")
    func registrationFailClosedSelfTest() throws {
        let good = "# TOTAL: 4\n"
            + "# MIGRATABLE TOTAL: 0\n"
            + "#+\tUIApplication\tA.swift\t2\n"
            + "# SYSTEM-SINGLETON TOTAL: 2\n"
            + "#@\tPlayerEngine\tB.swift\t1\n"
            + "# COMPOSITION-ROOT TOTAL: 1\n"
            + "#~\tAppCoordinator\tC.swift\t1\n"
            + "# PREVIEW TOTAL: 1\n"
            + "A.swift\t2\n"
            + "B.swift\t1\n"
            + "C.swift\t1\n"

        // 正向：三个类别都解析出来，类别合计 / 条目 / 文件行各自到位
        let parsed = try ViewSharedSingletonContract.parseBaseline(good)
        #expect(parsed.total == 4)
        #expect(parsed.migratableTotal == 0)
        #expect(parsed.registrations.count == 3)
        #expect(parsed.entries(of: .systemSingleton).count == 1)
        #expect(parsed.entries(of: .compositionRoot).count == 1)
        #expect(parsed.entries(of: .preview).count == 1)
        #expect(parsed.categoryTotals[.systemSingleton] == 2)
        #expect(parsed.categoryTotals[.compositionRoot] == 1)
        #expect(parsed.categoryTotals[.preview] == 1)
        #expect(parsed.perFile["A.swift"] == 2)

        // 反向（每条都必须抛错，不得静默放行）：
        // 新类别 `#@` 整区缺失
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "#@\tPlayerEngine\tB.swift\t1\n", with: "")
            )
        }
        // 既有系统单例类别整区缺失
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "#+\tUIApplication\tA.swift\t2\n", with: "")
            )
        }
        // 缺新类别合计行
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "# COMPOSITION-ROOT TOTAL: 1\n", with: "")
            )
        }
        // 批 7-C 新类别 `#~`（`#Preview` 脚手架）整区缺失 / 缺其合计行 ⇒ 同样 fail-closed
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "#~\tAppCoordinator\tC.swift\t1\n", with: "")
            )
        }
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "# PREVIEW TOTAL: 1\n", with: "")
            )
        }
        // 缺可迁口径行 / 缺上限行
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "# MIGRATABLE TOTAL: 0\n", with: "")
            )
        }
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(
                good.replacingOccurrences(of: "# TOTAL: 4\n", with: "")
            )
        }
        // 文件行格式坏
        #expect(throws: ViewSharedSingletonContract.ContractError.self) {
            _ = try ViewSharedSingletonContract.parseBaseline(good + "坏行\n")
        }
    }

    @Test("自证：检测规则本身能抓到合成输入（fail-closed 反向验证）")
    func detectionRuleSelfTest() {
        let viewSource = """
        import SwiftUI
        struct Foo: View {
            // 文档/行尾注释里的 KaraokeController.shared 不算
            var body: some View {
                let engine = PlayerEngine.shared
                _ = KaraokeController.shared.state // 行尾注释 ArtworkManager.shared 也不算
                _ = AppCoordinator.shared
            }
        }
        """
        #expect(ViewSharedSingletonContract.declaresSwiftUIView(viewSource))
        #expect(ViewSharedSingletonContract.occurrenceCount(in: viewSource) == 3)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "// 整行注释 X.shared") == 0)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let x = URLSession.shared") == 1)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let y = something.sharedThing") == 1)

        // 2026-09-19 收紧：前导点简写必须计入（此前正是「换写法压低上限」的漏洞）
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "store: LocalDeviceNameStore = .shared") == 1)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "_x = ObservedObject(wrappedValue: .shared)") == 1)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let a = hostCenter ?? .shared") == 1)
        // 显式写法不得被简写规则重复计数（`Foo.shared` 仍只算 1）
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let b = Foo.shared") == 1)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let c = Foo.shared.bar") == 1)
        // 链式/可选链后的简写同样算（点号前不是标识符）
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let d = foo().shared") == 1)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let e = maker()?.shared") == 1)
        // 词边界：`shared` 后面还有标识符字符 → 不是单例访问
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let f = .sharedThing") == 0)

        let serviceSource = """
        import Foundation
        enum BarService {
            static func load() { _ = PlayerEngine.shared.currentTrack }
        }
        """
        #expect(!ViewSharedSingletonContract.declaresSwiftUIView(serviceSource))
        #expect(ViewSharedSingletonContract.occurrenceCount(in: serviceSource) == 1)
    }

    @Test("口径自证：声明 View 的文件一律在口径内（含根目录 / 意图层；fail-closed 反向验证）")
    func scopeSelfTest() throws {
        let viewSource = """
        import SwiftUI
        struct RootScreen: View {
            @StateObject private var indexer = LibraryIndexer.shared
            var body: some View { EmptyView() }
        }
        """
        // 非视图文件，但确实含一处直连（否则会被「计数为 0 不进名单」当成过）
        let serviceSource = """
        import Foundation
        final class FooService {
            func load() { _ = PlayerEngine.shared.currentTrack }
        }
        """

        let detected = ViewSharedSingletonContract.detectedOccurrences(in: [
            ("QQPlayer/ContentView.swift", viewSource),
            ("QQPlayer/AppIntents/Snippets/SongCardSnippetIntent.swift", viewSource),
            ("QQPlayer/Services/DatabaseManager.swift", serviceSource),
            ("QQPlayer/Mac/MacImportService.swift", serviceSource),
            ("QQPlayer/Views/Player/PlayerGestureLogic.swift", serviceSource),
        ])

        // 口径补齐前，这两类位置的视图文件一处都看不见（本次事故形态：根目录视图 + 意图层视图）
        #expect(detected["QQPlayer/ContentView.swift"] == 1)
        #expect(detected["QQPlayer/AppIntents/Snippets/SongCardSnippetIntent.swift"] == 1)
        // 不声明 View 的服务不在口径内（不误伤服务层）
        #expect(detected["QQPlayer/Services/DatabaseManager.swift"] == nil)
        #expect(detected["QQPlayer/Mac/MacImportService.swift"] == nil)
        // `QQPlayer/Views/**` 通配保留：不声明 `: View` 的视图层 helper 仍在口径内（口径只紧不松）
        #expect(detected["QQPlayer/Views/Player/PlayerGestureLogic.swift"] == 1)
        // 口径判定本身（与计数无关，直接断言集合归属）
        #expect(ViewSharedSingletonContract.isViewLayerFile(
            relativePath: "QQPlayer/Views/Player/PlayerGestureLogic.swift", source: serviceSource
        ))
        #expect(!ViewSharedSingletonContract.isViewLayerFile(
            relativePath: "QQPlayer/Services/DatabaseManager.swift", source: serviceSource
        ))

        // 反向验证（磁盘真实文件）：口径判定对真实仓库成立——
        // 根目录 / 意图层 / Mac 视图在口径内，服务层文件不在。
        let inScope = try ViewSharedSingletonContract.repositoryFiles()
            .filter { ViewSharedSingletonContract.isViewLayerFile(relativePath: $0.relativePath, source: $0.source) }
            .map(\.relativePath)
        for path in [
            "QQPlayer/ContentView.swift",
            "QQPlayer/AppIntents/Snippets/SongCardSnippetIntent.swift",
            "QQPlayer/Views/Player/PlayerGestureLogic.swift",
            "QQPlayer/Mac/MacLibraryView.swift",
        ] {
            #expect(inScope.contains(path), "口径漏了：\(path)")
        }
        for path in ["QQPlayer/Services/DatabaseManager.swift", "QQPlayer/Mac/MacImportService.swift"] {
            #expect(!inScope.contains(path), "口径过宽：\(path)")
        }
        // fail-closed：口径内文件数不应明显偏小（枚举/判定失灵时本断言先红，绝不静默通过）
        #expect(inScope.filter { $0.hasPrefix("QQPlayer/Views/") }.count > 40)
        #expect(inScope.count > 60)
    }
}
