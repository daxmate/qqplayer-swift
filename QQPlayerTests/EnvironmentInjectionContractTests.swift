//
//  EnvironmentInjectionContractTests.swift
//  QQPlayerTests
//
//  组合根装配契约（2026-09-19 立，事故驱动）。
//
//  **事故**：批 4 给 iOS 视图加了 `@Environment(AppServices.self)`，却只在 Mac 组合根补了
//  `.environment(AppServices.live)` → **编译期零警告、1671 个单测全绿，真机一进「同步设置」页就崩**
//  （`@Environment(T.self)` 未装配时是**运行时**致命错；UI 层没有测试覆盖，两类门禁都看不见）。
//
//  **契约**：视图层读了 `@Environment(T.self)` → 其**所在平台对应的组合根**必须有一行装配。
//    - `QQPlayer/Mac/**` 的视图 → macOS 组合根（`QQPlayerMacApp.swift`）
//    - 其余视图文件 → iOS 组合根（`QQPlayerApp.swift`）
//  两个方向都算违例：**用了没装配**（本次事故）与**平台搞错**（给 Mac 视图只装 iOS 根）。
//
//  **口径**：扫描范围 = 声明了 SwiftUI View 的全部 `QQPlayer/**` 文件（组合根自身除外）；
//  注释里的写法不算；`@Environment(\.keyPath)` 形式不算（那是环境值，不是 App 级对象）。
//  合法例外：视图文件的 `#Preview` 是第二个装配点（preview 不继承场景环境），本契约只管**组合根**，
//  与直连单例棘轮的口径一致（见 `shared-singleton-budget-plan.md` §五.2）。
//  **手工 hosting 根**（`NSHostingView` 承载的 NSPanel 浮窗）是第三个装配点，同样不继承场景环境，
//  由本文件下方的 `ManualHostingEnvironmentContractTests` 守护（2026-09-20 批 5b 立）。
//

import Foundation
import Testing

