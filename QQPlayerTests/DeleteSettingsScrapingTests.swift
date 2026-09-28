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

// MARK: - 曲库位置单值化（M2，2026-09-28）

/// M2：`libraryFolders`（多根，已退役）→ `libraryRoot`（单值）的迁移防回归。
/// - 旧数据只有 `libraryFolders`（非空）→ 取**首项**；
/// - 旧空数组 / 完全没有该字段 → 空串（= 默认 `~/Music/QQPlayer`）；
/// - 新字段存在 → 以新字段为准（旧多根被忽略）；
/// - 旧字段**不再写回**（encode 结果不含 `libraryFolders`）。
@Suite(.serialized)
struct DeleteSettingsLibraryRootTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test("旧多根 [a, b] + 无新字段 → 取首项 a")
    func legacyMultipleFoldersTakesFirst() throws {
        let json = #"{"libraryFolders": ["/Volumes/A", "/Volumes/B"]}"#
        let settings = try decoder.decode(DeleteSettings.self, from: Data(json.utf8))
        #expect(settings.libraryRoot == "/Volumes/A")
    }

    @Test("旧空数组 + 无新字段 → 空串（默认根）")
    func legacyEmptyFoldersIsDefault() throws {
        let settings = try decoder.decode(DeleteSettings.self, from: Data(#"{"libraryFolders": []}"#.utf8))
        #expect(settings.libraryRoot.isEmpty)
    }

    @Test("完全没有曲库字段（最老数据）→ 空串（默认根）")
    func missingFieldIsDefault() throws {
        let settings = try decoder.decode(DeleteSettings.self, from: Data("{}".utf8))
        #expect(settings.libraryRoot.isEmpty)
    }

    @Test("新字段存在 → 以新字段为准（旧多根被忽略）")
    func newFieldWinsOverLegacy() throws {
        let json = #"{"libraryRoot": "/Volumes/New", "libraryFolders": ["/Volumes/Old"]}"#
        let settings = try decoder.decode(DeleteSettings.self, from: Data(json.utf8))
        #expect(settings.libraryRoot == "/Volumes/New")
    }

    @Test("新字段 round-trip：encode → decode 值不丢")
    func libraryRootRoundTrip() throws {
        var original = DeleteSettings()
        original.libraryRoot = "/Volumes/Music/Library"
        let decoded = try decoder.decode(DeleteSettings.self, from: try encoder.encode(original))
        #expect(decoded.libraryRoot == "/Volumes/Music/Library")
    }

    @Test("旧字段不再写回：encode 结果不含 libraryFolders")
    func legacyFieldIsNotEncoded() throws {
        var original = DeleteSettings()
        original.libraryRoot = "/Volumes/Music/Library"
        let json = String(data: try encoder.encode(original), encoding: .utf8) ?? ""
        #expect(!json.contains("libraryFolders"))
        #expect(json.contains("libraryRoot"))
    }
}
