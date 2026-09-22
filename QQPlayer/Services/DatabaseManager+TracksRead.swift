//
//  DatabaseManager+TracksRead.swift
//  QQPlayer
//
//  Track read queries (by id / stableId / album / artist / pagination / counts / favorite
//  list) for DatabaseManager.
//
//  2026-09-21 从 DatabaseManager+Tracks.swift 原样搬出（纯搬家，无逻辑变更）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    func getAllTracks() throws -> [Track] {
        return try read { db in
            return try Track.order(Column("id").desc).fetchAll(db)
        }
    }

    func getTrack(byStableId stableId: String) throws -> Track? {
        return try read { db in
            return try Track.filter(Column("stable_id") == stableId).fetchOne(db)
        }
    }

    func getTracksByStableIds(_ stableIds: [String]) throws -> [Track] {
        return try read { db in
            return try Track.filter(stableIds.contains(Column("stable_id"))).order(Column("id").desc).fetchAll(db)
        }
    }

    func getTracksByStableIdsPreservingOrder(_ stableIds: [String]) throws -> [Track] {
        guard !stableIds.isEmpty else { return [] }

        let tracks = try getTracksByStableIds(stableIds)
        let tracksByStableId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.stableId, $0) })
        return stableIds.compactMap { tracksByStableId[$0] }
    }

    func getFavoriteTracks(excludingFormats: [String] = []) throws -> [Track] {
        let favoriteIds = try getFavorites()
        let orderedTracks = try getTracksByStableIdsPreservingOrder(favoriteIds)
        guard !excludingFormats.isEmpty else { return orderedTracks }

        let excludedFormats = Set(excludingFormats.map { $0.lowercased() })
        return orderedTracks.filter { track in
            let ext = LibraryRoot.absoluteURL(forStoredPath: track.path).pathExtension.lowercased()
            return !excludedFormats.contains(ext)
        }
    }

    func getTracksPaginated(limit: Int, offset: Int, excludingFormats: [String] = []) throws -> [Track] {
        return try read { db in
            let sanitizedFormats = excludingFormats
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }

            var sql = "SELECT * FROM track"
            if !sanitizedFormats.isEmpty {
                let formatClauses = sanitizedFormats.map { "LOWER(path) NOT LIKE '%.\($0)'" }
                sql += " WHERE " + formatClauses.joined(separator: " AND ")
            }

            sql += " ORDER BY title LIMIT \(max(limit, 0)) OFFSET \(max(offset, 0))"
            return try Track.fetchAll(db, sql: sql)
        }
    }

    func getTrackCount(excludingFormats: [String] = []) throws -> Int {
        return try read { db in
            let sanitizedFormats = excludingFormats
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }

            var sql = "SELECT COUNT(*) FROM track"
            if !sanitizedFormats.isEmpty {
                let formatClauses = sanitizedFormats.map { "LOWER(path) NOT LIKE '%.\($0)'" }
                sql += " WHERE " + formatClauses.joined(separator: " AND ")
            }

            return try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    func getTracksByAlbumId(_ albumId: Int64) throws -> [Track] {
        return try read { db in
            // Fetch all tracks for this album
            let tracks = try Track
                .filter(Column("album_id") == albumId)
                .fetchAll(db)

            // Sort in Swift to ensure proper integer sorting
            let sortedTracks = tracks.sorted { track1, track2 in
                // Sort by track number only (ignore disc number)
                let trackNo1 = track1.trackNo ?? 999
                let trackNo2 = track2.trackNo ?? 999

                if trackNo1 != trackNo2 {
                    return trackNo1 < trackNo2
                }

                // Tiebreaker: sort by title
                return track1.title < track2.title
            }

            return sortedTracks
        }
    }

    func getTracksByArtistId(_ artistId: Int64) throws -> [Track] {
        return try read { db in
            return try Track.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT track.*
                    FROM track
                    LEFT JOIN track_artist ON track_artist.track_stable_id = track.stable_id
                    WHERE track.artist_id = ? OR track_artist.artist_id = ?
                    ORDER BY track.title
                """,
                arguments: [artistId, artistId]
            )
        }
    }

    /// 按多个 artist id 查曲目（去重 union），供归一后的歌手详情聚合
    /// （同名简繁两行 artist 的曲目合并显示）。
    func getTracksByArtistIds(_ ids: [Int64]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let uniqueIds = Array(Set(ids))
        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ",")
        return try read { db in
            return try Track.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT track.*
                    FROM track
                    LEFT JOIN track_artist ON track_artist.track_stable_id = track.stable_id
                    WHERE track.artist_id IN (\(placeholders)) OR track_artist.artist_id IN (\(placeholders))
                    ORDER BY track.title
                """,
                arguments: StatementArguments(uniqueIds + uniqueIds)
            )
        }
    }
}
