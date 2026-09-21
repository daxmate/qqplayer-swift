//
//  PlaylistDetailScreen+PlaybackActions.swift
//  QQPlayer
//
//  歌单详情页的**播放/行操作**分区：播放引擎门面 + 行操作反馈：
//  playerEngine（AppCoordinator 门面） · markAsActed（1 秒内抑制重复滑动操作）。
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
    var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    /// 分片：跨文件可见（原 private）
    func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        // Remove after 1 second so user can swipe again if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }
}
