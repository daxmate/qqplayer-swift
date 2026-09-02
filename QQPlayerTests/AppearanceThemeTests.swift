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
        // 旧格式 JSON（无 appearanceTheme/accentColorName）
        let json = Data("""
        {"hasShownDeletePopup": true, "forceDarkMode": true}
        """.utf8)
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.appearanceTheme == "dark")
        #expect(settings.accentColorName == "orange")
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
}
