//
//  LibraryReads.swift
//  QQPlayer
//
//  视图层「只读查询」的唯一入口（2026-09-17 P0 收口）。
//
//  背景：审计 2026-08-29 / 2026-09-12 两轮都点名「视图直连 DatabaseManager」，
//  但两轮报告都没变成可执行机制 → 本次把它变成硬约束：
//    - `QQPlayer/Views/**` 与声明了 SwiftUI View 的 `QQPlayer/Mac/**` 文件里，
//      不得再出现 `DatabaseManager`；
//    - 查询走本文件，曲目/播放列表**变更**走 `TrackDeletionService` / `PlaylistMutations`；
//    - 由 `ViewDataAccessContractTests` 在 CI 里守（存量清单只能减不能增，见该文件）。
//
//  为什么不是「再加一层 ViewModel」：本仓库的现状是 View 直接持服务单例，
//  真正缺的不是又一层类型，而是**一个不许绕过的入口**（同 `AppNotifications` /
//  `PlaybackOrderIcon` 的收口写法）。所以这里是纯转发 enum，无生命周期、无 DI 负担。
//
//  行为：**纯转发**，不改变任何查询语义（含各 limit 默认值、cache 行为）。
//

import Foundation
import GRDB

/// 曲库只读查询唯一入口。全部 `throws` 与 `DatabaseManager` 同义，视图自己决定怎么兜错。
enum LibraryReads {
    // MARK: - 曲目

    static func track(stableId: String) throws -> Track? {
        try DatabaseManager.shared.getTrack(byStableId: stableId)
    }

    static func allTracks() throws -> [Track] {
        try DatabaseManager.shared.getAllTracks()
    }

    static func tracksMissingYearOrGenre() throws -> [Track] {
        try DatabaseManager.shared.getTracksMissingYearOrGenre()
    }

    /// 按 stableId 取曲目，**保持入参顺序**（列表顺序敏感的调用方用这个）。
    static func tracksPreservingOrder(stableIds: [String]) throws -> [Track] {
        try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(stableIds)
    }

    static func tracks(artistId: Int64) throws -> [Track] {
        try DatabaseManager.shared.getTracksByArtistId(artistId)
    }

    static func tracks(albumId: Int64) throws -> [Track] {
        try DatabaseManager.shared.getTracksByAlbumId(albumId)
    }

    static func isFavorite(trackStableId: String) throws -> Bool {
        try DatabaseManager.shared.isFavorite(trackStableId: trackStableId)
    }

    // MARK: - 艺人

    static func artist(id: Int64) throws -> Artist? {
        try DatabaseManager.shared.read { db in
            try Artist.fetchOne(db, key: id)
        }
    }

    static func artists(ids: [Int64]) throws -> [Artist] {
        guard !ids.isEmpty else { return [] }
        return try DatabaseManager.shared.read { db in
            try Artist.filter(ids.contains(Column("id"))).fetchAll(db)
        }
    }

    static func artistNamesById() throws -> [Int64: String] {
        try DatabaseManager.shared.getAllArtistNamesById()
    }

    static func artistDisplayName(forTrackStableId stableId: String, fallbackArtistId: Int64?) throws -> String? {
        try DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: stableId,
            fallbackArtistId: fallbackArtistId
        )
    }

    static func artistDisplayNames(
        forTrackStableIds stableIds: [String],
        fallbackArtistIdsByStableId: [String: Int64] = [:]
    ) throws -> [String: String] {
        try DatabaseManager.shared.getArtistDisplayNames(
            forTrackStableIds: stableIds,
            fallbackArtistIdsByStableId: fallbackArtistIdsByStableId
        )
    }

    // MARK: - 专辑

    static func album(id: Int64) throws -> Album? {
        try DatabaseManager.shared.read { db in
            try Album.fetchOne(db, key: id)
        }
    }

    static func albums(artistId: Int64) throws -> [Album] {
        try DatabaseManager.shared.getAlbumsByArtistId(artistId)
    }

    // MARK: - 播放列表

    static func playlists() throws -> [Playlist] {
        try DatabaseManager.shared.getAllPlaylists()
    }

    static func folderPlaylists() throws -> [Playlist] {
        try DatabaseManager.shared.getAllFolderPlaylists()
    }

    static func playlistItems(playlistId: Int64) throws -> [PlaylistItem] {
        try DatabaseManager.shared.getPlaylistItems(playlistId: playlistId)
    }

    /// 该曲目出现在哪些播放列表里（「加入播放列表」多选面板的勾选态）。
    static func playlistIdsContaining(trackStableId: String) throws -> [Int64] {
        try DatabaseManager.shared.read { db in
            try PlaylistItem
                .filter(Column("track_stable_id") == trackStableId)
                .fetchAll(db)
                .map(\.playlistId)
        }
    }

    // MARK: - 搜索

    static func searchTracks(query: String, limit: Int = 50) throws -> [Track] {
        try DatabaseManager.shared.searchTracks(query: query, limit: limit)
    }

    static func searchArtists(query: String, limit: Int = 20) throws -> [Artist] {
        try DatabaseManager.shared.searchArtists(query: query, limit: limit)
    }

    static func searchAlbums(query: String, limit: Int = 30) throws -> [Album] {
        try DatabaseManager.shared.searchAlbums(query: query, limit: limit)
    }

    static func searchPlaylists(query: String, limit: Int = 15) throws -> [Playlist] {
        try DatabaseManager.shared.searchPlaylists(query: query, limit: limit)
    }
}
