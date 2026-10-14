//
//  ScrapeSourceContractTests.swift
//  QQPlayerTests
//
//  刮削源**形状契约**（E2「刮削源收口 + 流式显示 + iTunes 备用源」批 2026-10）：
//  ① 每个 ScrapeSource 的 localizationKey 在 zh-Hans + en 两个 .strings 里都存在（防漏翻）
//  ② ScrapeBatchService.scrapeSources（注入 fake）返回的 key 集合 == ScrapeSource.allCases
//     （防漏源——任何新增源忘了接进唯一入口即红）
//
//  ① 走 #filePath 定位仓库根直读 .strings（QQPlayerTests 的 Resources phase 为空，
//  与其它形状契约同款）；② 用注入 seam，不发网络。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct ScrapeSourceContractTests {
    /// 仓库根（#filePath 上两级：QQPlayerTests/ → 仓库根）
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 解析 .strings 里 "key" = "value"; 行的 key 集合
    private static func keys(inLocalizationFile lang: String) throws -> Set<String> {
        let url = repoRoot
            .appendingPathComponent("QQPlayer/Resources/\(lang).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var keys = Set<String>()
        for line in text.split(separator: "\n") {
            guard let firstQuote = line.firstIndex(of: "\"") else { continue }
            let rest = line[line.index(after: firstQuote)...]
            guard let secondQuote = rest.firstIndex(of: "\"") else { continue }
            keys.insert(String(rest[..<secondQuote]))
        }
        return keys
    }

    @Test("每个 ScrapeSource 的 localizationKey 在 zh-Hans / en .strings 中都存在（防漏翻）")
    func everySourceHasLocalizationKey() throws {
        for lang in ["zh-Hans", "en"] {
            let keys = try Self.keys(inLocalizationFile: lang)
            for source in ScrapeSource.allCases {
                #expect(keys.contains(source.localizationKey), "\(lang) 缺 \(source.localizationKey)")
            }
        }
    }

    @Test("scrapeSources（注入 fake）返回的 key 集合 == ScrapeSource.allCases（防漏源）")
    func scrapeSourcesReturnsEverySource() async {
        let fake: ScrapeBatchService.ScrapeSourceSearch = { source, _, _ in
            [ScrapeCandidate(
                source: source.rawValue,
                id: "id",
                title: "t",
                artist: nil,
                album: nil,
                coverURL: nil,
                year: nil,
                genre: nil,
                track: nil,
                albumArtist: nil,
                durationMs: nil
            )]
        }
        let result = await ScrapeBatchService.scrapeSources(query: "q", artist: "a", search: fake)
        #expect(Set(result.keys) == Set(ScrapeSource.allCases))
        // 每源都拿到注入的候选（1 条）
        #expect(result.values.allSatisfy { $0.count == 1 })
    }
}
