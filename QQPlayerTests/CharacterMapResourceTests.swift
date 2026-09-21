//
//  CharacterMapResourceTests.swift
//  QQPlayerTests
//
//  P2-①（2026-09-17）简繁映射表下沉的**数据不变**证明 + 资源入包自证。
//
//  背景：两张表原本是 6900 行 Swift 字面量，下沉为资源文件（QQPlayer/Resources/*.tsv）后，
//  「数据一字不变」必须由测试守住，不能靠人核对：
//  - 基线夹具 `QQPlayerTests/Fixtures/{simplified-to-traditional,traditional-to-simplified}.baseline.tsv`
//    由 scripts/gen-character-maps.sh 在改造前从**原字面量** dump（码点升序 `键\t值`），
//    与资源文件由同一次输出写成 → 基线哈希即「改造前」的哈希。
//  - 本文件断言：① 夹具哈希 == 记录值（夹具没被改过）
//                ② 运行期加载的表 == 夹具（逐键 + 全表规范化序列化哈希 + 条数）
//                ③ bundle 里的资源字节 == 夹具字节（资源没被重新生成/手改）
//                ④ 解析器 fail-closed（坏数据抛错，不静默吞/不返回空表）
//
//  ⚠️ 夹具不是测试包资源（QQPlayerTests 的 Resources phase 为空），走 #filePath 定位仓库根。
//
import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

