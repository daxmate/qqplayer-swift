import Foundation
import SwiftUI
#if os(iOS)
    import UIKit
#endif

extension Notification.Name {
    /// Posted only when QQPlayer UI settings change. Playback persistence also
    /// writes to UserDefaults, so views must not observe the broad
    /// UserDefaults.didChangeNotification or every state save rebuilds the
    /// library hierarchy while audio is playing.
    static let qqplayerSettingsDidChange = Notification.Name("QQPlayerSettingsDidChange")

    /// 曲库扫描条件变化（文件类型设置改动等）→ 需重扫曲库。与
    /// LibraryFoldersChanged 分开：语义不同（文件夹增删 vs 收录条件变化），
    /// 但消费方动作相同（reload + start，扫描中则排队）。
    static let libraryScanCriteriaChanged = Notification.Name("LibraryScanCriteriaChanged")
}

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

enum BackgroundColor: String, CaseIterable, Codable {
    case violet = "b11491"
    case red = "e74c3c"
    case blue = "3498db"
    case green = "27ae60"
    case orange = "f39c12"
    case pink = "e91e63"
    case teal = "1abc9c"
    case purple = "9b59b6"

    var name: String {
        switch self {
        case .violet: return "Violet (Default)"
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .purple: return "Purple"
        }
    }

    var color: Color {
        #if os(iOS)
            return Color(hex: self.rawValue)
        #else
            // Color(hex:) lives in an iOS Views file; macOS UI batch will bring
            // its own hex color helper. Fall back to a plain SwiftUI Color.
            return Color(red: 0.5, green: 0.5, blue: 0.5)
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

struct DeleteSettings: Codable {
    var hasShownDeletePopup: Bool = false
    var minimalistIcons: Bool = false
    var backgroundColorChoice: BackgroundColor = .violet
    var forceDarkMode: Bool = false
    /// 外观三态主题（system/dark/light，对齐 web 版 theme 语义）。macOS 设置页写入；
    /// 旧数据（无此 key）用 forceDarkMode 推导，见 init(from:) 与 AppearanceTheme.resolved。
    var appearanceTheme: String = "system"
    /// 强调色预设 key（orange/blue/green/purple/pink/teal，对齐 web 版 ACCENT_OPTIONS）
    var accentColorName: String = "orange"
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

    // Home screen section visibility & order
    var homeSections: [HomeSectionItem] = HomeSectionItem.defaultSections

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasShownDeletePopup = try container.decodeIfPresent(Bool.self, forKey: .hasShownDeletePopup) ?? false
        minimalistIcons = try container.decodeIfPresent(Bool.self, forKey: .minimalistIcons) ?? false
        backgroundColorChoice = try container.decodeIfPresent(BackgroundColor.self, forKey: .backgroundColorChoice) ?? .violet
        forceDarkMode = try container.decodeIfPresent(Bool.self, forKey: .forceDarkMode) ?? false
        appearanceTheme = try container.decodeIfPresent(String.self, forKey: .appearanceTheme)
            ?? (forceDarkMode ? "dark" : "system")
        accentColorName = try container.decodeIfPresent(String.self, forKey: .accentColorName) ?? "orange"
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
