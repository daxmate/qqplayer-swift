//
//  StructuralBudgetRule.swift
//  QQPlayerTests
//
// target: ios-only
//
//  结构预算棘轮的**唯一口径实现**（2026-09-19 立）。
//
//  为什么单独成文件、且**不 import Testing**：
//  口径必须能被**脱离模拟器直编**——`swiftc` 直编本文件即可生成/校验基线（命令见
//  `Fixtures/structural-budget-*.tsv` 头部），否则基线只能手抄，而手抄必然与检测漂移
//  （「同一语义多处手工维护」的老毛病）。本文件是本仓库唯一的「结构计数」口径实现：
//  测试文件、基线生成、本地 harness 全部走这里的函数，别处不得再写一份。
//
//  两条预算：
//   ① 文件行数：单文件 > 600 行属超长，名单钉成基线（只能减不能增）
//   ② 裸 `print(`：诊断输出必须走统一出口（`AppLog`），存量钉成基线（只能减不能增）
//
//  为什么立棘轮而不是直接批量重构：2026-09-17 的教训——**审计结论必须落到「机器会红的
//  机制」上，否则第 N 轮审计结论与第 1 轮完全相同**。本轮只立棘轮、不动生产代码，
//  把存量钉死、把新增拦住；清债是后续批次的事（清一处就必须同步改基线行）。
//

import Foundation

/// 一条基线：`路径<TAB>计数` + `# TOTAL: <数字>`。
struct StructuralBudgetBaseline: Equatable {
    var total: Int
    var perFile: [String: Int]

    enum ParseError: Error, CustomStringConvertible {
        case malformed(String)
        case totalMissing

        var description: String {
            switch self {
            case .malformed(let line):
                return "基线格式错误（fail-closed）：\(line)"
            case .totalMissing:
                return "基线缺少 `# TOTAL: <数字>` 行（fail-closed）"
            }
        }
    }

    static func parse(_ text: String) throws -> StructuralBudgetBaseline {
        var perFile: [String: Int] = [:]
        var total: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let body = line.dropFirst()
                if let range = body.range(of: "TOTAL:") {
                    let value = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    total = Int(value)
                }
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw ParseError.malformed(line)
            }
            perFile[String(parts[0]).trimmingCharacters(in: .whitespaces)] = count
        }
        guard let total else { throw ParseError.totalMissing }
        return StructuralBudgetBaseline(total: total, perFile: perFile)
    }

    var rendered: String {
        let rows = perFile.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }
        return rows.joined(separator: "\n")
    }
}

/// 结构预算棘轮：口径 + 四条契约判定（纯逻辑，返回违规清单）。
enum StructuralBudgetRule {
    /// 扫描范围（相对仓库根）。
    static let scannedDirectory = "QQPlayer"
    /// 超长文件阈值（行）。
    static let fileSizeThreshold = 600
    /// 唯一日志出口的相对路径：允许自身含 `print(`。AppLog 落地后把它的路径加进来。
    static let printWhitelist: Set<String> = []

    /// 仓库根（本文件位于 `<root>/QQPlayerTests/`）。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - 口径（改这里 = 改口径；基线由本口径生成）

    /// 行数口径：与 `wc -l` 一致（结尾换行不算额外一行；空文件 0 行）。
    static func lines(in source: String) -> Int {
        guard !source.isEmpty else { return 0 }
        let newlines = source.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return source.hasSuffix("\n") ? newlines : newlines + 1
    }

