//
//  MacLibraryRootSingleSourceContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-09-28 立，用户拍板「曲库只能有一个地址」）。
//
//  **契约**：macOS 曲库根（默认位置）的定义只允许一处 ——
//  `MusicFolderResolver.macDefaultFolderURL(homeDirectory:)`。
//  其他任何 `QQPlayer/**` 源文件直接调用它 = 又一个「根在哪」的事实源
//  （封面解析散落 5 处的教训：修 3 处漏 2 处 ⇒ 症状随机复发）。
//
//  收口后：默认根的定义留在 `MusicFolderResolver`；对本根做 IO 的唯一入口是
//  `QQPlayer/Mac/MacLibraryRoot.swift`；消费者一律走
//  `MacLibraryRoot.resolvedRootURL`（Mac 侧）或 `MusicFolderResolver.macLibraryRootURL`（纯逻辑）。
//
//  **口径**：扫描范围 = 全部 `QQPlayer/**/*.swift`；**先剥注释与字符串字面量**再找
//  `macDefaultFolderURL(` 出现点。剥注释/字符串是必须的：不剥的话注释里提到的写法会
//  骗绿（组合根装配契约同款教训，2026-09-19）。
//

import Foundation
import Testing

private enum MacLibraryRootSingleSourceContract {
    /// 仓库根（`#filePath` 上两级 = QQPlayerTests/ → 仓库根）。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"
    /// 唯一允许出现的调用/定义形态。
    static let marker = "macDefaultFolderURL("

    /// 允许出现该调用/定义的文件（仓库相对路径）。
    static let whitelist: Set<String> = [
        "QQPlayer/Services/MusicFolderResolver.swift",
        "QQPlayer/Mac/MacLibraryRoot.swift",
    ]

    /// 剥掉注释（行 / 块）与字符串字面量，只留代码。
    /// 为什么必须剥：否则注释 / 字面量里的写法会把扫描骗绿（假阴性）。
    static func codeOnly(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        let end = source.endIndex
        var inString = false
        var inBlockComment = false
        var inLineComment = false
        while i < end {
            let c = source[i]
            let nextIndex = source.index(after: i)
            let next: Character = nextIndex < end ? source[nextIndex] : "\0"
            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next == "/" {
                    inBlockComment = false
                    i = nextIndex
                }
            } else if inString {
                if c == "\\" {
                    i = nextIndex // 跳过被转义字符
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "/", next == "/" {
                inLineComment = true
                i = nextIndex
            } else if c == "/", next == "*" {
                inBlockComment = true
                i = nextIndex
            } else if c == "\"" {
                inString = true
            } else {
                out.append(c)
            }
            i = source.index(after: i)
        }
        return out
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

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举（fail-closed）：\(path)"
            }
        }
    }

    /// 白名单外直接调用 `macDefaultFolderURL(` 的文件（升序）。
    static func offenders() throws -> [String] {
        let prefix = repositoryRoot.path + "/"
        var offenders: [String] = []
        for url in try swiftFiles() {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if codeOnly(source).contains(marker), !whitelist.contains(relative) {
                offenders.append(relative)
            }
        }
        return offenders.sorted()
    }
}

struct MacLibraryRootSingleSourceContractTests {
    @Test("macOS 默认曲库根只允许一处定义/调用（白名单外出现即红）")
    func defaultRootHasSingleSource() throws {
        let offenders = try MacLibraryRootSingleSourceContract.offenders()
        #expect(
            offenders.isEmpty,
            "白名单外出现 macDefaultFolderURL( 调用点：\(offenders)（应改走 MacLibraryRoot.resolvedRootURL）"
        )
    }

    @Test("扫描器自证：代码里的写法检出；注释/字符串/块注释里的写法不算")
    func scannerSelfProof() {
        let codeOnly = MacLibraryRootSingleSourceContract.codeOnly
        // 真实代码里的调用 → 检出
        #expect(codeOnly("let x = MusicFolderResolver.macDefaultFolderURL(homeDirectory: h)").contains("macDefaultFolderURL("))
        // 行注释 → 不算（否则注释一写就骗绿）
        #expect(!codeOnly("// macDefaultFolderURL(homeDirectory:) 旧写法").contains("macDefaultFolderURL("))
        // 块注释 → 不算
        #expect(!codeOnly("/* macDefaultFolderURL(homeDirectory:) */").contains("macDefaultFolderURL("))
        // 字符串字面量 → 不算
        #expect(!codeOnly("let s = \"macDefaultFolderURL(homeDirectory:)\"").contains("macDefaultFolderURL("))
        // 转义引号不破坏后续代码的剥离
        #expect(codeOnly("let s = \"a\\\"b\"; let y = macDefaultFolderURL(x)").contains("macDefaultFolderURL("))
    }
}
