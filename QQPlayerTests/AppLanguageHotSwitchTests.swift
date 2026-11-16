//
//  AppLanguageHotSwitchTests.swift
//  QQPlayerTests
//
//  设置 → 外观 → 语言：切换热生效的解析层单测（2026-11-16）。
//
//  为什么需要它：`Localized` 从 static let 改成 static var 后，语言不再在首次
//  求值时冻结；但「改了 property 却不查 lproj Bundle」这类回归，单测看不见 UI，
//  只能把解析路径钉死：
//  - 选了具体语言 → 文案来自该语言 lproj 的 Bundle（不重启即切换）
//  - 跟随系统 / 该语言缺 key → 回退 `NSLocalizedString`
//  - `Localized` 条目必须保持计算属性（static let 会冻结首次解析的语言）
//
//  测试纪律：**不写 `UserDefaults.standard`**（测试宿主 = App 域，其它套件并行跑，
//  改全局语言会让别处断言忽然变成日语）。语言选择 → Bundle 的映射用
//  `AppLanguageResources.localizedString(forKey:languageCode:)` 直接覆盖；
//  「当前选择」到 UserDefaults 的读写由端到端 harness 验证（见任务报告）。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("语言热切换（按 App 内选择的 lproj Bundle 解析）")
struct AppLanguageHotSwitchTests {
    @Test("同一 key 在不同语言 Bundle 下解析出对应文案（不重启即切换）")
    func resolvesPerLanguageBundle() {
        #expect(AppLanguageResources.localizedString(forKey: "playlists", languageCode: "ja") == "プレイリスト")
        #expect(AppLanguageResources.localizedString(forKey: "playlists", languageCode: "en") == "Playlists")
        #expect(AppLanguageResources.localizedString(forKey: "playlists", languageCode: "zh-Hans") == "播放列表")
        #expect(AppLanguageResources.localizedString(forKey: "language", languageCode: "ja") == "言語")
        #expect(AppLanguageResources.localizedString(forKey: "language", languageCode: "en") == "Language")
        #expect(AppLanguageResources.localizedString(forKey: "language_follow_system", languageCode: "ko") == "시스템 설정")
    }

    @Test("跟随系统 / 缺 key 都回退 nil（调用方走 NSLocalizedString）")
    func fallbackPaths() {
        #expect(AppLanguageResources.localizedString(forKey: "playlists", languageCode: nil) == nil)
        #expect(AppLanguageResources.localizedString(forKey: "definitely_missing_key_xyz", languageCode: "ja") == nil)
    }

    @Test("8 个 lproj 都有新增的 language / language_follow_system 文案，且互不相同")
    func newKeysExistInAllLocales() {
        let codes = ["en", "zh-Hans", "zh-Hant", "fr", "ru", "ja", "ko", "es"]
        let languageTitles = codes.compactMap {
            AppLanguageResources.localizedString(forKey: "language", languageCode: $0)
        }
        let followTitles = codes.compactMap {
            AppLanguageResources.localizedString(forKey: "language_follow_system", languageCode: $0)
        }
        #expect(languageTitles.count == codes.count, "有 lproj 缺 language 这条文案")
        #expect(followTitles.count == codes.count, "有 lproj 缺 language_follow_system 这条文案")
        #expect(Set(languageTitles).count == codes.count, "各语 language 文案不该相同：\(languageTitles)")
        #expect(Set(followTitles).count == codes.count, "各语 language_follow_system 文案不该相同：\(followTitles)")
    }

    @Test("语言目录：跟随系统存空字符串，具体语言存语言码")
    func storageMapping() {
        #expect(AppLanguage.allCases.count == 9)
        #expect(AppLanguage.system.storageValue.isEmpty)
        #expect(AppLanguage.zhHans.storageValue == "zh-Hans")
        #expect(AppLanguage.zhHant.storageValue == "zh-Hant")
        #expect(AppLanguage(rawValue: "") == nil)
        #expect(AppLanguage(rawValue: "zh-Hans") == .zhHans)
        #expect(AppLanguage.allCases.contains(AppLanguage.current))
    }

    @Test("`Localized` 条目必须是计算属性，且 `String.localized` 必须走 App 语言 Bundle")
    func localizationHelperKeepsHotSwitchShape() throws {
        let source = try helperSource()
        let frozen = source
            .split(separator: "\n")
            .filter { $0.contains("static let ") && $0.contains(".localized") }
        #expect(frozen.isEmpty, "Localized 里出现 static let ... .localized（语言会冻结）：\(frozen)")

        // 桥接层：String.localized 必须查 App 语言 Bundle，否则「选了语言也不生效」
        #expect(source.contains("AppLanguageResources.localizedString("), "String.localized 不再走 App 语言 Bundle")
        #expect(source.contains("AppLanguage.resolvedCode"), "String.localized 不再读当前语言选择")
    }

    private func helperSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("QQPlayer/Helpers/LocalizationHelper.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