    /// 裸 `print(` 口径：先剥掉 `//` 之后的行尾注释，再数 `print(` 出现次数。
    /// 与 `grep 'print('` 同口径（整行注释不计；字符串字面量里的 `print(` 会误计，已知且可接受）。
    static func printCalls(in source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { partial, rawLine in
            let code = rawLine.components(separatedBy: "//").first ?? ""
            return partial + occurrences(of: "print(", in: code)
        }
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart ..< haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    // MARK: - 扫描 / 检测

    /// 仓库内 `QQPlayer/**/*.swift` 的相对路径（按路径排序）。
    /// 注意：先解析符号链接再算相对路径——`FileManager` 枚举返回的是**已解析**路径，
    /// 若 root 本身带软链（macOS `/tmp`、`/var`→`/private/...`）直接用 root.path 做前缀
    /// 会拼出不存在的相对路径（本地 harness 实测踩到）。
    static func sourcePaths(repositoryRoot root: URL = repositoryRoot) throws -> [String] {
        let directory = root.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            paths.append(url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: ""))
        }
        return paths.sorted()
    }

    /// 检测结果：`路径 → 计数`（只含计数 > 0 的文件）。`measure` 决定测什么（行数 / print 数）。
    static func detected(
        repositoryRoot root: URL = repositoryRoot,
        excluding whitelist: Set<String> = [],
        measure: (String) -> Int
    ) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for relativePath in try sourcePaths(repositoryRoot: root) {
            guard !whitelist.contains(relativePath) else { continue }
            let url = root.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let value = measure(source)
            guard value > 0 else { continue }
            result[relativePath] = value
        }
        return result
    }

    /// 超长文件检测（行数 > 阈值）。
    static func detectedOversizedFiles(repositoryRoot root: URL = repositoryRoot) throws -> [String: Int] {
        try detected(repositoryRoot: root, measure: lines).filter { $0.value > fileSizeThreshold }
    }

    /// 裸 print 检测（带唯一出口白名单）。
    static func detectedPrintCalls(repositoryRoot root: URL = repositoryRoot) throws -> [String: Int] {
        try detected(repositoryRoot: root, excluding: printWhitelist, measure: printCalls)
    }

    // MARK: - 四条契约（fail-closed：基线自相矛盾也红）

    /// 判定并返回违规描述（空数组 = 通过）。`name` / `unit` 只用于错误文案。
    static func violations(
        detected: [String: Int],
        baseline: StructuralBudgetBaseline,
        name: String,
        unit: String,
        allowNewEntries: Bool = false,
        repositoryRoot root: URL = repositoryRoot
    ) -> [String] {
        var problems: [String] = []

        let added = detected.keys.filter { baseline.perFile[$0] == nil }.sorted()
        if !added.isEmpty, !allowNewEntries {
            problems.append(
                "新增了\(name)（基线里没有这些文件）：\(added)。"
                    + "请改走已有入口；确需登记则把行加进基线并在提交信息里说明理由。"
            )
        }

        let grown = detected.compactMap { path, value -> String? in
            guard let base = baseline.perFile[path], value > base else { return nil }
            return "\(path): \(base) → \(value)\(unit)"
        }.sorted()
        if !grown.isEmpty {
            problems.append("\(name)回涨（只能减不能增）：\(grown)")
        }

        var stale: [String] = []
        for (path, base) in baseline.perFile {
            let fileURL = root.resolvingSymlinksInPath().appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                stale.append("\(path)（文件已不存在）")
                continue
            }
            let actual = detected[path] ?? 0
            if actual < base {
                stale.append("\(path): \(base) → \(actual)\(unit)")
            }
        }
        if !stale.isEmpty {
            problems.append("基线名单腐烂（已减少/归零，须同步改行或删行）：\(stale.sorted())")
        }

        let actualTotal = detected.values.reduce(0, +)
        if actualTotal > baseline.total {
            problems.append("总数回涨：基线 TOTAL \(baseline.total) → 实测 \(actualTotal)")
        }
        let baselineSum = baseline.perFile.values.reduce(0, +)
        if baselineSum != baseline.total {
            problems.append("基线自相矛盾：各行合计 \(baselineSum) ≠ TOTAL \(baseline.total)")
        }
        return problems
    }

    /// 读 fixture 基线（读不到/格式错 = 抛错 → 测试红，绝不静默通过）。
    static func baseline(at relativePath: String, repositoryRoot root: URL = repositoryRoot) throws -> StructuralBudgetBaseline {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try StructuralBudgetBaseline.parse(try String(contentsOf: url, encoding: .utf8))
    }

    static let sizeBaselinePath = "QQPlayerTests/Fixtures/structural-budget-size-baseline.tsv"
    static let printBaselinePath = "QQPlayerTests/Fixtures/structural-budget-print-baseline.tsv"
}