private enum EnvironmentInjectionContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 扫描根目录（与直连单例棘轮同源：全 `QQPlayer/`，只看声明了 View 的文件）。
    static let scannedDirectory = "QQPlayer"
    /// Mac 专属视图目录前缀 —— 决定该由哪个组合根装配。
    static let macViewPrefix = "QQPlayer/Mac/"

    /// 组合根：App 级对象的唯一装配点（相对仓库根的路径 + 平台名）。
    static let roots: [(platform: String, path: String)] = [
        ("iOS", "QQPlayer/QQPlayerApp.swift"),
        ("macOS", "QQPlayer/QQPlayerMacApp.swift"),
    ]

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case rootUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举/读取（fail-closed）：\(path)"
            case .rootUnreadable(let path):
                return "组合根文件读不到（fail-closed）：\(path)"
            }
        }
    }

    /// 是否声明了 SwiftUI View（决定该文件算不算视图层）。
    static func declaresSwiftUIView(_ source: String) -> Bool {
        source.contains(": View") || source.contains("some View")
    }

    /// 剥离行注释（`//` 之后），避免注释里提到的写法被计入。
    static func stripped(_ line: String) -> String {
        line.components(separatedBy: "//").first ?? ""
    }

    /// `@Environment(Type.self)`（**不是** `@Environment(\.keyPath)`）。
    private static let environmentTypePattern = try! NSRegularExpression(
        pattern: "[@]Environment\\(([A-Za-z_][A-Za-z0-9_]*)[.]self\\)"
    )

    /// 一份源码里被 `@Environment(T.self)` 消费的 App 级对象类型名。
    static func consumedTypes(in source: String) -> Set<String> {
        var result: Set<String> = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let code = stripped(String(rawLine))
            let range = NSRange(code.startIndex ..< code.endIndex, in: code)
            for match in environmentTypePattern.matches(in: code, range: range) {
                guard let typeRange = Range(match.range(at: 1), in: code) else { continue }
                result.insert(String(code[typeRange]))
            }
        }
        return result
    }

    /// 组合根里是否存在该类型的装配行（`.environment(Type.shared)` / `.environment(Type.live)`）。
    /// 判据带上类型名后面的点号，避免 `Foo` 误匹配 `FooBar`；**注释行不计**
    /// （与直连单例棘轮同口径——否则把装配行 `//` 注掉、或注释里提到该写法，都会把判据骗绿）。
    static func rootInjects(_ type: String, in rootSource: String) -> Bool {
        let code = rootSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripped(String($0)) }
            .joined(separator: "\n")
        let pattern = "[.]environment\\(\\s*" + type + "[.]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(code.startIndex ..< code.endIndex, in: code)
        return regex.firstMatch(in: code, range: range) != nil
    }

    static func swiftFiles() throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func rootSource(_ path: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.rootUnreadable(path)
        }
        return text
    }

    /// 视图层消费清单：平台 → 类型 → 引用它的视图文件（升序）。
    static func consumedByPlatform() throws -> [String: [String: [String]]] {
        let prefix = repositoryRoot.path + "/"
        let rootPaths = Set(roots.map(\.path))
        var result: [String: [String: [String]]] = [:]

        for url in try swiftFiles() {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            guard !rootPaths.contains(relative) else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard declaresSwiftUIView(source) else { continue }

            let platform = relative.hasPrefix(macViewPrefix) ? "macOS" : "iOS"
            for type in consumedTypes(in: source) {
                result[platform, default: [:]][type, default: []].append(relative)
            }
        }
        return result
    }

    // MARK: - 手工 hosting 根（批 5b 立）

    //  盲区：上方的组合根契约只管 **App 场景根**；手工 `NSHostingView` 承载的视图
    //  （NSPanel 浮窗）不继承场景环境，装配点在那个构造方文件里。批 5b 上浮窗时实证：
    //  只改 App 根，进迷你模式即运行时致命错（编译与单测都看不见）。

    /// 顶层类型声明的起点（`struct/class/enum/actor Name`）。
    private static let typeDeclarationPattern = try! NSRegularExpression(
        pattern: "\\b(?:struct|class|enum|actor) ([A-Za-z_][A-Za-z0-9_]*)\\b"
    )

    /// 声明了 SwiftUI View 的类型声明行（`: …View`；`ViewModifier` 不匹配，`some View` 函数行不算）。
    private static let viewDeclarationPattern = try! NSRegularExpression(
        pattern: "\\b(?:struct|class|enum) [A-Za-z_][A-Za-z0-9_]*\\s*:[^{]*\\bView\\b"
    )

    /// AppKit 手工承载 SwiftUI 内容的入口（按标识符判，兼容 `NSHostingView<AnyView>(…)` 泛型写法）。
    private static let hostingEntryPattern = try! NSRegularExpression(
        pattern: "\\bNSHosting(?:View|Controller|Menu)\\b"
    )

    /// `.environment(self)`（对象把自己的引用注入环境）。
    private static let selfInjectionPattern = try! NSRegularExpression(
        pattern: "[.]environment\\(\\s*self\\s*\\)"
    )

    /// 逐行剥注释后的源码（`stripped` 只处理单行，多行文本必须先按行拆再拼）。
    static func strippedSource(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripped(String($0)) }
            .joined(separator: "\n")
    }

    /// 该行声明的类型名（无则 nil）。
    static func declaredTypeName(in codeLine: String) -> String? {
        let range = NSRange(codeLine.startIndex ..< codeLine.endIndex, in: codeLine)
        guard let match = typeDeclarationPattern.firstMatch(in: codeLine, range: range),
              let nameRange = Range(match.range(at: 1), in: codeLine)
        else { return nil }
        return String(codeLine[nameRange])
    }

    /// 承载手工 hosting 的那个类型：hosting 入口前最近的一个**顶层（缩进 0）**类型声明。
    /// 口径：本仓库约定一个文件一个 App 级类；缩进判据足以定位（不做完整语法解析）。
    static func hostingEnclosingType(_ source: String) -> String? {
        var enclosing: String?
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let code = stripped(rawLine)
            if !code.isEmpty, code.first != " ", code.first != "\t",
               let name = declaredTypeName(in: code) {
                enclosing = name
            }
            let range = NSRange(code.startIndex ..< code.endIndex, in: code)
            if hostingEntryPattern.firstMatch(in: code, range: range) != nil {
                return enclosing
            }
        }
        return nil
    }

    /// 该文件是否构造了手工 hosting 根。
    static func buildsManualHostingRoot(_ source: String) -> Bool {
        let code = strippedSource(source)
        let range = NSRange(code.startIndex ..< code.endIndex, in: code)
        return hostingEntryPattern.firstMatch(in: code, range: range) != nil
    }

    /// hosting 文件里出现过的、仓库内已定义的视图类型名（= 它承载的内容视图）。
    static func hostedViewTypes(in source: String, known: [String: Set<String>]) -> [String] {
        let code = strippedSource(source)
        return known.keys
            .filter { code.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil }
            .sorted()
    }

    /// 该文件是否装配了 `type`：字面量 `.environment(Type.…)`，
    /// 或（承载 hosting 的那个类型就是 Type 时）`.environment(self)`。
    static func injects(_ type: String, in source: String) -> Bool {
        if rootInjects(type, in: source) { return true }
        guard hostingEnclosingType(source) == type else { return false }
        let code = strippedSource(source)
        let range = NSRange(code.startIndex ..< code.endIndex, in: code)
        return selfInjectionPattern.firstMatch(in: code, range: range) != nil
    }

    /// 单文件判定：hosting 了哪些内容视图、缺哪些装配（契约与自证共用同一口径）。
    static func hostingGaps(
        in source: String,
        consumedByViewType: [String: Set<String>]
    ) -> (hosted: [String], missing: [String]) {
        guard buildsManualHostingRoot(source) else { return ([], []) }
        let hosted = hostedViewTypes(in: source, known: consumedByViewType)
        var required: Set<String> = []
        for type in hosted {
            required.formUnion(consumedByViewType[type] ?? [])
        }
        return (hosted, required.filter { !injects($0, in: source) }.sorted())
    }

    /// 视图类型 → 该类型（按类型声明行切块，不是按整文件）读的 `@Environment(T.self)` 类型集合。
    static func consumedTypesByViewType() throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for url in try swiftFiles() {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (name, types) in viewConsumedTypes(in: source) {
                result[name, default: []].formUnion(types)
            }
        }
        return result
    }

    /// 按类型声明行切块（近似解析：声明须自成一行；每个声明开一块，到下一个声明为止）。
    static func viewTypeBlocks(in source: String) -> [(name: String, body: String)] {
        var blocks: [(name: String, body: String)] = []
        var currentName: String?
        var currentLines: [String] = []

        func flush() {
            guard let name = currentName else { return }
            blocks.append((name, currentLines.joined(separator: "\n")))
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let code = stripped(line)
            if let name = declaredTypeName(in: code).flatMap({ candidate -> String? in
                let range = NSRange(code.startIndex ..< code.endIndex, in: code)
                return viewDeclarationPattern.firstMatch(in: code, range: range) != nil ? candidate : nil
            }) {
                flush()
                currentName = name
                currentLines = [line]
            } else if currentName != nil {
                currentLines.append(line)
            }
        }
        flush()
        return blocks
    }
}