struct CharacterMapResourceTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fixturesDirectory = repoRoot.appendingPathComponent("QQPlayerTests/Fixtures")

    /// 基线夹具（改造前由字面量 dump）
    static let baselineFileNames: [CharacterMapResourceLoader.Resource: String] = [
        .simplifiedToTraditional: "simplified-to-traditional.baseline.tsv",
        .traditionalToSimplified: "traditional-to-simplified.baseline.tsv",
    ]

    // MARK: - 规范化序列化（与 scripts/gen-character-maps.sh 同规则：按**码点**升序，末尾换行）

    static func scalarValue(_ character: Character) -> UInt32 {
        Array(character.unicodeScalars).first!.value
    }

    static func canonicalText(_ map: [Character: Character]) -> String {
        map.sorted { scalarValue($0.key) < scalarValue($1.key) }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n") + "\n"
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 夹具文件内容（磁盘字节 → UTF-8 文本）；读不到 = 测试环境坏了，直接失败
    static func baselineText(_ resource: CharacterMapResourceLoader.Resource) throws -> String {
        let url = fixturesDirectory.appendingPathComponent(baselineFileNames[resource]!)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 记录的基线哈希（`character-maps.baseline.sha256`：`<sha256>  <仓库相对路径>`）
    static func recordedBaselineHashes() throws -> [String: String] {
        let url = fixturesDirectory.appendingPathComponent("character-maps.baseline.sha256")
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let columns = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count == 2 else { continue }
            // 只留文件名（记录里是仓库相对路径）
            result[String(columns[1].split(separator: "/").last!)] = String(columns[0])
        }
        return result
    }

    static func baselineMap(_ resource: CharacterMapResourceLoader.Resource) throws -> [Character: Character] {
        try CharacterMapResourceLoader.parse(text: try baselineText(resource), resource: resource)
    }

    // MARK: - ① 基线夹具自证（没被改过）

    @Test("基线夹具哈希 == 记录值（夹具本身没被动过）")
    func baselineFixtureHashesMatchRecord() throws {
        let recorded = try Self.recordedBaselineHashes()
        #expect(recorded.count == 2, "基线哈希记录应有 2 条：\(recorded)")
        for resource in CharacterMapResourceLoader.Resource.allCases {
            let fileName = Self.baselineFileNames[resource]!
            let computed = Self.sha256Hex(try Self.baselineText(resource))
            #expect(recorded[fileName] == computed, "夹具 \(fileName) 与记录哈希不一致（夹具被改过？）")
        }
    }

    // MARK: - ② 加载的表 == 基线（逐键 + 哈希 + 条数）

    @Test("简→繁表 == 基线夹具（逐键 + 全表哈希）")
    func simplifiedToTraditionalMatchesBaseline() throws {
        let baseline = try Self.baselineMap(.simplifiedToTraditional)
        let loaded = simplifiedToTraditionalMap
        #expect(loaded.count == baseline.count, "条数不一致：加载 \(loaded.count) vs 基线 \(baseline.count)")
        let differing = baseline.filter { loaded[$0.key] != $0.value }
        #expect(differing.isEmpty, "逐键比对不一致 \(differing.count) 处：\(differing.prefix(5))")
        #expect(Self.sha256Hex(Self.canonicalText(loaded)) == Self.sha256Hex(Self.canonicalText(baseline)),
                "全表规范化序列化哈希不一致（数据变了）")
        // 特例修正必须还在（台→台，lrclib 等源收录「電台」）
        #expect(loaded["台"] == "台", "「台→台」特例丢了")
    }

    @Test("繁→简表 == 基线夹具（逐键 + 全表哈希）")
    func traditionalToSimplifiedMatchesBaseline() throws {
        let baseline = try Self.baselineMap(.traditionalToSimplified)
        let loaded = traditionalToSimplifiedMap
        #expect(loaded.count == baseline.count, "条数不一致：加载 \(loaded.count) vs 基线 \(baseline.count)")
        let differing = baseline.filter { loaded[$0.key] != $0.value }
        #expect(differing.isEmpty, "逐键比对不一致 \(differing.count) 处：\(differing.prefix(5))")
        #expect(Self.sha256Hex(Self.canonicalText(loaded)) == Self.sha256Hex(Self.canonicalText(baseline)),
                "全表规范化序列化哈希不一致（数据变了）")
    }

    // MARK: - ③ 资源入包自证（bundle 里的字节 == 夹具字节）

    @Test("bundle 里的资源 == 基线夹具（字节一致 = 进包的确实是同一份数据）")
    func bundledResourcesAreByteIdenticalToBaseline() throws {
        for resource in CharacterMapResourceLoader.Resource.allCases {
            let bundledText = try CharacterMapResourceLoader.readText(resource)
            let baselineText = try Self.baselineText(resource)
            #expect(Self.sha256Hex(bundledText) == Self.sha256Hex(baselineText),
                    "\(resource.fileName) 进包字节与基线不一致（资源被重新生成/手改？）")
            #expect(!bundledText.isEmpty, "\(resource.fileName) 为空")
        }
    }

    // MARK: - ④ 解析器 fail-closed（坏数据不许静默通过）

    @Test("解析器对坏数据抛错（多列 / 缺列 / 多标量键 / 重复键 / 空表）")
    func parserFailsClosedOnMalformedInput() throws {
        let bad: [(String, String)] = [
            ("a", "只有 1 列"),
            ("a\tb\tc\n", "3 列"),
            ("ab\tc\n", "键是多标量（2 个字符）"),
            ("a\tbc\n", "值是多标量"),
            ("a\tb\na\tc\n", "键重复"),
            ("", "空表"),
            ("\n\n", "只有空行 = 空表"),
        ]
        for (text, label) in bad {
            #expect(throws: (any Error).self, "坏数据未抛错：\(label)") {
                _ = try CharacterMapResourceLoader.parse(text: text, resource: .simplifiedToTraditional)
            }
        }
        // 合法输入照常解析（证明上面的抛错不是因为解析器一律抛错）
        let ok = try CharacterMapResourceLoader.parse(text: "台\t臺\n簡\t简\n", resource: .simplifiedToTraditional)
        #expect(ok.count == 2)
        #expect(ok["台"] == "臺")
    }

    // MARK: - 唯一入口：直连加载拿到的是同一张表（缓存不改变数据）
}
