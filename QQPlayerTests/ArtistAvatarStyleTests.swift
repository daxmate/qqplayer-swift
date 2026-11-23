//
//  ArtistAvatarStyleTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  艺人头像纯文本规则的回归测试（2026-11-23）。规则本体是双 target 共享的
//  `QQPlayer/Services/ArtistAvatarStyle.swift`（macOS `MacArtistAvatarStyle` 现为
//  typealias，iOS `ArtistAvatarView` 直接复用）。
//
//  覆盖三块：
//  - `monogram`：空名 → `?`、中文原样、拉丁大写、前导空白跳过
//  - `paletteIndex`：同输入稳定、范围 0..<count、超长名不溢出、count ≤ 0 兜底
//  - `sanitizedFileName`：去路径分隔符 / 文件系统非法字符 / 控制符、trim、空 → `_`
//  另有形状守卫：三条规则只允许一处实现（防「再抄一份」）。
//

import Foundation
import Testing

@testable import QQPlayer

struct ArtistAvatarStyleTests {
    // MARK: - monogram

    @Test("monogram：空名 / 纯空白 → ?")
    func monogramEmpty() {
        #expect(ArtistAvatarStyle.monogram(for: "") == "?")
        #expect(ArtistAvatarStyle.monogram(for: "   ") == "?")
        #expect(ArtistAvatarStyle.monogram(for: "\n\t ") == "?")
    }

    @Test("monogram：中文原样，拉丁字母大写")
    func monogramScripts() {
        #expect(ArtistAvatarStyle.monogram(for: "周杰伦") == "周")
        #expect(ArtistAvatarStyle.monogram(for: "mayday") == "M")
        #expect(ArtistAvatarStyle.monogram(for: "bEYOND") == "B")
    }

    @Test("monogram：跳过前导空白")
    func monogramTrimsLeadingWhitespace() {
        #expect(ArtistAvatarStyle.monogram(for: "   Adele") == "A")
        #expect(ArtistAvatarStyle.monogram(for: "\n\t火星电台") == "火")
    }

    // MARK: - paletteIndex

    @Test("paletteIndex：同输入稳定（不依赖 hashValue 随机化）")
    func paletteIndexStable() {
        let first = ArtistAvatarStyle.paletteIndex(for: "Radiohead", paletteCount: 8)
        for _ in 0 ..< 20 {
            #expect(ArtistAvatarStyle.paletteIndex(for: "Radiohead", paletteCount: 8) == first)
        }
        // 已知值：Unicode 标量和 mod 8（锁定实现，防公式被悄悄改）
        #expect(ArtistAvatarStyle.paletteIndex(for: "A", paletteCount: 8) == 65 % 8)
    }

    @Test("paletteIndex：结果落在 0..<count")
    func paletteIndexRange() {
        let names = ["", "?", "周杰伦", "Mayday", "bEYOND", "a b c", "🎵🎶", "ÄÖÜ"]
        for name in names {
            for count in [1, 2, 5, 8] {
                let index = ArtistAvatarStyle.paletteIndex(for: name, paletteCount: count)
                #expect(index >= 0 && index < count, "\(name) / \(count) → \(index)")
            }
        }
    }

    @Test("paletteIndex：超长名字不溢出 / count ≤ 0 兜底 0")
    func paletteIndexEdgeCases() {
        let longName = String(repeating: "艺人", count: 20_000)
        let index = ArtistAvatarStyle.paletteIndex(for: longName, paletteCount: 8)
        #expect(index >= 0 && index < 8)
        #expect(ArtistAvatarStyle.paletteIndex(for: "A", paletteCount: 0) == 0)
        #expect(ArtistAvatarStyle.paletteIndex(for: "A", paletteCount: -3) == 0)
    }

    // MARK: - sanitizedFileName

    @Test("sanitizedFileName：去掉路径分隔符与文件系统非法字符")
    func sanitizedFileNameRemovesIllegal() {
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "AC/DC") == "ACDC")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "a:b") == "ab")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "a\\b") == "ab")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "a*b?c") == "abc")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "a\"b<c>d|e") == "abcde")
    }

    @Test("sanitizedFileName：去换行 / 回车 / 制表符、trim 首尾空白")
    func sanitizedFileNameTrimsAndStripsControl() {
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "  Adele  ") == "Adele")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "A\nB\rC\tD") == "ABCD")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "\n\tRadiohead\r") == "Radiohead")
        // ⚠️ 既有 macOS 规则的非法字符集只含 \n / \r / \t 这三个控制符，其余控制符原样保留。
        // 本任务要求「原样搬」⇒ 不擅自扩大清洗集；要扩展必须先改 macOS 行为（待 maintainer 决策）。
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "A\u{0000}B") == "A\u{0000}B")
    }

    @Test("sanitizedFileName：清洗后为空 → _")
    func sanitizedFileNameEmptyFallback() {
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "") == "_")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "   ") == "_")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "///") == "_")
    }

    @Test("sanitizedFileName：正常中文 / 空格 / 点号原样保留")
    func sanitizedFileNameKeepsLegal() {
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "周杰伦") == "周杰伦")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "Simon & Garfunkel") == "Simon & Garfunkel")
        #expect(ArtistAvatarStyle.sanitizedFileName(for: "Mr.Children") == "Mr.Children")
    }

    // MARK: - 形状守卫：三条规则只允许一处实现

    @Test("规则只允许一处实现（禁止第二份 monogram / 配色 / 清洗逻辑）")
    func singleImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("QQPlayer", isDirectory: true)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }

        // 只看「实现签名」，调用点（如 `ArtistAvatarStyle.monogram(for:)`）不含这些串
        let signatures = [
            "static func paletteIndex(for name: String, paletteCount: Int) -> Int {",
            "static func monogram(for name: String) -> String {",
            "static func sanitizedFileName(for name: String) -> String {",
        ]
        for signature in signatures {
            var hits: [String] = []
            for relative in files {
                let url = directory.appendingPathComponent(relative)
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if source.contains(signature) {
                    hits.append(relative)
                }
            }
            #expect(hits == ["Services/ArtistAvatarStyle.swift"], "\(signature) 实现位置 → \(hits)")
        }
    }
}
