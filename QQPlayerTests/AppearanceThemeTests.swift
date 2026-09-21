//  AppearanceThemeTests.swift
//  QQPlayerTests
//
//  外观三态主题解析与旧数据迁移推导防回归测试。
//  背景：macOS 设置从「强制深色 Bool」升级为「跟随系统/深色/浅色三态」，
//  老用户 forceDarkMode=true 的配置必须在无 appearanceTheme 时推导为深色。
//

import Testing

@testable import QQPlayer

struct AppearanceThemeTests {
    // MARK: - resolved(raw:forceDarkMode:)

    @Test("无 appearanceTheme + 旧 forceDarkMode=false：跟随系统")
    func nilRawNoForceDarkIsSystem() {
        #expect(AppearanceTheme.resolved(raw: nil, forceDarkMode: false) == .system)
    }

    @Test("无 appearanceTheme + 旧 forceDarkMode=true：推导为深色（迁移）")
    func nilRawForceDarkMigratesToDark() {
        #expect(AppearanceTheme.resolved(raw: nil, forceDarkMode: true) == .dark)
    }

    @Test("有 appearanceTheme：以三态值为准")
    func rawValueWins() {
        #expect(AppearanceTheme.resolved(raw: "dark", forceDarkMode: false) == .dark)
        #expect(AppearanceTheme.resolved(raw: "light", forceDarkMode: true) == .light)
        #expect(AppearanceTheme.resolved(raw: "system", forceDarkMode: true) == .system)
    }

    @Test("非法 appearanceTheme：回退 forceDarkMode 推导")
    func invalidRawFallsBack() {
        #expect(AppearanceTheme.resolved(raw: "sepia", forceDarkMode: true) == .dark)
        #expect(AppearanceTheme.resolved(raw: "", forceDarkMode: false) == .system)
    }

    // MARK: - DeleteSettings 解码兼容

    @Test("DeleteSettings 解码：无新字段时默认值正确")
    func decodeLegacyDefaults() throws {
        // 旧格式 JSON（无 appearanceTheme/accentColorName/backgroundColorChoice）
        let json = Data("""
        {"hasShownDeletePopup": true, "forceDarkMode": true}
        """.utf8)
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.appearanceTheme == "dark")
        // 配色默认值按端不同（各端色表首项，见 `AppAccentDefault`）：测试跑在 iOS target 上 = violet
        #expect(settings.accentColorName == AppAccentDefault.key)
    }

    @Test("DeleteSettings 解码：新字段完整读写")
    func decodeRoundTrip() throws {
        var original = DeleteSettings()
        original.appearanceTheme = "light"
        original.accentColorName = "teal"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeleteSettings.self, from: data)
        #expect(decoded.appearanceTheme == "light")
        #expect(decoded.accentColorName == "teal")
    }

    // MARK: - 配色字段层收口（2026-09-17：iOS backgroundColorChoice → 共享 accentColorName）

    @Test("老 iOS 数据迁移：backgroundColorChoice(hex) → accentColorName(token)，8 色逐一对应")
    func legacyColorChoiceMigratesToToken() throws {
        for (key, hex) in IOSAppearance.accentPresets {
            let json = try JSONSerialization.data(withJSONObject: ["backgroundColorChoice": hex])
            let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
            #expect(settings.accentColorName == key, "hex \(hex) 应迁移成 token \(key)，实际 \(settings.accentColorName)")
        }
    }

    @Test("老 iOS 数据迁移：旧字段优先——老 plist 里那个 iOS 从没用过的 accentColorName 占位值不作数")
    func legacyFieldWinsOverPlaceholder() throws {
        // 老 iOS 的 save() 会把整个结构编码，故旧 plist 里同时躺着 accentColorName = "orange"（默认值）。
        // 认它会静默把老用户的 violet 变成 orange ⇒ 迁移以旧字段为准。
        let json = try JSONSerialization.data(withJSONObject: [
            "backgroundColorChoice": "b11491",
            "accentColorName": "orange",
        ])
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.accentColorName == "violet")
    }

    @Test("新格式：无旧字段时以 accentColorName 为准（macOS 侧行为不变）")
    func accentNameWinsWhenNoLegacyField() throws {
        let json = try JSONSerialization.data(withJSONObject: ["accentColorName": "teal"])
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.accentColorName == "teal")
    }

    @Test("旧字段值不在名单里：回落本端默认色（不落到那个无意义的占位 orange）")
    func unknownLegacyHexFallsBackToPlatformDefault() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "backgroundColorChoice": "ffffff",
            "accentColorName": "orange",
        ])
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.accentColorName == AppAccentDefault.key)
    }

    @Test("迁移是单向的：encode 不再写回旧字段，往返后配色不变")
    func legacyFieldIsNotWrittenBack() throws {
        let legacy = try JSONSerialization.data(withJSONObject: ["backgroundColorChoice": "3498db"])
        let migrated = try JSONDecoder().decode(DeleteSettings.self, from: legacy)
        #expect(migrated.accentColorName == "blue")

        let reencoded = try JSONEncoder().encode(migrated)
        let text = String(bytes: reencoded, encoding: .utf8) ?? ""
        #expect(!text.contains("backgroundColorChoice"), "旧字段不应再被写回：\(text)")

        let roundTripped = try JSONDecoder().decode(DeleteSettings.self, from: reencoded)
        #expect(roundTripped.accentColorName == "blue", "往返后配色不能变")
    }

    @Test("iOS 名单自洽：token / hex 不重复，默认 token 可解，且共用 token 名齐全")
    func iosPaletteIsConsistent() {
        let keys = IOSAppearance.accentPresets.map(\.key)
        let hexes = IOSAppearance.accentPresets.map(\.hex)
        #expect(Set(keys).count == keys.count, "token 有重复：\(keys)")
        #expect(Set(hexes).count == hexes.count, "色值有重复：\(hexes)")
        #expect(keys.contains(IOSAppearance.defaultAccentKey), "默认 token 必须能在名单里解出颜色")

        // token 名空间与 macOS / web 共用（**色值按端独立**，见 docs/ui-design-tokens.md §0.1）：
        // 共用 token 名必须在 iOS 名单里存在，否则同一个 key 在两端指的不是同一个语义位。
        let shared = ["orange", "blue", "green", "purple", "pink", "teal"]
        let missing = Set(shared).subtracting(keys)
        #expect(missing.isEmpty, "iOS 名单缺少共用 token 名：\(missing)")
    }
}
