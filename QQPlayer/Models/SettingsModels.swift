import Foundation
import SwiftUI
#if os(iOS)
    import UIKit
#endif

/// 曲库可收录的音频扩展名（单一事实源）。
///
/// web 版（对齐对象）有 7 种（.mp3/.flac/.m4a/.wav/.ogg/.aac/.opus），但
/// Swift 原生端播放引擎额外支持 Opus/OGG/DSD（SFBAudioEngine，macOS/iOS），
/// 故收录全集为 9 种 = web 7 种 + dsf/dff。默认全选 = 与历史行为一致
/// （2026-09-02 前硬编码过滤列表），用户可自行取消个别格式。
enum LibraryAudioFormats {
    /// 全部受支持扩展名（小写、不带点），顺序即设置页 chips 显示顺序
    static let allSupported: [String] = ["mp3", "flac", "m4a", "wav", "ogg", "aac", "opus", "dsf", "dff"]

    /// 设置未配置（首次启动/旧数据）时的默认启用集 = 全部
    static let defaultEnabled: [String] = allSupported

    /// 某路径是否属于当前启用收录格式（按扩展名，小写比较）。
    static func isEnabled(path: String, enabled: [String]) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return enabled.contains(ext)
    }
}

#if os(iOS)
    /// 全局外观决策（forceDarkMode → UIUserInterfaceStyle）。
    ///
    /// 不用 SwiftUI 的 `.preferredColorScheme(forceDark ? .dark : nil)`：从显式
    /// `.dark` 切回 `nil` 时系统不会重新解析，界面会卡在深色（已实测复现）。
    /// 改用 UIKit 层 `window.overrideUserInterfaceStyle`：`.unspecified` 明确
    /// 恢复跟随系统，SwiftUI 的 `@Environment(\.colorScheme)` 会自动跟随，
    /// sheet/弹窗/系统控件全部统一生效。
    enum AppearanceResolver {
        static func interfaceStyle(forceDark: Bool) -> UIUserInterfaceStyle {
            forceDark ? .dark : .unspecified
        }

        @MainActor
        static func apply(forceDark: Bool) {
            let style = interfaceStyle(forceDark: forceDark)
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
#endif

/// iOS 强调色名单（8 色）+ **唯一读取入口**（对称 macOS 的 `Mac/MacAppearance.swift`）。
///
/// 2026-09-17 「设置字段层收口」（反屎山审计复核，用户拍板走「iOS 迁到 accentColorName」）：
/// - **字段名单一**：iOS / macOS 都读写 `DeleteSettings.accentColorName`（token 名）。
///   原 iOS 字段 `backgroundColorChoice`（枚举 rawValue = hex）退役，老数据在
///   `DeleteSettings.init(from:)` 里按 hex → token 迁移 → **iOS 视觉零变化**。
/// - **色表按端独立**（用户 2026-09-15 已拍板，`docs/ui-design-tokens.md` §0.1）：iOS 8 色饱和表、
///   macOS / web 6 色 pastel 表**有意不同**，不做跨端色值对拍；每端内部唯一入口即可。
/// - hex 解析一律走全仓唯一入口 `Color(hex:)`（Models/AppearanceTheme.swift，M3）。
///
/// **不要在视图里自读 `DeleteSettings.accentColorName`**——注入点 `ContentView` 从这里取
/// （形状契约见 `QQPlayerTests/UIAccentContractTests.swift`）。
enum IOSAppearance {
    /// iOS 强调色预设（token → hex）。色值 = 历史 `BackgroundColor` 各 case 的 rawValue，逐字未改。
    static let accentPresets: [(key: String, hex: String)] = [
        ("violet", "b11491"),
        ("red", "e74c3c"),
        ("blue", "3498db"),
        ("green", "27ae60"),
        ("orange", "f39c12"),
        ("pink", "e91e63"),
        ("teal", "1abc9c"),
        ("purple", "9b59b6"),
    ]

    /// 默认 token（8 色表首项，历史默认；`AppAccentDefault.key` 在 iOS 上取它）。
    static let defaultAccentKey = accentPresets[0].key

    /// token → 色值。未知 token 回退默认色（对齐 macOS `MacAppearance.accentColor(forKey:)`
    /// 的兜底语义），调用方无需自行 find / 兜底。
    static func accentColor(forKey key: String) -> Color {
        Color(hex: accentHex(forKey: key))
    }

    /// token → hex 字符串（widget 跨进程传递用；widget 侧只有 hex，没有 token 名单）。
    static func accentHex(forKey key: String) -> String {
        accentPresets.first { $0.key == key }?.hex ?? accentPresets[0].hex
    }

    /// 旧数据迁移：历史 `backgroundColorChoice` 的 hex rawValue → token（不在名单里 → nil）。
    /// 只用于 `DeleteSettings.init(from:)` 一处。
    static func legacyKey(fromHex hex: String) -> String? {
        accentPresets.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.key
    }

    // MARK: - 当前强调色（全 App 唯一读取入口）

    /// 当前强调色 token（from `DeleteSettings.accentColorName`）。
    /// 窗口 / 视图 / 服务一律从这里取，不要各自 `DeleteSettings.load().accentColorName`。
    static var currentAccentKey: String { DeleteSettings.load().accentColorName }

    /// 当前强调色色值（= `currentAccentKey` 经 8 色名单解析）。
    static var currentAccentColor: Color { accentColor(forKey: currentAccentKey) }
}

/// 强调色字段（`DeleteSettings.accentColorName`）的默认 token。
///
/// 两端默认**有意不同**（= 各自色表首项，保持历史默认行为）：iOS = 8 色表 `violet`，
/// macOS = 6 色表 `orange`（对齐 web）。放在共享文件是因为 `DeleteSettings` 的默认值
/// 必须在两端各自编译时取对，而 macOS 名单（`MacAppearance`）不在 iOS target 内。
enum AppAccentDefault {
    static var key: String {
        #if os(iOS)
            return IOSAppearance.defaultAccentKey
        #else
            return "orange"
        #endif
    }
}

enum DSDPlaybackMode: String, CaseIterable, Codable {
    case auto
    case pcm
    case dop

    var displayName: String {
        switch self {
        case .auto: return Localized.dsdModeAuto
        case .pcm: return Localized.dsdModePCM
        case .dop: return Localized.dsdModeDoP
        }
    }

    var description: String {
        switch self {
        case .auto: return Localized.dsdModeAutoDescription
        case .pcm: return Localized.dsdModePCMDescription
        case .dop: return Localized.dsdModeDoDescription
        }
    }
}

enum HomeSectionId: String, Codable, CaseIterable {
    case allSongs
    case likedSongs
    case playlists
    case artists
    case albums
    case addSongs

    var displayName: String {
        switch self {
        case .allSongs: return Localized.allSongs
        case .likedSongs: return Localized.likedSongs
        case .playlists: return Localized.playlists
        case .artists: return Localized.artists
        case .albums: return Localized.albums
        case .addSongs: return Localized.addSongs
        }
    }

    var icon: String {
        switch self {
        case .allSongs: return "music.note"
        case .likedSongs: return "heart.fill"
        case .playlists: return "music.note.list"
        case .artists: return "person.2.fill"
        case .albums: return "opticaldisc.fill"
        case .addSongs: return "plus.circle.fill"
        }
    }
}

struct HomeSectionItem: Codable, Identifiable, Equatable {
    var id: HomeSectionId
    var isVisible: Bool

    static let defaultSections: [HomeSectionItem] = [
        HomeSectionItem(id: .allSongs, isVisible: true),
        HomeSectionItem(id: .likedSongs, isVisible: true),
        HomeSectionItem(id: .playlists, isVisible: true),
        HomeSectionItem(id: .artists, isVisible: true),
        HomeSectionItem(id: .albums, isVisible: true),
        HomeSectionItem(id: .addSongs, isVisible: true),
    ]
}

/// 已退役的旧配色字段（`DeleteSettings` 字段层收口 2026-09-17，只读一次用于老数据迁移）。
/// 字符串字面量**只允许出现在这一处**：形状契约（`UIAccentContractTests`）禁止全仓再出现
/// `backgroundColorChoice`（防字段复活 = 防第二份配色语义）。
private enum LegacyCodingKeys: String, CodingKey {
    case backgroundColorChoice
}

struct DeleteSettings: Codable {
    var hasShownDeletePopup: Bool = false
    var minimalistIcons: Bool = false
    var forceDarkMode: Bool = false
    /// 外观三态主题（system/dark/light，对齐 web 版 theme 语义）。macOS 设置页写入；
    /// 旧数据（无此 key）用 forceDarkMode 推导，见 init(from:) 与 AppearanceTheme.resolved。
    var appearanceTheme: String = "system"
    /// 强调色预设 token——**两端唯一的配色设置字段**（2026-09-17 字段层收口）。
    /// iOS 名单 8 色（`IOSAppearance`）/ macOS 名单 6 色（orange/blue/green/purple/pink/teal，
    /// 色值对齐 web `ACCENT_OPTIONS`）；色表按端独立是用户已拍板的（`docs/ui-design-tokens.md` §0.1）。
    /// 旧 iOS 字段 `backgroundColorChoice` 已退役，老数据迁移见 `init(from:)`。
    var accentColorName: String = AppAccentDefault.key
    var dsdPlaybackMode: DSDPlaybackMode = .pcm
    var deleteFromLibraryOnly: Bool = true
    var lastLibraryScanDate: Date?
    var autoCreateFolderPlaylists: Bool = true
    /// macOS 曲库文件夹列表（用户添加的外部歌曲文件夹；空 = 默认 ~/Music/QQPlayer）
    var libraryFolders: [String] = []
    /// 曲库收录的音频扩展名（小写不带点，web 版「文件类型」chips 对齐）。
    /// 默认全部支持格式；取消某格式后重扫会从曲库移除该格式曲目
    /// （文件保留在磁盘，勾回重扫即恢复——web 版扫描缓存语义对齐）。
    var audioExtensions: [String] = LibraryAudioFormats.defaultEnabled
    var showSleepTimerButton: Bool = false
    /// 在线下载音质等级（standard/exhigh/lossless/hires，web download.defaultQuality 对齐；
    /// 默认 exhigh=320k）。在线搜索下载用，见 NeteaseOnlineLogic。
    var onlineDownloadQuality: String = NeteaseOnlineLogic.defaultLevel
    /// 在线下载目标目录（空 = 默认曲库首目录，web download.downloadDir 语义）
    var onlineDownloadDirectory: String = ""

    // MARK: - 下载引擎（web download.* 对齐，2026-09 B1 下载引擎批）

    /// 下载引擎（httpx=内置 HTTP | aria2，web download.engine 对齐；默认内置）
    var downloadEngine: String = "httpx"
    /// aria2 RPC 地址（web download.aria2Rpc 对齐；默认本机 daemon）
    var aria2Rpc: String = "http://localhost:6800/jsonrpc"
    /// aria2 RPC secret（web download.aria2Secret 对齐）
    var aria2Secret: String = ""
    /// 下载限速 MB/s（0=不限速；web download.maxSpeed 对齐——注意 web 单位是 MB/s）
    var downloadMaxSpeed: Double = 0
    /// 歌曲海（夸克）下载音质（mp3|flac，web download.quarkQuality 对齐；macOS 现在写死 mp3）
    var quarkQuality: String = "mp3"
    /// 歌词字号（Mac 歌词面板正文；web 版 lyric fontSize 对齐，默认 15）
    var lyricFontSize: Double = 15
    /// 歌词译文行显示（web 版 lyric showZh 对齐，默认显示）
    var lyricShowTranslation: Bool = true
    /// 歌词罗马音行显示（web 版 lyric showRoma 对齐，默认显示；只有带罗马音的曲目会出现该行）
    var lyricShowRoman: Bool = true
    /// 歌词整体延迟校准秒（>0 = 歌词比声音延后；web 版 lyric offset 对齐，默认 0）
    var lyricOffset: Double = 0
    /// 歌词延迟校准（按输出路由分开存，key = LyricOffsetRoute.rawValue；缺省 = 未校准 → 用系统初值）。
    /// iOS / CarPlay 用（无线车机与蓝牙量级差很多）；全局 lyricOffset 仍作 Mac/web 的总校准。
    var lyricOffsetsByRoute: [String: Double] = [:]
    /// 播放页频谱（web 版 visualizerEnabled 对齐，默认开；仅 native 引擎曲目有数据）
    var visualizerEnabled: Bool = true

    // MARK: - E3 桌面浮窗 v2（迷你模式：主窗 ⇄ 迷你窗+桌面歌词，用户 2026-09-06 拍板）

    /// 主界面显示「进入迷你模式」按钮（v2；默认开。仅控制主窗工具栏入口可见性，
    /// 不直接开关窗口——窗口显隐是瞬态，启动恒回主窗态）
    var showMiniWindowButton: Bool = true
    /// 迷你模式中显示桌面歌词窗（v2；默认开。mini 窗内歌词按钮与设置页开关同源，
    /// 进入迷你模式时按此值决定是否带出歌词窗；退出记忆，下次进入保持）
    var miniLyricsEnabled: Bool = true
    /// 桌面歌词主行字号（E3，web desktopLyric.fontSize 对齐，默认 26；译文行按比例派生）
    var desktopLyricFontSize: Double = 26

    // MARK: - 快捷键重绑（E4，web shortcuts.ts settingKey 语义；key = shortcut id，
    // 缺省 = 用出厂默认组合；与默认一致的绑定不存储）

    /// 快捷键自定义绑定（keyCode/flags 存 Int——UInt16 不 Codable）
    var shortcutBindings: [String: ShortcutCombo] = [:]

    // MARK: - E1 标签刮削（scraping namespace，web 版 scraping.* 对齐）

    /// 重命名模板（web scraping.rename_template；默认 "{artist} - {title}"）
    var scrapingRenameTemplate: String = TagWriterService.defaultRenameTemplate
    /// 刮削源优先级（web scraping.source_order；默认 netease 优先）
    var scrapingSourceOrder: [String] = ["netease", "musicbrainz"]
    /// 批量刮削开关（web scraping.batch_enabled；默认关，关时批量入口隐藏+服务拒接）
    var scrapingBatchEnabled: Bool = false

    // MARK: - 跨端续播（播放位置）

    /// 跨端续播（播放位置）开关；默认关（2026-09-14 用户拍板）。关 = 本端既不上报也不接受 playback_position
    var syncPlaybackPositionEnabled: Bool = false

    // MARK: - 同步目标设备（批 B2，2026-09-26）

    /// macOS「同步」页选中的设备 Device ID（= 本次同步的**唯一合法目标**；重启后仍记得）。
    /// 空串 = 未选。**复用既有偏好入口**（`DeleteSettings` 的 UserDefaults 存）：
    /// 不新造第二套存储，与 `syncPlaybackPositionEnabled` 同住一个设置 namespace。
    var syncTargetDeviceID: String = ""

    // Home screen section visibility & order
    var homeSections: [HomeSectionItem] = HomeSectionItem.defaultSections

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        hasShownDeletePopup = try container.decodeIfPresent(Bool.self, forKey: .hasShownDeletePopup) ?? false
        minimalistIcons = try container.decodeIfPresent(Bool.self, forKey: .minimalistIcons) ?? false
        forceDarkMode = try container.decodeIfPresent(Bool.self, forKey: .forceDarkMode) ?? false
        appearanceTheme = try container.decodeIfPresent(String.self, forKey: .appearanceTheme)
            ?? (forceDarkMode ? "dark" : "system")
        // 强调色：老 iOS 数据只有 `backgroundColorChoice`（hex rawValue，如 "b11491"）→ 迁移成 token。
        // **旧字段优先**：老 iOS plist 里同时躺着一个从未被 iOS 用过的 `accentColorName`
        // 默认值 "orange"（save() 整体编码），认它会把老用户的 violet 变成 orange。
        // 迁移期只读这两个 key，不再写回旧 key（旧 key 在下一次 save() 时自然消失）。
        if let legacyHex = try legacyContainer.decodeIfPresent(String.self, forKey: .backgroundColorChoice) {
            accentColorName = IOSAppearance.legacyKey(fromHex: legacyHex) ?? AppAccentDefault.key
        } else {
            accentColorName = try container.decodeIfPresent(String.self, forKey: .accentColorName)
                ?? AppAccentDefault.key
        }
        dsdPlaybackMode = try container.decodeIfPresent(DSDPlaybackMode.self, forKey: .dsdPlaybackMode) ?? .pcm
        // Default to app-only deletion - deleting the user's actual files
        // should always be an explicit opt-in
        deleteFromLibraryOnly = try container.decodeIfPresent(Bool.self, forKey: .deleteFromLibraryOnly) ?? true
        lastLibraryScanDate = try container.decodeIfPresent(Date.self, forKey: .lastLibraryScanDate)
        autoCreateFolderPlaylists = try container.decodeIfPresent(Bool.self, forKey: .autoCreateFolderPlaylists) ?? true
        libraryFolders = try container.decodeIfPresent([String].self, forKey: .libraryFolders) ?? []
        // 兼容旧数据/未配置：decode 失败或为空列表时回落默认全集
        // （空列表在旧格式里可能表示「未设置」，与「用户显式清空」区分——
        // 保存路径保证至少保留一种，见 MacSettingsView 文件类型 chips）
        let storedExts = try container.decodeIfPresent([String].self, forKey: .audioExtensions) ?? []
        audioExtensions = storedExts.isEmpty ? LibraryAudioFormats.defaultEnabled : storedExts
        showSleepTimerButton = try container.decodeIfPresent(Bool.self, forKey: .showSleepTimerButton) ?? false
        onlineDownloadQuality = try container.decodeIfPresent(String.self, forKey: .onlineDownloadQuality)
            ?? NeteaseOnlineLogic.defaultLevel
        onlineDownloadDirectory = try container.decodeIfPresent(String.self, forKey: .onlineDownloadDirectory) ?? ""
        downloadEngine = try container.decodeIfPresent(String.self, forKey: .downloadEngine) ?? "httpx"
        aria2Rpc = try container.decodeIfPresent(String.self, forKey: .aria2Rpc)
            ?? "http://localhost:6800/jsonrpc"
        aria2Secret = try container.decodeIfPresent(String.self, forKey: .aria2Secret) ?? ""
        downloadMaxSpeed = try container.decodeIfPresent(Double.self, forKey: .downloadMaxSpeed) ?? 0
        quarkQuality = try container.decodeIfPresent(String.self, forKey: .quarkQuality) ?? "mp3"
        lyricFontSize = try container.decodeIfPresent(Double.self, forKey: .lyricFontSize) ?? 15
        lyricShowTranslation = try container.decodeIfPresent(Bool.self, forKey: .lyricShowTranslation) ?? true
        lyricShowRoman = try container.decodeIfPresent(Bool.self, forKey: .lyricShowRoman) ?? true
        lyricOffset = try container.decodeIfPresent(Double.self, forKey: .lyricOffset) ?? 0
        // 旧设置文件没有按路由的偏移表 → 空表（解码绝不解码失败）
        lyricOffsetsByRoute = try container.decodeIfPresent([String: Double].self, forKey: .lyricOffsetsByRoute) ?? [:]
        visualizerEnabled = try container.decodeIfPresent(Bool.self, forKey: .visualizerEnabled) ?? true
        showMiniWindowButton = try container.decodeIfPresent(Bool.self, forKey: .showMiniWindowButton) ?? true
        miniLyricsEnabled = try container.decodeIfPresent(Bool.self, forKey: .miniLyricsEnabled) ?? true
        desktopLyricFontSize = try container.decodeIfPresent(Double.self, forKey: .desktopLyricFontSize) ?? 26
        shortcutBindings = try container.decodeIfPresent([String: ShortcutCombo].self, forKey: .shortcutBindings) ?? [:]
        scrapingRenameTemplate = try container.decodeIfPresent(String.self, forKey: .scrapingRenameTemplate)
            ?? TagWriterService.defaultRenameTemplate
        scrapingSourceOrder = try container.decodeIfPresent([String].self, forKey: .scrapingSourceOrder)
            ?? ["netease", "musicbrainz"]
        scrapingBatchEnabled = try container.decodeIfPresent(Bool.self, forKey: .scrapingBatchEnabled) ?? false
        // 跨端续播开关：旧设置文件（无此 key）必须是「关」——decodeIfPresent 兜底，绝不解码失败。
        syncPlaybackPositionEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .syncPlaybackPositionEnabled
        ) ?? false
        // 同步目标设备（批 B2）：旧设置文件（无此 key）必须是「未选」——同上兜底。
        syncTargetDeviceID = try container.decodeIfPresent(String.self, forKey: .syncTargetDeviceID) ?? ""

        var decoded = try container.decodeIfPresent([HomeSectionItem].self, forKey: .homeSections) ?? HomeSectionItem.defaultSections
        // Ensure any new sections added in future updates are included
        let existingIds = Set(decoded.map(\.id))
        for defaultSection in HomeSectionItem.defaultSections where !existingIds.contains(defaultSection.id) {
            decoded.append(defaultSection)
        }
        homeSections = decoded
    }

    static func load() -> DeleteSettings {
        guard let data = UserDefaults.standard.data(forKey: "DeleteSettings"),
              let settings = try? JSONDecoder().decode(DeleteSettings.self, from: data) else {
            return DeleteSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "DeleteSettings")
            // 内联通知，避免 non-Sendable 闭包跨线程转换警告（2026-08-30 警告清理）
            if Thread.isMainThread {
                NotificationCenter.default.post(name: .qqplayerSettingsDidChange, object: nil)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .qqplayerSettingsDidChange, object: nil)
                }
            }
        }
    }

    // MARK: - Excluded Tracks (library-only deletions)

    private static let excludedTracksKey = "ExcludedTrackStableIds"

    static func addExcludedTrack(_ stableId: String) {
        var excluded = excludedTrackIds()
        excluded.insert(stableId)
        UserDefaults.standard.set(Array(excluded), forKey: excludedTracksKey)
    }

    static func isTrackExcluded(_ stableId: String) -> Bool {
        return excludedTrackIds().contains(stableId)
    }

    static func removeExcludedTrack(_ stableId: String) {
        var excluded = excludedTrackIds()
        excluded.remove(stableId)
        UserDefaults.standard.set(Array(excluded), forKey: excludedTracksKey)
    }

    private static func excludedTrackIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: excludedTracksKey) ?? []
        return Set(array)
    }
}

