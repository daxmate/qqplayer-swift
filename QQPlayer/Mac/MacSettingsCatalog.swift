//
//  MacSettingsCatalog.swift
//  QQPlayer
//
//  设置目录 = **唯一注册表**（2026-09-18 ⌘K 设置项搜索批次）。
//
//  为什么需要它：⌘K 浮层的「设置」分组原本是**写死的 5 个分类字符串**，设置项本身
//  不在任何数据源里——用户搜「刮削」永远搜不到「批量刮削」开关，因为整个设置项
//  目录根本不存在（AGENTS.md 2026-09-15：同一语义只能有一个入口）。本文件把
//  「分类 + 设置项 + 搜索别名 + 锚点 id」收成一份硬约束：
//
//  - 分类：`Category`（左导航顺序 = `allCases` 顺序，MacSettingsView 直接用它渲染）
//  - 条目：`Item`（`id` = 锚点常量，设置页**只能**通过 `.settingsAnchor(...)` 引用）
//  - 匹配：`matches(for:)`——分类名 + 项标题 + 别名，走 DisplayScriptNormalizer 归一
//  - 定位：`MacSettingsRouter`（通知 + pending 兜底，防「设置窗口还没建好，通知已丢」）
//
// 形状契约（QQPlayerTests/MacSettingsSearchContractTests.swift）钉死四件事：
//  ① 每条 titleKey 在全部 lproj 里真实存在；② 每条锚点在设置页源码里真实出现；
//  ③ 设置页里不得出现目录之外的裸字符串锚点 id；④ 扫描 fail-closed。
//  ——改了目录不改设置页（或反之）会直接红，不靠人记得。
//
//  文案：**一律复用设置页现有本地化 key，不新造文案**（无新 .strings 条目）。
//
//  QQPlayerMac target only。
//

import Foundation
import SwiftUI

// MARK: - 目录

enum MacSettingsCatalog {
    // MARK: 分类

    /// 设置分类（rawValue 与 `.macSettingsOpenCategory` 通知的 `category` 载荷一致）。
    /// 顺序 = 设置窗口左导航顺序（MacSettingsView 直接 `List(Category.allCases)`）。
    enum Category: String, CaseIterable, Hashable, Identifiable {
        case playback
        case lyrics
        case desktopWindows
        case library
        case download
        case scraping
        case shortcuts
        case sync
        case appearance
        case about

        var id: String { rawValue }

        /// 分类标题的本地化 key（设置页现有 key，非新造）。
        var titleKey: String {
            switch self {
            case .playback: return "settings_category_playback"
            case .lyrics: return "settings_category_lyrics"
            case .desktopWindows: return "settings_category_desktop_lyric"
            case .library: return "settings_category_library"
            case .download: return "settings_category_download"
            case .scraping: return "settings_category_scraping"
            case .shortcuts: return "settings_category_shortcuts"
            case .sync: return "settings_category_sync"
            case .appearance: return "settings_category_appearance"
            case .about: return "settings_category_about"
            }
        }

        var title: String { titleKey.localized }

        /// 左导航图标（原 MacSettingsView 内联 switch 迁到这里，一处定义）。
        var icon: String {
            switch self {
            case .playback: return "play.circle"
            case .lyrics: return "text.quote"
            case .desktopWindows: return "macwindow"
            case .library: return "music.note.list"
            case .download: return "arrow.down.circle"
            case .scraping: return "tag"
            case .shortcuts: return "keyboard"
            case .sync: return "arrow.triangle.2.circlepath"
            case .appearance: return "paintbrush"
            case .about: return "info.circle"
            }
        }

        /// 分类名搜索别名（分类标题本身也参与匹配，别名只补用户常用说法）。
        var aliases: [String] {
            switch self {
            case .playback: return ["播放", "音频", "playback", "audio"]
            case .lyrics: return ["歌词", "歌词显示", "lyrics"]
            case .desktopWindows: return ["桌面歌词", "迷你窗", "迷你模式", "浮窗", "desktop lyric", "mini"]
            case .library: return ["曲库", "音乐库", "媒体库", "library"]
            case .download: return ["下载", "下载设置", "download"]
            case .scraping: return ["刮削", "补全", "标签", "scraping", "scrape", "tag"]
            case .shortcuts: return ["快捷键", "热键", "键位", "shortcut", "hotkey"]
            case .sync: return ["同步", "局域网同步", "配对", "sync", "pair"]
            case .appearance: return ["界面", "外观", "主题", "配色", "appearance", "theme"]
            case .about: return ["关于", "版本", "about", "version"]
            }
        }
    }

