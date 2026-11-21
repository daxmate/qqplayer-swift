//
//  AppLanguage.swift
//  QQPlayer
//
//  设置 → 外观 → 语言：App 内语言选择 + 切换热生效。
//
//  为什么需要它：此前 App 语言只能跟随系统（NSLocalizedString），改语言必须
//  去系统设置且重启 App。这里把「用户选择的语言」变成 App 级状态：
//  - 选择持久化在 UserDefaults[`qqplayer.appLanguage`]（跟随系统 = 空字符串）
//  - 同时写 AppleLanguages，让下次启动后的系统级文案（应用名/权限弹窗/Siri/
//    小组件/分享扩展）也跟随；当前进程热生效只依赖下面的 lproj Bundle。
//  - `String.localized` 每次按当前选择查对应 lproj 的 Bundle，所以 `Localized`
//    里的条目必须是计算属性（static var），static let 只求值一次会冻结语言。
//

import Foundation

/// App 内可选语言（顺序 = 设置里下拉列表顺序）。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case fr
    case ru
    case es

    /// 持久化 key（`UserDefaults`）
    static let storageKey = "qqplayer.appLanguage"
    /// 系统语言偏好 key（下次启动生效，不负责当前进程热切换）
    static let appleLanguagesKey = "AppleLanguages"

    var id: String { rawValue }

    /// 存进 `UserDefaults` 的值：跟随系统 = 空字符串
    var storageValue: String {
        self == .system ? "" : rawValue
    }

    /// 下拉列表选项文案：母语写法（不本地化）；「跟随系统」跟随当前语言
    var displayName: String {
        switch self {
        case .system: return Localized.languageFollowSystem
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .ru: return "Русский"
        case .es: return "Español"
        }
    }

    /// 当前持久化选择（没存过 = 跟随系统）
    static var current: AppLanguage {
        AppLanguage(rawValue: storedCode) ?? .system
    }

    /// 当前生效的具体语言码（跟随系统 → nil，走系统 `NSLocalizedString`）
    static var resolvedCode: String? {
        storedCode.isEmpty ? nil : storedCode
    }

    /// 给定持久化值 → Locale（空字符串 = 跟随系统）
    ///
    /// 视图树用 `.id(存储值.isEmpty ? "system" : 存储值)` 触发重建，
    /// 这里负责把同一存储值翻成日期/数字格式用的 Locale。
    static func locale(forStoredCode code: String) -> Locale {
        code.isEmpty ? .current : Locale(identifier: code)
    }

    /// 切换语言：写选择 + AppleLanguages，并广播热切换事件。
    /// 当前进程的界面文案由 `String.localized` 的 lproj Bundle 直接兑现；
    /// 显示层简繁方向则由 `DisplayScriptNormalizer.current` 现读存储值兑现。
    /// 通知只给「已经推出去、不会随视图重建自动更新」的消费者用（锁屏 / 控制中心文案）。
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.storageValue, forKey: storageKey)
        if language == .system {
            // 跟随系统：交给系统按设备语言解析，下次启动生效
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
        NotificationCenter.default.post(name: .qqplayerLanguageDidChange, object: nil)
    }

    private static var storedCode: String {
        UserDefaults.standard.string(forKey: storageKey) ?? ""
    }
}

/// 语言 lproj 的 `Bundle` 缓存（按语言码缓存，避免每次取文案都新建 Bundle）。
enum AppLanguageResources {
    private final class BundleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var bundles: [String: Bundle] = [:]

        func bundle(for code: String) -> Bundle? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = bundles[code] { return cached }
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return nil
            }
            bundles[code] = bundle
            return bundle
        }
    }

    private static let cache = BundleCache()

    /// 指定语言的 Bundle（跟随系统传 nil）
    static func bundle(for code: String?) -> Bundle? {
        guard let code else { return nil }
        return cache.bundle(for: code)
    }

    /// 给定 key 与语言码的解析结果（nil = 该语言没有这条文案，调用方回退系统解析）
    static func localizedString(forKey key: String, languageCode: String?) -> String? {
        guard let bundle = bundle(for: languageCode) else { return nil }
        let translated = bundle.localizedString(forKey: key, value: nil, table: nil)
        return translated == key ? nil : translated
    }
}
