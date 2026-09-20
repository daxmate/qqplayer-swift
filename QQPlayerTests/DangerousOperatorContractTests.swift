//
//  DangerousOperatorContractTests.swift
//  QQPlayerTests
//
//  「一崩了之」操作契约（2026-09-19 立，工程质量线）：`try!` / `as!` / `fatalError(`。
//
//  为什么需要：这三类写法把「可能失败」直接变成**崩溃**，而它们通常是**顺手**加上的
//  （不是设计决策）—— 加的人当下证明不了失败不可达，事后也没人复看。已有的棘轮
//  （直连单例 / @Observable 迁移 / 行数 / print）都覆盖不到它们。
//
//  本契约把存量**逐个钉死**：每一条剩余都必须能被审视，新增一条就红。
//    - 出现基线里没有的文件/写法          → 红（不许新加）
//    - 既有条目计数回涨（> 基线值）        → 红
//    - 既有条目计数下降（含归零）或文件消失 → 红（**名单不腐烂**：迁完必须同步改行）
//    - 合计 > TOTAL                        → 红
//
//  口径（两处坑都踩过，写下来免得再犯）：
//    1. **剥离注释与字符串**：注释里提到 `try!` 不算 —— 首次盘点就因此虚高（9 处命中里只有 6 处是真代码）；
//    2. `try?` / `as?` / `preconditionFailure(` **不计**：前两者不崩，后者是**收口后的目标写法**
//       （本批把 4 处 `try!`/`as!` 改成了带诊断的 `preconditionFailure`）。
//

import Foundation
import Testing

private enum DangerousOperatorContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"
    static let baselinePath = "QQPlayerTests/Fixtures/dangerous-operators-baseline.tsv"

    /// 受管写法（键名即基线里的「写法」列）。
    static let kinds: [(name: String, pattern: String)] = [
        ("try!", #"\btry!"#),
        ("as!", #"\bas!"#),
        ("fatalError", #"\bfatalError\s*\("#),
    ]

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case baselineUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path): return "契约测试无法枚举/读取（fail-closed）：\(path)"
            case .baselineUnreadable(let path): return "基线文件读不到（fail-closed）：\(path)"
            }
        }
    }

    /// 去掉字符串字面量与行注释后的代码。
    ///
    /// 必须两件都做：只剥注释时，字符串里的 `try!`（日志文案/测试夹具）仍会误计；
    /// 只剥字符串时，注释里的说明会误计（首版口径就是这样虚高的）。
    static func strippedCode(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var isInString = false
        var isEscaped = false
        var isInLineComment = false
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
            if isInString {
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
            if character == "\"" {
                isInString = true
                previous = character
                continue
            }
            if character == "/", previous == "/" {
                // 行注释起点：把已写出的那个 `/` 也撤掉
                if out.hasSuffix("/") { out.removeLast() }
                isInLineComment = true
                previous = character
                continue
            }
            out.append(character)
            previous = character
        }
        return out
    }

    struct Entry: Hashable {
        let path: String
        let kind: String
    }

    /// 生产代码里每个「文件 + 写法」的出现次数（只留 > 0 的）。
    static func detected() throws -> [Entry: Int] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        let prefix = repositoryRoot.path + "/"
        var result: [Entry: Int] = [:]

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = strippedCode(source)
            let path = url.path.replacingOccurrences(of: prefix, with: "")
            for (name, pattern) in kinds {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(code.startIndex ..< code.endIndex, in: code)
                let count = regex.numberOfMatches(in: code, range: range)
                if count > 0 { result[Entry(path: path, kind: name)] = count }
            }
        }
        return result
    }

    /// 基线：`路径<TAB>写法<TAB>计数`（`#` 开头为注释行）。
    static func baseline() throws -> [Entry: Int] {
        let url = repositoryRoot.appendingPathComponent(baselinePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.baselineUnreadable(baselinePath)
        }
        var result: [Entry: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count == 3, let count = Int(parts[2]) else { continue }
            result[Entry(path: parts[0], kind: parts[1])] = count
        }
        return result
    }
}

@Suite("危险操作契约（try! / as! / fatalError 存量只能减不能增）")
struct DangerousOperatorContractTests {
    @Test("(a) 实际存量与基线逐个相等：不许新增、也不许悄悄减少（名单不腐烂）")
    func detectedMatchesBaseline() throws {
        let actual = try DangerousOperatorContract.detected()
        let expected = try DangerousOperatorContract.baseline()

        var problems: [String] = []
        for (entry, count) in actual.sorted(by: { ($0.key.path, $0.key.kind) < ($1.key.path, $1.key.kind) }) {
            guard let base = expected[entry] else {
                problems.append("新增未登记：\(entry.path) 的 `\(entry.kind)` ×\(count) → 请改用可恢复写法；"
                    + "确属「不可达且已论证」的，才登记进基线并写明理由")
                continue
            }
            if count > base {
                problems.append("计数回涨：\(entry.path) 的 `\(entry.kind)` \(base) → \(count)（基线只能减不能增）")
            } else if count < base {
                problems.append("计数下降：\(entry.path) 的 `\(entry.kind)` \(base) → \(count)"
                    + "（**这是好事**：请把基线行改到实测值，否则本棘轮只会「防变差」不会「变好」）")
            }
        }
        for (entry, count) in expected.sorted(by: { ($0.key.path, $0.key.kind) < ($1.key.path, $1.key.kind) })
            where actual[entry] == nil {
            problems.append("基线项已不存在：\(entry.path) 的 `\(entry.kind)` ×\(count) → 请删掉该基线行")
        }

        #expect(
            problems.isEmpty,
            """
            危险操作契约不满足：
            \(problems.sorted().joined(separator: "\n"))
            """
        )
    }

    @Test("(b) 扫描器自证：注释/字符串不算；try? / as? / preconditionFailure 不算（fail-closed 反向验证）")
    func scannerSelfTest() throws {
        let source = """
        // 注释里的 try! 不算
        let a = try? risky()          // try? 不是崩溃路径
        let b = value as? String      // as? 不是崩溃路径
        let c = "字符串里的 try! as! fatalError( 不算"
        func boom() -> Never { preconditionFailure("收口后的目标写法，不计") }
        let d = try! risky()          // ← 这一条才算
        let e = obj as! String        // ← 这一条才算
        fatalError("这条也算")
        """
        let code = DangerousOperatorContract.strippedCode(source)

        // 剥离效果：注释与字符串字面量都不在剥离后的代码里
        #expect(!code.contains("注释里的"))
        #expect(!code.contains("字符串里的"))
        #expect(!code.contains("这一条才算"))

        /// 各写法在剥离后源码里的匹配数 —— 这才是契约真正依赖的口径
        /// （不要用 `code.contains("xxx")` 当代理：真实代码本来就该保留，会假红）。
        func matches(_ pattern: String) -> Int {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
            return regex.numberOfMatches(in: code, range: NSRange(code.startIndex ..< code.endIndex, in: code))
        }

        for (name, pattern) in DangerousOperatorContract.kinds {
            #expect(matches(pattern) == 1, "受管写法 `\(name)` 在自证源码里应恰好匹配 1 处")
        }
        // 非崩溃路径 / 收口目标写法：**存在但不受任何受管模式管辖**
        #expect(matches(#"\btry\?"#) == 1)
        #expect(matches(#"\bas\?"#) == 1)
        #expect(matches(#"\bpreconditionFailure\s*\("#) == 1)
    }
}