// MARK: - Color Extension for Widget
extension Color {
    func toHex() -> String {
        #if canImport(UIKit)
            let components = UIColor(self).cgColor.components
            let r = Float(components?[0] ?? 0)
            let g = Float(components?[1] ?? 0)
            let b = Float(components?[2] ?? 0)

            return String(format: "%02lX%02lX%02lX",
                          lroundf(r * 255),
                          lroundf(g * 255),
                          lroundf(b * 255))
        #else
            return "b11491" // Default violet
        #endif
    }
}

// MARK: - 快捷键组合（E4；Mac-only 使用但定义在共享文件——纯值类型无 AppKit 依赖）

/// 一个快捷键组合（keyCode + 修饰键 + 展示串）。
/// 持久化字段：keyCode/flags 用于匹配（flags 只含 cmd/opt/ctrl/shift 位，
/// capsLock/numericPad/function 等不计入）；display 供设置面板展示。
struct ShortcutCombo: Codable, Equatable, Sendable {
    /// NSEvent keyCode（UInt16 → Int 存储）
    var keyCode: Int
    /// 修饰键 rawValue 交集（只保留 cmd/option/control/shift）
    var flags: Int
    /// 展示文本（如 "⌘G" / "Space" / "←"）
    var display: String

    /// 修饰键是否为空（纯键）
    var isPlain: Bool { flags == 0 }

    /// 展示串与持久化共用；修改绑定后再读此字段渲染
    static func == (lhs: ShortcutCombo, rhs: ShortcutCombo) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.flags == rhs.flags
    }
}