    // MARK: 条目

    /// 一条设置项：`id` 是**锚点常量的唯一形式**，设置页里禁止手写等价字符串。
    struct Item: Hashable {
        /// 锚点 id（ScrollViewReader 用；全目录唯一）
        let id: String
        /// 所属分类
        let category: Category
        /// 标题本地化 key（设置页现有 key）
        let titleKey: String
        /// 搜索别名（用户可能输入的其它说法；大小写/简繁已在匹配时归一）
        let aliases: [String]

        var title: String { titleKey.localized }
    }

    // MARK: 条目常量（锚点 id 的唯一来源）

    static let playbackEqualizer = Item(
        id: "settings.playback.equalizer",
        category: .playback,
        titleKey: "graphic_equalizer",
        aliases: ["eq", "均衡器", "图示均衡器", "音效", "音频", "equalizer"]
    )

    static let playbackSleepTimerButton = Item(
        id: "settings.playback.sleepTimerButton",
        category: .playback,
        titleKey: "show_sleep_timer_button",
        aliases: ["睡眠", "睡眠定时", "定时", "定时器", "sleep", "timer"]
    )

    static let playbackVisualizer = Item(
        id: "settings.playback.visualizer",
        category: .playback,
        titleKey: "visualizer_enabled",
        aliases: ["频谱", "可视化", "播放页频谱", "spectrum", "visualizer"]
    )

    static let lyricsFontSize = Item(
        id: "settings.lyrics.fontSize",
        category: .lyrics,
        titleKey: "lyrics_font_size",
        aliases: ["歌词字号", "字号", "字体", "大小", "font", "size"]
    )

    static let lyricsShowTranslation = Item(
        id: "settings.lyrics.showTranslation",
        category: .lyrics,
        titleKey: "lyrics_show_translation",
        aliases: ["译文", "翻译", "双语", "translation", "translate"]
    )

    static let lyricsShowRoman = Item(
        id: "settings.lyrics.showRoman",
        category: .lyrics,
        titleKey: "lyrics_show_roman",
        aliases: ["罗马音", "罗马", "拼音", "roman", "romanization"]
    )

    static let lyricsOffset = Item(
        id: "settings.lyrics.offset",
        category: .lyrics,
        titleKey: "lyrics_offset",
        aliases: ["歌词延迟", "延迟", "校准", "对齐", "offset", "delay", "calibration"]
    )

    static let desktopWindowsMiniWindowButton = Item(
        id: "settings.desktopWindows.miniWindowButton",
        category: .desktopWindows,
        titleKey: "mini_window_button_enabled",
        aliases: ["迷你窗", "迷你模式", "迷你窗按钮", "mini", "mini window"]
    )

    static let desktopWindowsMiniLyrics = Item(
        id: "settings.desktopWindows.miniLyrics",
        category: .desktopWindows,
        titleKey: "mini_lyrics_enabled",
        aliases: ["桌面歌词", "迷你歌词", "歌词窗", "desktop lyric", "mini lyrics"]
    )

    static let desktopWindowsLyricFontSize = Item(
        id: "settings.desktopWindows.lyricFontSize",
        category: .desktopWindows,
        titleKey: "desktop_lyric_font_size",
        aliases: ["桌面歌词字号", "字号", "字体", "font", "size"]
    )

    static let libraryFolders = Item(
        id: "settings.library.folders",
        category: .library,
        titleKey: "library_folders",
        aliases: ["曲库文件夹", "文件夹", "目录", "扫描目录", "folder", "library folder"]
    )

    static let libraryFileTypes = Item(
        id: "settings.library.fileTypes",
        category: .library,
        titleKey: "library_file_types",
        aliases: ["文件类型", "格式", "扩展名", "format", "extension", "file type"]
    )

    static let downloadQuality = Item(
        id: "settings.download.quality",
        category: .download,
        titleKey: "settings_download_quality",
        aliases: ["下载音质", "音质", "无损", "quality", "lossless"]
    )

    static let downloadQuarkQuality = Item(
        id: "settings.download.quarkQuality",
        category: .download,
        titleKey: "settings_download_quark_quality",
        aliases: ["歌曲海音质", "歌曲海", "夸克音质", "quark", "quark quality"]
    )