@Suite("组合根装配契约（视图消费 @Environment(T.self) ⟹ 该平台组合根必须装配）")
struct EnvironmentInjectionContractTests {
    @Test("(a) 视图读的 App 级对象，其平台对应的组合根必须有一行 `.environment(…)`")
    func compositionRootsInjectEveryConsumedObject() throws {
        let consumed = try EnvironmentInjectionContract.consumedByPlatform()

        var missing: [String] = []
        for (platform, rootPath) in EnvironmentInjectionContract.roots.map({ ($0.platform, $0.path) }) {
            let source = try EnvironmentInjectionContract.rootSource(rootPath)
            for (type, files) in consumed[platform] ?? [:] {
                guard !EnvironmentInjectionContract.rootInjects(type, in: source) else { continue }
                missing.append(
                    "\(platform)：`\(rootPath)` 缺 `\(type)` 的装配"
                        + "（被 \(files.sorted().joined(separator: ", ")) 消费）→ "
                        + "补一行 `.environment(...)`，否则视图在**运行时会致命错**（编译与单测都发现不了）"
                )
            }
        }

        #expect(
            missing.isEmpty,
            """
            组合根装配缺口（视图用了 `@Environment(T.self)`，但该平台组合根没装配）：
            \(missing.sorted().joined(separator: "\n"))
            """
        )
    }

    @Test("(b) 扫描器自证：类型形式算、keyPath 形式不算、注释不算（fail-closed 反向验证）")
    func scannerSelfTest() {
        let source = """
        import SwiftUI
        struct Foo: View {
            // 整行注释里的 @Environment(AppServices.self) 不算
            @Environment(\\.appAccentColor) private var accentColor
            @Environment(AppServices.self) private var services
            var body: some View {
                Text("x") // 行尾注释 @Environment(Engine.self) 也不算
            }
        }
        """
        let types = EnvironmentInjectionContract.consumedTypes(in: source)
        #expect(types == ["AppServices"])
        #expect(EnvironmentInjectionContract.declaresSwiftUIView(source))

        let serviceSource = "import Foundation\nactor Foo { static let shared = Foo() }"
        #expect(!EnvironmentInjectionContract.declaresSwiftUIView(serviceSource))
        #expect(EnvironmentInjectionContract.consumedTypes(in: serviceSource).isEmpty)

        // 装配行判据：`Foo` 不得被 `FooBar` 的装配行误判为已装配
        #expect(EnvironmentInjectionContract.rootInjects("AppServices", in: ".environment(AppServices.live)"))
        #expect(EnvironmentInjectionContract.rootInjects("Foo", in: ".environment(FooBar.shared)") == false)
        #expect(EnvironmentInjectionContract.rootInjects("Foo", in: ".environment(Foo.shared)") == true)
        // **注释行不算**：把装配行注掉必须判为未装配（首次实现漏此口径 → 反向验证假绿）
        #expect(EnvironmentInjectionContract.rootInjects("AppServices", in: "// .environment(AppServices.live)") == false)
        #expect(
            EnvironmentInjectionContract.rootInjects(
                "AppServices",
                in: "// 漏了这一行的后果：视图 `@Environment(AppServices.self)` 会运行时致命错"
            ) == false
        )
    }
}

