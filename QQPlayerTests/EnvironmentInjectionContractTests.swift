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
//  合法例外：视图文件的 `#Preview` 是第二个装配点（preview 不继承场景环境），本契约只管组合根，
//  与直连单例棘轮的口径一致（见 `shared-singleton-budget-plan.md` §五.2）。
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
