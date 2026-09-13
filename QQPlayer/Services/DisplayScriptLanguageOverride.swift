//
//  DisplayScriptLanguageOverride.swift
//  QQPlayer
//
//  「App 已解析的 UI 语言」跨进程共享（App → Siri 扩展）。
//
//  背景：显示层简繁归一的方向由 `Bundle.main.preferredLocalizations` 决定
//  （唯一入口 DisplayScriptNormalizer）。Siri 扩展进程里 `Bundle.main` 是扩展包，
//  没有任何本地化资源 → preferredLocalizations 恒为 ["en"]，读不到用户在 iOS
//  设置里单独给 QQPlayer 指定的语言（如繁体中文）。扩展改用
//  Locale.preferredLanguages（系统语言）只是退而求其次，per-app 语言与系统语言
//  不同时 Siri 卡片会和 App 显示不一致。
//
//  方案（2026-09-13 用户拍板）：App 启动时把自己解析出的 UI 语言写进 App Group，
//  扩展优先读它，读不到（App 从未启动过 / 值非法）再回退系统语言列表。
//
//  职责边界：本类型只负责「跨进程传递语言 + 校验 + 回退选择」，
//  **不定义任何字形转换规则**（转换规则只在 DisplayScriptNormalizer /
//  ArtistNameNormalizer 里）。纯 Foundation，无 GRDB/SwiftUI 依赖，
//  故可同时编进 App 与 SiriIntentsExtension 两个 target。
//

import Foundation

enum DisplayScriptLanguageOverride {
    // MARK: - 共享位置

    /// App Group 标识（与 entitlements 及其它使用点一致）。
    /// 仓库里现存多处字面量副本（DatabaseManager 等），本类型是**新代码的唯一入口**，
    /// 不再新增裸字面量；把既有副本收敛到一处不在本包改动面内。
    static let appGroupIdentifier = "group.com.daxmate.qqplayer.ios"

    /// App 写入「已解析 UI 语言」用的键。
    static let defaultsKey = "displayScript.resolvedLanguage"

    /// App Group 共享的 UserDefaults（拿不到容器时为 nil，调用方按「读不到」处理）。
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    // MARK: - 读写

    /// App 侧写点：把当前解析出的 UI 语言写进 App Group。
    /// **每次启动覆盖写**——per-app 语言变化会重启 App，启动时读到的即最新值。
    static func write(resolvedLanguage: String, to defaults: UserDefaults) {
        defaults.set(resolvedLanguage, forKey: defaultsKey)
        // 跨进程（App 写 / 扩展读），显式落盘，不等进程内延迟写。
        defaults.synchronize()
    }

    /// 读取原始值（**未校验**；校验与回退在 validatedLanguage / effectiveLanguages 里做）。
    static func storedLanguage(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey)
    }

    /// 读取 App Group 里的原始值（App 从未启动过 / 无容器 → nil）。
    static func storedLanguageFromAppGroup() -> String? {
        guard let defaults = sharedDefaults else { return nil }
        return storedLanguage(from: defaults)
    }

    // MARK: - 校验与回退

    /// App 支持的 UI 语言（= 仓库内已本地化的语言，小写规范化形式）。
    /// 扩展包没有本地化资源，不能用 `Bundle.main.localizations` 判定，故显式列出；
    /// 表外语言（含垃圾值，如 "xx"）一律视为无效 → 回退系统语言。
    static let supportedLanguages: Set<String> = ["en", "fr", "ru", "zh-hans", "zh-hant"]

    /// 校验 stored 语言：空 / 空白 / 不支持（如 "xx"）→ nil。
    /// 带地区后缀的合法语言（zh-Hans-CN / fr-CA 等）按前缀落到支持的语言上，
    /// 返回小写规范化形式；方向判定仍交给 DisplayScriptNormalizer（不在此处判繁简）。
    static func validatedLanguage(_ stored: String?) -> String? {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if supportedLanguages.contains(lowered) { return lowered }
        for language in supportedLanguages where lowered.hasPrefix("\(language)-") {
            return language
        }
        return nil
    }

    /// 方向判定的有效语言列表：stored 有效 → [stored]；否则 systemLanguages。
    /// **唯一决策点**——App 侧与扩展侧共用（扩展据此喂 DisplayScriptNormalizer /
    /// ArtistNameNormalizer，保证两者方向永远一致）。
    static func effectiveLanguages(stored: String?, systemLanguages: [String]) -> [String] {
        if let language = validatedLanguage(stored) { return [language] }
        return systemLanguages
    }

    /// 显示层字形方向：stored 有效 → 按其判定；否则按系统语言列表判定。
    static func direction(
        stored: String?,
        systemLanguages: [String]
    ) -> DisplayScriptNormalizer.Direction {
        DisplayScriptNormalizer.direction(
            for: effectiveLanguages(stored: stored, systemLanguages: systemLanguages)
        )
    }
}
