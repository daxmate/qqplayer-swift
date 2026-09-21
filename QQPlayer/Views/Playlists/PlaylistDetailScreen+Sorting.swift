//
//  PlaylistDetailScreen+Sorting.swift
//  QQPlayer
//
//  歌单详情页的**排序**分区：排序求值 + 排序偏好持久化：
//  sortedTracks（按 sortOption 求值 + CarPlay 过滤） · loadSortPreference / saveSortPreference
//  （UserDefaults 读写）。
//
//  2026-09-21 从 PlaylistDetailScreen.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Playlists/PlaylistDetailScreen.swift — 主片：stored property + body
//    · Views/Playlists/PlaylistDetailScreen+DataLoading.swift — 曲目/歌手名缓存加载
//    · Views/Playlists/PlaylistDetailScreen+PlaybackActions.swift — 播放引擎门面 + 行操作反馈
//    · Views/Playlists/PlaylistDetailScreen+Sorting.swift — 排序求值 + 排序偏好持久化
//    · Views/Playlists/PlaylistDetailScreen+CustomCover.swift — 封面小图 + 自定义封面读写
//
// target: ios-only（PlaylistDetailScreen 分片：与原文件归属一致）
//

import SwiftUI

extension PlaylistDetailScreen {
    /// 分片：跨文件可见（原 private）
    var sortedTracks: [Track] {
        // CarPlay 连接时剔除不兼容格式（名单与判据的唯一入口 = CarPlayTrackFilter）
        let filteredTracks = CarPlayTrackFilter.filtered(tracks)

        switch sortOption {
        case .playlistOrder:
            // Respect the playlist position order (tracks are already loaded in position order)
            return filteredTracks
        case .dateNewest:
            return filteredTracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest:
            return filteredTracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ:
            return filteredTracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA:
            return filteredTracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
        case .artistAZ:
            // Pre-fetch all artist names for performance
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistSortCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistSortCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() < artist2.lowercased()
            }
        case .artistZA:
            // Pre-fetch all artist names for performance
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistSortCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistSortCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() > artist2.lowercased()
            }
        case .sizeLargest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    /// 分片：跨文件可见（原 private）
    func loadSortPreference() {
        guard let playlistId = playlist.id else { return }
        let key = "sortPreference_playlist_\(playlistId)"
        if let savedRawValue = UserDefaults.standard.string(forKey: key),
           let saved = TrackSortOption(rawValue: savedRawValue) {
            sortOption = saved
        }
    }

    /// 分片：跨文件可见（原 private）
    func saveSortPreference() {
        guard let playlistId = playlist.id else { return }
        let key = "sortPreference_playlist_\(playlistId)"
        UserDefaults.standard.set(sortOption.rawValue, forKey: key)
    }
}
