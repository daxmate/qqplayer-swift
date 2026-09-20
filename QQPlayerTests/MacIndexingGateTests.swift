//  MacIndexingGateTests.swift
//  QQPlayerTests
//
//  macOS 音乐库扫描状态决策防回归测试（MacIndexingGate）。
//
//  背景（2026-08-31 首测 bug）：startMacScan() 未置 isIndexing=true → scanMusicFolder
//  首行 guard 直接拦截 → 扫描从未执行、音乐库永远为空（用户放歌不进库的根因）。
//
//  两层覆盖（2026-09-20 补第二层，测试债批 ⑤）：
//   ① 纯谓词行为（本文件上半，原有 6 条）：shouldBeginScan / canProceedScan 的真值表。
//   ② **接线/形状**（本文件下半 `MacIndexingGateWiringTests`）：谓词**被谁调用**、
//      `isIndexing` **被谁写**、顺序对不对。
//
//  为什么必须补 ②（审计结论）：本文件头原先声称「任何人删掉 start 处的 isIndexing=true，
//  CI 立即变红」，但 6 条用例只调纯谓词、从不触碰接线点 `LibraryIndexer+Scanning.swift`
//  / `LibraryIndexer.swift` —— 把 `markScanStarted()` 从 startMacScan 里删掉，
//  谓词测试**照样全绿**，而这正是 2026-08-31 那个「扫描从未执行」bug 的形状。
//  曲线：纯谓词覆盖涨了，真正会出事的那行反而没人管。
//

import Foundation
import Testing

@testable import QQPlayer

struct MacIndexingGateTests {
    // MARK: - shouldBeginScan

    @Test("未在扫描：应该开始扫描")
    func notIndexingShouldBegin() {
        #expect(MacIndexingGate.shouldBeginScan(currentlyIndexing: false))
    }

    @Test("已在扫描：不应重复启动")
    func alreadyIndexingShouldNotBegin() {
        #expect(!MacIndexingGate.shouldBeginScan(currentlyIndexing: true))
    }

    // MARK: - canProceedScan

    @Test("代次匹配 + isIndexing=true：扫描可继续")
    func generationMatchAndIndexingProceeds() {
        #expect(MacIndexingGate.canProceedScan(generationMatches: true, isIndexing: true))
    }

    @Test("isIndexing=false（start 未置 true，历史 bug 场景）：扫描被拦截")
    func missingIsIndexingBlocksScan() {
        #expect(!MacIndexingGate.canProceedScan(generationMatches: true, isIndexing: false))
    }

    @Test("代次不匹配（stop()/offline 切换后）：扫描被拦截")
    func staleGenerationBlocksScan() {
        #expect(!MacIndexingGate.canProceedScan(generationMatches: false, isIndexing: true))
    }

    @Test("代次不匹配 + isIndexing=false：扫描被拦截")
    func staleGenerationAndNoIndexingBlocksScan() {
        #expect(!MacIndexingGate.canProceedScan(generationMatches: false, isIndexing: false))
    }
}

// MARK: - ② 接线 / 形状（审计 P1-10 补：谓词**被谁调用**、`isIndexing`**被谁写**、顺序对不对）

/// 接线契约的读源码基建（fail-closed：读不到 = 红，绝不静默通过）。
private enum MacIndexingGateWiring {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scanningPath = "QQPlayer/Services/LibraryIndexer+Scanning.swift"
    static let indexerPath = "QQPlayer/Services/LibraryIndexer.swift"
    static let gatePath = "QQPlayer/Services/MacIndexingGate.swift"

    enum WiringError: Error, CustomStringConvertible {
        case sourceUnreadable(String)
        case functionNotFound(String)
        case scanAreaTooSmall(Int)

        var description: String {
            switch self {
            case .sourceUnreadable(let path): return "接线契约读不到源码（fail-closed）：\(path)"
            case .functionNotFound(let name): return "接线契约定位不到函数体（fail-closed）：\(name)"
            case .scanAreaTooSmall(let count):
                return "接线契约扫描面塌陷（fail-closed）：只枚举到 \(count) 个 Swift 文件"
            }
        }
    }