    static let downloadEngine = Item(
        id: "settings.download.engine",
        category: .download,
        titleKey: "settings_download_engine",
        aliases: ["下载引擎", "引擎", "aria2", "内置下载", "engine"]
    )

    static let downloadMaxSpeed = Item(
        id: "settings.download.maxSpeed",
        category: .download,
        titleKey: "settings_download_max_speed",
        aliases: ["限速", "下载限速", "速度", "带宽", "speed", "max speed"]
    )

    static let scrapingRenameTemplate = Item(
        id: "settings.scraping.renameTemplate",
        category: .scraping,
        titleKey: "scraping_rename_template",
        aliases: ["重命名模板", "重命名", "命名规则", "模板", "rename", "template"]
    )

    static let scrapingSourceOrder = Item(
        id: "settings.scraping.sourceOrder",
        category: .scraping,
        titleKey: "scraping_source_order",
        aliases: ["源优先级", "优先级", "刮削源", "顺序", "source", "priority"]
    )

    static let scrapingBatchEnabled = Item(
        id: "settings.scraping.batchEnabled",
        category: .scraping,
        titleKey: "scraping_batch_enabled",
        aliases: ["刮削", "批量", "批量刮削", "刮", "补全", "年份", "流派", "scrape", "batch", "genre", "year"]
    )

    static let appearanceTheme = Item(
        id: "settings.appearance.theme",
        category: .appearance,
        titleKey: "appearance_theme",
        aliases: ["主题", "深色", "浅色", "跟随系统", "暗黑", "theme", "dark", "light"]
    )

    static let appearanceAccentColor = Item(
        id: "settings.appearance.accent",
        category: .appearance,
        titleKey: "accent_color",
        aliases: ["强调色", "配色", "颜色", "accent", "color"]
    )

    static let aboutVersion = Item(
        id: "settings.about.version",
        category: .about,
        titleKey: "version",
        aliases: ["版本", "版本号", "version", "build"]
    )

    static let aboutAppName = Item(
        id: "settings.about.appName",
        category: .about,
        titleKey: "app_name",
        aliases: ["应用名", "名称", "app name", "name"]
    )

    static let aboutGitHub = Item(
        id: "settings.about.github",
        category: .about,
        titleKey: "github_repository",
        aliases: ["github", "仓库", "源码", "开源", "repository", "source"]
    )

    /// 全部条目（顺序 = ⌘K 结果里同分类内的展示顺序）。
    static let items: [Item] = [
        playbackEqualizer,
        playbackSleepTimerButton,
        playbackVisualizer,
        lyricsFontSize,
        lyricsShowTranslation,
        lyricsShowRoman,
        lyricsOffset,
        desktopWindowsMiniWindowButton,
        desktopWindowsMiniLyrics,
        desktopWindowsLyricFontSize,
        libraryFolders,
        libraryFileTypes,
        downloadQuality,
        downloadQuarkQuality,
        downloadEngine,
        downloadMaxSpeed,
        scrapingRenameTemplate,
        scrapingSourceOrder,
        scrapingBatchEnabled,
        appearanceTheme,
        appearanceAccentColor,
        aboutVersion,
        aboutAppName,
        aboutGitHub,
    ]

    static func item(withID id: String) -> Item? {
        items.first { $0.id == id }
    }

    // MARK: - ⌘K 命中行

    /// ⌘K「设置」分组的一行：分类行（`itemID == nil`）或设置项行。
    struct Match: Hashable, Identifiable {
        /// 行标识（分类行 = 分类 rawValue；项行 = 锚点 id）
        let id: String
        let category: Category
        let titleKey: String
        /// 设置项锚点 id；nil = 只切分类不滚动
        let itemID: String?

        var title: String { titleKey.localized }
        var isCategory: Bool { itemID == nil }
        var icon: String { isCategory ? "folder" : "gearshape" }
    }

    // MARK: - 匹配

