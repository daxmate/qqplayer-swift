//
//  DeleteSettingsScrapingTests.swift
//  QQPlayerTests
//
//  DeleteSettings 刮削三字段（E1-S4）decode 兜底防回归：
//  - 旧数据（JSON 缺新 key）→ 默认值：scrapingRenameTemplate = "{artist} - {title}"、
//    scrapingSourceOrder = [netease, musicbrainz]、scrapingBatchEnabled = false
//  - 显式值 round-trip（encode → decode 不丢）
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct DeleteSettingsScrapingTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test("空 JSON（模拟旧版存储）decode → 三字段全部回落默认")
    func emptyJSONAppliesDefaults() throws {
        let settings = try decoder.decode(DeleteSettings.self, from: Data("{}".utf8))
        #expect(settings.scrapingRenameTemplate == TagWriterService.defaultRenameTemplate)
        #expect(settings.scrapingSourceOrder == ["netease", "musicbrainz"])
        #expect(settings.scrapingBatchEnabled == false)
    }

    @Test("显式存值 round-trip：encode → decode 值不丢")
    func storedValuesRoundTrip() throws {
        var original = DeleteSettings()
        original.scrapingRenameTemplate = "{track} - {title}"
        original.scrapingSourceOrder = ["musicbrainz", "netease"]
        original.scrapingBatchEnabled = true

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DeleteSettings.self, from: data)

        #expect(decoded.scrapingRenameTemplate == "{track} - {title}")
        #expect(decoded.scrapingSourceOrder == ["musicbrainz", "netease"])
        #expect(decoded.scrapingBatchEnabled == true)
    }

    @Test("部分缺 key 的 JSON（只存了模板）→ 其它两字段回落默认")
    func partialJSONAppliesDefaultsForMissingKeys() throws {
        let json = """
        {"scrapingRenameTemplate": "{album}/{artist} - {title}"}
        """
        let settings = try decoder.decode(DeleteSettings.self, from: Data(json.utf8))
        #expect(settings.scrapingRenameTemplate == "{album}/{artist} - {title}")
        #expect(settings.scrapingSourceOrder == ["netease", "musicbrainz"])
        #expect(settings.scrapingBatchEnabled == false)
    }
}