    static let scannedDirectory = "QQPlayer"
    /// 扫描面下限（防“目录枚举失败但返回空数组”把唯一写入入口变成恒真）
    static let minimumScannedFiles = 100

    static func source(at relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WiringError.sourceUnreadable(relativePath)
        }
        return text
    }

    /// 剥掉行注释 / 块注释，只留代码。
    /// 为什么必须剥：文档注释里就写着「isIndexing 置 true」（历史 bug 描述），
    /// 不剥的话「写入唯一入口」的扫描会把注释当代码 —— 判据会虚高到看不出真变化。
    static func strippedCode(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var isInString = false
        var isEscaped = false
        var isInLineComment = false
        var isInBlockComment = false
        var previous: Character?

        for character in source {
            if isInLineComment {
                if character == "\n" {
                    isInLineComment = false
                    out.append(character)
                }
                previous = character
                continue
            }
            if isInBlockComment {
                if previous == "*", character == "/" { isInBlockComment = false }
                previous = character
                continue
            }
            if isInString {
                out.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                previous = character
                continue
            }
            if previous == "/", character == "/" {
                out.removeLast()
                isInLineComment = true
                previous = character
                continue
            }
            if previous == "/", character == "*" {
                out.removeLast()
                isInBlockComment = true
                previous = character
                continue
            }
            if character == "\"" { isInString = true }
            out.append(character)
            previous = character
        }
        return out
    }

    /// 取出函数体（含外层大括号）。用**大括号计数**定位结尾，不用“找第一个 }”（会被嵌套块骗）。
    static func functionBody(named name: String, in source: String) throws -> String {
        let code = strippedCode(source)
        guard let declaration = code.range(of: "func \(name)("), let openBrace = code[declaration.lowerBound...].firstIndex(of: "{") else {
            throw WiringError.functionNotFound(name)
        }
        var depth = 0
        var index = openBrace
        while index < code.endIndex {
            let character = code[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(code[openBrace ... index]) }
            }
            index = code.index(after: index)
        }
        throw WiringError.functionNotFound(name)
    }

    struct WriteSite: Hashable {
        let path: String
        let function: String
        let value: String
    }

    /// 全仓扫 `isIndexing` **赋值**点（读点不算），并回溯它所在的函数名。
    static func isIndexingWriteSites() throws -> [WriteSite] {
        let root = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw WiringError.scanAreaTooSmall(0)
        }
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        guard urls.count >= minimumScannedFiles else {
            throw WiringError.scanAreaTooSmall(urls.count)
        }

        let assignment = try NSRegularExpression(pattern: "^\\s*=\\s*(true|false)\\b")
        var sites: [WriteSite] = []

        for url in urls {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = strippedCode(raw)
            let relative = scannedDirectory + "/" + url.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )
            var searchStart = code.startIndex
            while let match = code.range(of: "isIndexing", range: searchStart ..< code.endIndex) {
                let tail = String(code[match.upperBound...].prefix(24))
                let full = NSRange(tail.startIndex ..< tail.endIndex, in: tail)
                // 排除声明行本身（`private(set) var isIndexing = false` 也会命中赋值正则，
                // 但它不是“写点”，属性声明由本文件另一条断言锁）——取同一行 match 之前的文字判定。
                let lineStart = code[code.startIndex ..< match.lowerBound].lastIndex(of: "\n").map {
                    code.index(after: $0)
                } ?? code.startIndex
                let beforeOnLine = String(code[lineStart ..< match.lowerBound])
                let isDeclaration = beforeOnLine.range(of: #"\bvar\s+$"#, options: .regularExpression) != nil
                if !isDeclaration, let hit = assignment.firstMatch(in: tail, range: full) {
                    let value = (tail as NSString).substring(with: hit.range(at: 1))
                    let function = enclosingFunctionName(at: match.lowerBound, in: code) ?? "<顶层>"
                    sites.append(WriteSite(path: relative, function: function, value: value))
                }
                searchStart = match.upperBound
            }
        }
        return sites.sorted { ($0.path, $0.function) < ($1.path, $1.function) }
    }

    /// 向上找最近的 `func ` 声明，返回函数名。
    static func enclosingFunctionName(at index: String.Index, in code: String) -> String? {
        let prefix = code[code.startIndex ..< index]
        guard let range = prefix.range(of: "func ", options: .backwards) else { return nil }
        let name = prefix[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

@Suite("MacIndexingGate 接线：谓词被谁调用 · isIndexing 被谁写")
struct MacIndexingGateWiringTests {
    private typealias Wiring = MacIndexingGateWiring

    @Test("startMacScan：先置状态（markScanStarted）再起扫描（scanMusicFolder）—— 历史 bug 的形状")
    func startMacScanSetsStateBeforeScanning() throws {
        let body = try Wiring.functionBody(named: "startMacScan", in: Wiring.source(at: Wiring.scanningPath))

        #expect(body.contains("markScanStarted()"))
        #expect(body.contains("scanMusicFolder("))
        guard let stateAt = body.range(of: "markScanStarted()"),
              let scanAt = body.range(of: "scanMusicFolder(") else {
            Issue.record("startMacScan 缺少 markScanStarted()/scanMusicFolder() —— 这正是 2026-08-31 bug 的形状（未置状态就起扫描）")
            return
        }
        #expect(stateAt.lowerBound < scanAt.lowerBound)
    }

    @Test("startMacScan：启动决策走 MacIndexingGate.shouldBeginScan（不是裸 !isIndexing）")
    func startMacScanDecisionGoesThroughTheGate() throws {
        let body = try Wiring.functionBody(named: "startMacScan", in: Wiring.source(at: Wiring.scanningPath))
        #expect(body.contains("MacIndexingGate.shouldBeginScan("))
    }

    @Test("scanMusicFolder：guard 走 MacIndexingGate.canProceedScan，且在取文件（findMusicFiles）之前")
    func scanMusicFolderGuardsThroughTheGate() throws {
        let body = try Wiring.functionBody(named: "scanMusicFolder", in: Wiring.source(at: Wiring.scanningPath))

        #expect(body.contains("MacIndexingGate.canProceedScan("))
        #expect(body.contains("generationMatches: generation == indexingGeneration"))
        #expect(body.contains("isIndexing: isIndexing"))
        guard let guardAt = body.range(of: "MacIndexingGate.canProceedScan("),
              let filesAt = body.range(of: "findMusicFiles(") else {
            Issue.record("scanMusicFolder 缺少首行 gate 或取文件调用（fail-closed）")
            return
        }
        #expect(guardAt.lowerBound < filesAt.lowerBound)
    }

    @Test("isIndexing 写入唯一入口 = markScanStarted / markScanEnded（且属性是 private(set)）")
    func isIndexingHasSingleWriter() throws {
        let sites = try Wiring.isIndexingWriteSites()

        #expect(sites.count == 2)
        #expect(Set(sites.map(\.function)) == ["markScanStarted", "markScanEnded"])
        #expect(Set(sites.map(\.path)) == [Wiring.indexerPath])
        #expect(Set(sites.map(\.value)) == ["true", "false"])

        // private(set) 才是「唯一入口」在编译期的保障；改成 var 就变成“约定”了
        let indexer = Wiring.strippedCode(try Wiring.source(at: Wiring.indexerPath))
        #expect(indexer.contains("private(set) var isIndexing"))
    }

    @Test("谓词定义在位：接线点引用的两个纯函数仍在 MacIndexingGate 里")
    func gatePredicatesStillExist() throws {
        let source = try Wiring.source(at: Wiring.gatePath)
        // 接线点写的是名字，谓词被删/改名 → 编译就红了；这里锁的是“定义仍在同一个文件”
        #expect(source.contains("func shouldBeginScan("))
        #expect(source.contains("func canProceedScan("))
    }
}