    /// 归一：大小写/变音符/全半角折叠 + 简繁统一到简体。
    /// 字形归一复用 `DisplayScriptNormalizer`（唯一字形入口），不另建映射。
    static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_Hans_CN")
        )
        return DisplayScriptNormalizer.toSimplified(folded)
    }

    /// 分类名 + 项标题 + 别名任一包含 query（归一后子串匹配）即命中。
    /// 空 query → 空结果（⌘K 空查询显示提示，不铺设置列表）。
    /// 顺序：按分类顺序，分类行在其条目行之前（用户输入「刮削」时分类行先出）。
    static func matches(for query: String) -> [Match] {
        let q = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        var result: [Match] = []
        for category in Category.allCases {
            let categoryHaystack = ([category.title] + category.aliases).map(normalized)
            if categoryHaystack.contains(where: { $0.contains(q) }) {
                result.append(
                    Match(id: category.rawValue, category: category, titleKey: category.titleKey, itemID: nil)
                )
            }
            for item in items where item.category == category {
                let haystack = ([item.title] + item.aliases).map(normalized)
                if haystack.contains(where: { $0.contains(q) }) {
                    result.append(
                        Match(id: item.id, category: category, titleKey: item.titleKey, itemID: item.id)
                    )
                }
            }
        }
        return result
    }
}

// MARK: - 定位请求（唯一入口）

/// 设置窗口定位请求的**唯一入口**：⌘K 浮层 → 主窗 → 设置窗口。
///
/// 两条投递路径缺一不可：
///  - 通知 `.macSettingsOpenCategory`：设置窗口**已经打开**时，设置页视图已在订阅。
///  - `pending`：设置窗口**尚未创建**时通知没有订阅者（会静默丢失，这正是原 bug 的一部分：
///    先 post 通知、再（用私有 selector）尝试开窗，而窗根本没开）。设置页 `onAppear`
///    消费一次兜底。
@MainActor
enum MacSettingsRouter {
    struct Request: Equatable {
        let category: MacSettingsCatalog.Category
        /// 需要滚动 + 高亮的设置项锚点 id
        let itemID: String?
    }

    private static var pending: Request?

    /// 发起定位：落 pending（兜底）+ 发通知（已开窗路径）。
    /// userInfo 保留 `"category"`（向后兼容），新增 `"item"`。
    static func open(_ request: Request) {
        pending = request
        var userInfo: [String: String] = ["category": request.category.rawValue]
        if let itemID = request.itemID {
            userInfo["item"] = itemID
        }
        NotificationCenter.default.post(
            name: .macSettingsOpenCategory,
            object: nil,
            userInfo: userInfo
        )
    }

    /// 通知 → 请求（订阅方收到即清 pending，避免下次 onAppear 重复定位）。
    static func request(from notification: Notification) -> Request? {
        guard let raw = notification.userInfo?["category"] as? String,
              let category = MacSettingsCatalog.Category(rawValue: raw) else { return nil }
        pending = nil
        let itemID = notification.userInfo?["item"] as? String
        return Request(category: category, itemID: itemID)
    }

    /// 设置页 onAppear 兜底：窗口后建时把最后一次请求补上（一次性）。
    static func consumePending() -> Request? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - 锚点（唯一入口）

/// 锚点高亮值的环境入口：`MacSettingsView` 注入，`.settingsAnchor` 修饰器读取。
/// 不引入第二个单例——视图层直连 `<Type>.shared` 被棘轮契约禁止
/// （QQPlayerTests/ViewSharedSingletonContractTests.swift）。
private struct MacSettingsHighlightedIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// 当前短暂高亮的设置项锚点 id（nil = 无高亮）
    var macSettingsHighlightedID: String? {
        get { self[MacSettingsHighlightedIDKey.self] }
        set { self[MacSettingsHighlightedIDKey.self] = newValue }
    }
}

/// 锚点标记（**标记式扫描的目标**：契约测试在设置页源码里找 `.settingsAnchor(MacSettingsCatalog.<常量>)`）。
private struct MacSettingsAnchorModifier: ViewModifier {
    let item: MacSettingsCatalog.Item
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.macSettingsHighlightedID) private var highlightedID

    func body(content: Content) -> some View {
        content
            .id(item.id)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.radius6)
                    .fill(appAccentColor.opacity(highlightedID == item.id ? 0.18 : 0))
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.2), value: highlightedID)
            }
    }
}

extension View {
    /// 给设置页的一行/一组标锚点。id 只能来自 `MacSettingsCatalog` 的条目常量
    /// （禁止手写等价字符串：同一语义一个入口，形状契约会红）。
    func settingsAnchor(_ item: MacSettingsCatalog.Item) -> some View {
        modifier(MacSettingsAnchorModifier(item: item))
    }
}