@Suite("手工 hosting 根装配契约（NSHostingView 承载的视图 ⟹ 构造方必须自己装配环境）")
struct ManualHostingEnvironmentContractTests {
    @Test("(a) 手工 hosting 根必须装配内容视图读的 App 级对象（场景环境到不了这里）")
    func manualHostingRootsInjectConsumedObjects() throws {
        let consumedByViewType = try EnvironmentInjectionContract.consumedTypesByViewType()
        let prefix = EnvironmentInjectionContract.repositoryRoot.path + "/"
        var scanned = 0
        var missing: [String] = []

        for url in try EnvironmentInjectionContract.swiftFiles() {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard EnvironmentInjectionContract.buildsManualHostingRoot(source) else { continue }
            scanned += 1
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            let gaps = EnvironmentInjectionContract.hostingGaps(
                in: source,
                consumedByViewType: consumedByViewType
            )
            for type in gaps.missing {
                missing.append(
                    "`\(relative)` 手工 hosting 了 \(gaps.hosted.joined(separator: ", "))"
                        + "，但没装配 `\(type)` → 手工 hosting 的内容**不继承 App 场景环境**，"
                        + "运行时会致命错（编译与单测都发现不了）"
                )
            }
        }

        #expect(
            missing.isEmpty,
            """
            手工 hosting 根的装配缺口（内容视图读 `@Environment(T.self)`，而构造方没注入 T）：
            \(missing.sorted().joined(separator: "\n"))
            """
        )
        // fail-closed：一个 hosting 根都没识别到 = 扫描器入口判据失效（写法变了），不是「没有缺口」。
        // 若这套浮窗机制被整体移除，本行应随之下线（而不是把断言删掉）。
        #expect(scanned > 0, "没识别到任何手工 hosting 根：入口判据可能已失效（fail-closed）")
    }

    @Test("(b) 扫描器自证：缺失必报、按名装配算、self 装配算、注释不算、泛型写法也算")
    func scannerSelfTest() {
        let consumed: [String: Set<String>] = ["MiniPlayer": ["Windows"], "Lyrics": []]

        func missing(_ source: String) -> [String] {
            EnvironmentInjectionContract.hostingGaps(in: source, consumedByViewType: consumed).missing
        }

        // 泛型 hosting 写法也算 hosting 根；缺装配 → 必须报
        let noInjection = """
        final class Windows {
            let host = NSHostingView<AnyView>(rootView: MiniPlayer())
        }
        """
        #expect(EnvironmentInjectionContract.buildsManualHostingRoot(noInjection))
        #expect(missing(noInjection) == ["Windows"])

        // 按名装配 → 不报
        #expect(missing("let r = NSHostingView(rootView: MiniPlayer().environment(Windows.shared))") == [])

        // `self` 装配（承载 hosting 的类型就是被消费的类型）→ 不报
        let selfInjection = """
        final class Windows {
            func rootView() -> some View {
                MiniPlayer().environment(self)
            }
        }
        """
        #expect(missing(selfInjection) == [])

        // `self` 但承载类型不是被消费的那个 → 必须报（防「随便一个 self 也算过」）
        let wrongSelf = """
        final class Other {
            let host = NSHostingView(rootView: MiniPlayer().environment(self))
        }
        """
        #expect(missing(wrongSelf) == ["Windows"])

        // 注释里的 hosting 入口 / 注释掉的装配 → 不算（否则注掉装配仍会假绿）
        #expect(!EnvironmentInjectionContract.buildsManualHostingRoot("// let h = NSHostingView(rootView: Lyrics())"))
        let commented = """
        let root = NSHostingView(rootView: MiniPlayer())
        // 漏了 .environment(self) 会崩（注释里提一次不算数）
        """
        #expect(missing(commented) == ["Windows"])

        // 内容视图不读环境对象 → 无要求
        #expect(missing("final class W { let h = NSHostingView(rootView: Lyrics()) }") == [])

        // 切块口径：同文件多视图按声明行切开，消费集合不得互相污染
        let twoViews = """
        struct MiniPlayer: View {
            @Environment(Windows.self) private var windows
            var body: some View { EmptyView() }
        }
        struct Lyrics: View {
            var body: some View { EmptyView() }
        }
        """
        let byType = EnvironmentInjectionContract.viewConsumedTypes(in: twoViews)
        #expect(byType["MiniPlayer"] == ["Windows"])
        #expect(byType["Lyrics"] == Set<String>())
    }
}

private extension EnvironmentInjectionContract {
    /// 单文件：视图类型 → 该类型读的 `@Environment(T.self)` 集合（纯函数，契约与自证共用一个口径）。
    static func viewConsumedTypes(in source: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for block in viewTypeBlocks(in: source) {
            result[block.name, default: []].formUnion(consumedTypes(in: block.body))
        }
        return result
    }
}
