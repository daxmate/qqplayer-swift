//
//  MacLibrarySelection.swift
//  QQPlayer
//
//  macOS 曲库侧栏的**选择语义唯一事实源**（2026-09-27）：一级分区
//  （`MacLibrarySection`）/ 自动歌单（`SmartPlaylistKind`）/ 用户自建歌单（id）。
//
//  为什么放共享层 `QQPlayer/Services/` 而不是 `QQPlayer/Mac/`：
//  选中项回退口径是纯逻辑、必须可单测，而 iOS 单测 target 编不到 `QQPlayer/Mac/**`
//  （该目录在 iOS 例外表里）——与 MacIndexingGate / MacFolderWatchPolicy /
//  MacLibraryFactsStore 同款：纯决策上收共享层，Mac 视图只消费。
//  全仓只此一处定义该语义：视图层不得另立裸 `Int64` / `String` 选择状态。
//

import Foundation

/// macOS 曲库侧栏的一级分区（原定义在 `MacLibraryView+Sidebar.swift`，随选择语义上收）。
/// 原「播放列表」一级入口已移除（2026-09-27：改为在侧栏直接列出自动歌单与用户歌单）。
enum MacLibrarySection: String, CaseIterable, Identifiable {
    case tracks = "songs"
    case likedSongs = "liked_songs"
    case albums = "albums"
    case artists = "artists"

    var id: String { rawValue }

    /// Localized sidebar title (rawValue is a localization key).
    var title: String { rawValue.localized }

    var icon: String {
        switch self {
        case .tracks: return "music.note.list"
        case .likedSongs: return "heart.fill"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        }
    }
}

/// 侧栏选中项：一级分区 / 自动歌单 / 用户自建歌单。
enum MacLibrarySelection: Hashable {
    case section(MacLibrarySection)
    case smartPlaylist(SmartPlaylistKind)
    case userPlaylist(Int64)

    /// 选中项失效时的落点。
    static let fallback = MacLibrarySelection.section(.tracks)

    /// 纯函数：选中项仍有效则原样返回，否则回退到 `fallback`。
    /// - 一级分区与自动歌单恒有效（枚举取值，无从失效）；
    /// - 用户歌单按其 id 是否仍在当前快照里判定（被删除 / 换库后回退，不崩、不空白）。
    /// - Parameter availableUserPlaylistIds: 当前曲库快照里的用户歌单 id 集合。
    static func resolved(
        _ selection: MacLibrarySelection,
        availableUserPlaylistIds: Set<Int64>
    ) -> MacLibrarySelection {
        switch selection {
        case .section, .smartPlaylist:
            return selection
        case let .userPlaylist(id):
            return availableUserPlaylistIds.contains(id) ? selection : fallback
        }
    }
}
