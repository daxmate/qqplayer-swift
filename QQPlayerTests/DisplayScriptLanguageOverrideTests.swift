//
//  DisplayScriptLanguageOverrideTests.swift
//  QQPlayerTests
//
//  Siri 扩展的语言判定（App Group 覆盖值 → 回退系统语言）：
//  - stored 有效值优先：zh-Hant → 繁；zh-Hans/en/fr/ru → 简（系统语言相反时仍按 stored）
//  - stored 缺失 / 空 / 空白 / 垃圾值（如 "xx"）→ 回退系统语言列表
//  - effectiveLanguages 是唯一决策点：App 侧与扩展侧据此喂两个归一器，方向一致
//  - 写入 / 读取往返 + 覆盖写（独立 UserDefaults 实例，不碰真实 App Group）
//

import Foundation
import Testing

@testable import QQPlayer

struct DisplayScriptLanguageOverrideTests {
    // MARK: - 夹具

    /// 独立 suite 的 UserDefaults（用完即清，不碰真实 App Group）。
    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "qqplayer.tests.display-script-language.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    // MARK: - stored 有效值：优先于系统语言

    @Test func storedTraditionalChineseUsesTraditional() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "zh-Hant", systemLanguages: ["en"])
        #expect(direction == .toTraditional)
    }

    @Test func storedSimplifiedChineseOverridesTraditionalSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "zh-Hans", systemLanguages: ["zh-Hant"])
        #expect(direction == .toSimplified)
    }

    @Test func storedEnglishOverridesTraditionalSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "en", systemLanguages: ["zh-Hant"])
        #expect(direction == .toSimplified)
    }

    @Test func storedRussianUsesSimplified() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "ru", systemLanguages: ["zh-Hant"])
        #expect(direction == .toSimplified)
    }

    @Test func storedFrenchUsesSimplified() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "fr", systemLanguages: ["zh-Hant"])
        #expect(direction == .toSimplified)
    }

    @Test func storedLanguageWithRegionSuffixIsAccepted() {
        let traditional = DisplayScriptLanguageOverride.direction(
            stored: "zh-Hant-TW", systemLanguages: ["en"])
        #expect(traditional == .toTraditional)

        let simplified = DisplayScriptLanguageOverride.direction(
            stored: "fr-CA", systemLanguages: ["zh-Hant"])
        #expect(simplified == .toSimplified)
    }

    // MARK: - 无有效 stored 值：回退系统语言

    @Test func missingStoredValueFallsBackToTraditionalSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: nil, systemLanguages: ["zh-Hant"])
        #expect(direction == .toTraditional)
    }

    @Test func missingStoredValueFallsBackToSimplifiedSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: nil, systemLanguages: ["en"])
        #expect(direction == .toSimplified)
    }

    @Test func garbageStoredValueFallsBackToSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "xx", systemLanguages: ["zh-Hant"])
        #expect(direction == .toTraditional)

        let languages = DisplayScriptLanguageOverride.effectiveLanguages(
            stored: "xx", systemLanguages: ["zh-Hant"])
        #expect(languages == ["zh-Hant"])
    }

    @Test func emptyStoredValueFallsBackToSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "", systemLanguages: ["zh-Hant"])
        #expect(direction == .toTraditional)
    }

    @Test func blankStoredValueFallsBackToSystem() {
        let direction = DisplayScriptLanguageOverride.direction(
            stored: "   ", systemLanguages: ["zh-Hant"])
        #expect(direction == .toTraditional)
    }

    // MARK: - effectiveLanguages：唯一决策点

    @Test func effectiveLanguagesPrefersValidStoredValue() {
        let languages = DisplayScriptLanguageOverride.effectiveLanguages(
            stored: "zh-Hant", systemLanguages: ["en", "fr"])
        #expect(languages == ["zh-hant"])
    }

    @Test func effectiveLanguagesKeepsSystemListWhenStoredIsInvalid() {
        let languages = DisplayScriptLanguageOverride.effectiveLanguages(
            stored: nil, systemLanguages: ["en", "fr"])
        #expect(languages == ["en", "fr"])
    }

    /// 扩展侧两个归一器吃同一个语言列表 → 方向必然一致（曲名/歌手名不打架）。
    @Test func bothNormalizersAgreeOnEffectiveLanguages() {
        let languages = DisplayScriptLanguageOverride.effectiveLanguages(
            stored: "zh-Hant", systemLanguages: ["en"])

        let script = DisplayScriptNormalizer.direction(for: languages)
        let artist = ArtistNameNormalizer.direction(for: languages)
        #expect(script == .toTraditional)
        #expect(artist == .toTraditional)
    }

    // MARK: - 写入 / 读取往返

    @Test func writeReadRoundTripResolvesStoredLanguage() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DisplayScriptLanguageOverride.storedLanguage(from: defaults) == nil)

        DisplayScriptLanguageOverride.write(resolvedLanguage: "zh-Hant", to: defaults)

        #expect(defaults.string(forKey: DisplayScriptLanguageOverride.defaultsKey) == "zh-Hant")
        let stored = DisplayScriptLanguageOverride.storedLanguage(from: defaults)
        #expect(stored == "zh-Hant")

        let direction = DisplayScriptLanguageOverride.direction(
            stored: stored, systemLanguages: ["en"])
        #expect(direction == .toTraditional)
    }

    /// 每次启动覆盖写：后写入的值决定方向，旧值不残留。
    @Test func writeOverwritesPreviousValue() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        DisplayScriptLanguageOverride.write(resolvedLanguage: "zh-Hans", to: defaults)
        DisplayScriptLanguageOverride.write(resolvedLanguage: "zh-Hant", to: defaults)

        let stored = DisplayScriptLanguageOverride.storedLanguage(from: defaults)
        #expect(stored == "zh-Hant")

        let direction = DisplayScriptLanguageOverride.direction(
            stored: stored, systemLanguages: ["zh-Hans"])
        #expect(direction == .toTraditional)
    }

    /// 白名单必须与 App 的本地化集合同步：将来给 App 加第 6 种本地化时忘了同步
    /// `supportedLanguages`，App 写入的值会被判非法 → 扩展回退系统语言 →
    /// Siri 卡片与 App 字形再次不一致（静默退化，行为用例抓不到）。
    /// 反向也查：白名单写了 App 并未打包的语言（拼错 / 语言已删）同样是漂移。
    @Test func supportedLanguagesMatchAppLocalizations() {
        let bundled = Set(
            Bundle.main.localizations
                .map { $0.lowercased() }
                .filter { $0 != "base" }
        )
        #expect(!bundled.isEmpty, "宿主 App 里 Bundle.main.localizations 为空 → 本守护测试失效，需改用别的取法")

        let missing = bundled.subtracting(DisplayScriptLanguageOverride.supportedLanguages)
        #expect(
            missing.isEmpty,
            "App 打包了这些本地化但 supportedLanguages 未列（加语言时请同步）：\(missing.sorted())"
        )

        let extra = DisplayScriptLanguageOverride.supportedLanguages.subtracting(bundled)
        #expect(
            extra.isEmpty,
            "supportedLanguages 列了 App 未打包的语言（拼错或语言已删？）：\(extra.sorted())"
        )
    }
}
