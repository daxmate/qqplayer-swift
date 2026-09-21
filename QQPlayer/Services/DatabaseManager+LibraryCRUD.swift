//
//  DatabaseManager+LibraryCRUD.swift
//  QQPlayer
//
//  歌手 / 专辑写读与歌手显示名缓存：upsertArtist / upsertAlbum（含重名判据助手）、
//  getAllArtists / getAllAlbums / getAlbum / getAlbumsByArtistId / setAlbumArtists /
//  getArtist / getAllArtistNamesById / getArtistDisplayName(s) / invalidateArtistDisplayNameCache。
//
//  2026-09-21 从 DatabaseManager+Library.swift 原样搬出（纯搬家，无逻辑变更）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - Artist operations

    /// 歌手入库唯一入口。落库的名字与判据都用**规范形**（简体，与 UI 语言解耦）：
    /// artist.name 是 COLLATE NOCASE，对汉字无效，「周杰倫 / 周杰伦」在原文精确匹配下
    /// 会各建一行 = 用户看到的重复歌手（2026-09-18 用户拍板「落库全部是简体中文」）。
    /// 此前 _only_ 显示层做过字形归一（ArtistNameNormalizer.displayName），库里仍是两行。
    func upsertArtist(name: String) throws -> Artist {
        let canonicalName = DisplayScriptNormalizer.canonical(name)
        return try write { db in
            if let existing = try Artist.filter(Column("name") == canonicalName).fetchOne(db) {
                return existing
            }

            let artist = Artist(name: canonicalName)
            return try artist.insertAndFetch(db)!
        }
    }

    func getAllArtists() throws -> [Artist] {
        return try read { db in
            return try Artist.order(Column("name")).fetchAll(db)
        }
    }

    // MARK: - Album operations

    func upsertAlbum(title: String, artistId: Int64?, year: Int?, albumArtist: String?, candidateArtistIds: [Int64] = []) throws -> Album {
        return try write { db in
            let normalizedTitle = self.albumMatchKey(title)

            // Match albums by title and primary artist. The same album title can exist for different artists.
            if let existing = try Album
                .filter(Column("title") == normalizedTitle && Column("artist_id") == artistId)
                .fetchOne(db) {
                return try self.albumWithYearFilled(existing, year: year, db: db)
            }

            // If no exact match, try case-insensitive and similar matches.
            // Only albums by this track's artists can match anyway, so
            // filter in SQL instead of fetching every album per track
            // (that scan made large imports quadratic)
            var relevantArtistIds = Set(candidateArtistIds)
            if let artistId { relevantArtistIds.insert(artistId) }
            let existingAlbums = try Album
                .filter(relevantArtistIds.contains(Column("artist_id")))
                .fetchAll(db)

            for existing in existingAlbums {
                let existingNormalized = self.albumMatchKey(existing.title)

                // Match by normalized title (case-insensitive)
                guard existing.artistId == artistId else { continue }

                if existingNormalized.lowercased() == normalizedTitle.lowercased() {
                    return try self.albumWithYearFilled(existing, year: year, db: db)
                }

                // Check for very similar titles (minor differences)
                if self.areSimilarTitles(existingNormalized, normalizedTitle) {
                    return try self.albumWithYearFilled(existing, year: year, db: db)
                }
            }

            // Fallback: a same-titled album whose primary artist is any of this
            // track's artists. Groups featured tracks (whose primary artist
            // differs, e.g. "Guest; Main") into the main album instead of
            // spawning one album per collab string (issue #81)
            if !candidateArtistIds.isEmpty {
                let candidates = Set(candidateArtistIds)
                for existing in existingAlbums {
                    guard let existingArtistId = existing.artistId,
                          candidates.contains(existingArtistId) else { continue }
                    // Same title but conflicting years = genuinely different albums
                    if let existingYear = existing.year, let year, existingYear != year { continue }

                    let existingNormalized = self.albumMatchKey(existing.title)
                    if existingNormalized.lowercased() == normalizedTitle.lowercased() ||
                        self.areSimilarTitles(existingNormalized, normalizedTitle) {
                        return try self.albumWithYearFilled(existing, year: year, db: db)
                    }
                }
            }

            // No existing match found, create new album
            // album_artist 与 title 同源：入库一律写规范形（存量迁移也会改这一列），
            // 否则旧行简体、新行繁体，同一列里两种字形并存。
            let album = Album(
                artistId: artistId,
                title: normalizedTitle,
                year: year,
                albumArtist: albumArtist.map(DisplayScriptNormalizer.canonical)
            )
            return try album.insertAndFetch(db)!
        }
    }

    /// 存量专辑补 year：早前扫描（MP3 年份帧未解析）写下的 album.year 全为
    /// NULL，重扫时匹配到 existing 直接返回不会更新。这里在 year 由 nil 变为
    /// 有值时回填，修复后重扫一次即可恢复年代自动歌单。
    private func albumWithYearFilled(_ existing: Album, year: Int?, db: Database) throws -> Album {
        guard existing.year == nil, let year else { return existing }
        var updated = existing
        updated.year = year
        try updated.update(db)
        return updated
    }

    private func areSimilarTitles(_ title1: String, _ title2: String) -> Bool {
        // Use folding to handle diacritics while preserving all Unicode characters
        let clean1 = title1.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespaces).joined()
        let clean2 = title2.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .whitespaces).joined()

        // If they're identical after removing punctuation and whitespace, consider them the same
        if clean1 == clean2 {
            return true
        }

        // Only check substring matching if the strings are both non-empty and share the same script
        // This prevents Thai albums from matching English albums
        guard !clean1.isEmpty && !clean2.isEmpty else {
            return false
        }

        // Check if both strings use similar character sets (prevent cross-script matching)
        let hasLatin1 = clean1.rangeOfCharacter(from: .letters) != nil && clean1.rangeOfCharacter(from: CharacterSet(charactersIn: "a" ... "z")) != nil
        let hasLatin2 = clean2.rangeOfCharacter(from: .letters) != nil && clean2.rangeOfCharacter(from: CharacterSet(charactersIn: "a" ... "z")) != nil

        // Only allow substring matching if both are Latin or both are non-Latin
        if hasLatin1 != hasLatin2 {
            return false
        }

        // Check if one is a substring of the other (for cases like "Album" vs "Album - Extended")
        if clean1.contains(clean2) || clean2.contains(clean1) {
            let lengthDiff = abs(clean1.count - clean2.count)
            // Only consider similar if the difference is small (less than 30% difference)
            let maxLength = max(clean1.count, clean2.count)
            return lengthDiff <= max(3, maxLength / 3)
        }

        return false
    }

    /// 专辑判据（含归名）的**唯一构造**：先写规范形（简体，与 UI 语言解耦），
    /// 再去结构性后缀/空白。upsertAlbum 的全部比较点与 issue #81 的分组键都用它 ——
    /// 少一层简繁归一，简繁分裂的同名专辑就永远分不到同一组（2026-09-18）。
    /// 分片：跨文件可见（原 private）
    func albumMatchKey(_ title: String) -> String {
        normalizeAlbumTitle(DisplayScriptNormalizer.canonical(title))
    }

    private func normalizeAlbumTitle(_ title: String) -> String {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common variations that cause duplicates
        let patternsToRemove = [
            " (Deluxe Edition)",
            " (Deluxe)",
            " (Extended Version)",
            " (Remastered)",
            " [Explicit]",
            " - EP",
            " EP",
        ]

        for pattern in patternsToRemove where normalized.hasSuffix(pattern) {
            normalized = String(normalized.dropLast(pattern.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove extra whitespace
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        return normalized.isEmpty ? title : normalized
    }

    func getAllAlbums() throws -> [Album] {
        return try read { db in
            return try Album.order(Column("title")).fetchAll(db)
        }
    }

    /// 按 id 查专辑（标签编辑表单的专辑 year 兜底用：文件解析无 year 时
    /// 用 track.albumId → Album.year 预填）。查无 → nil。
    func getAlbum(byId albumId: Int64) throws -> Album? {
        return try read { db in
            try Album.fetchOne(db, key: albumId)
        }
    }

    func getAlbumsByArtistId(_ artistId: Int64) throws -> [Album] {
        return try read { db in
            return try Album.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT album.*
                    FROM album
                    LEFT JOIN album_artist_link ON album_artist_link.album_id = album.id
                    WHERE album.artist_id = ? OR album_artist_link.artist_id = ?
                    ORDER BY album.title
                """,
                arguments: [artistId, artistId]
            )
        }
    }

    func setAlbumArtists(albumId: Int64, artistIds: [Int64]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM album_artist_link WHERE album_id = ?", arguments: [albumId])

            for (position, artistId) in artistIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [albumId, artistId, position]
                )
            }
        }
    }

    func getArtist(byId id: Int64) throws -> Artist? {
        return try read { db in
            return try Artist.filter(Column("id") == id).fetchOne(db)
        }
    }

    func getAllArtistNamesById() throws -> [Int64: String] {
        return try read { db in
            let artists = try Artist.fetchAll(db)
            var result: [Int64: String] = [:]
            result.reserveCapacity(artists.count)

            for artist in artists {
                if let id = artist.id {
                    // 显示层简繁归一：同一歌手的繁/简两行归一到同一字形
                    result[id] = ArtistNameNormalizer.displayName(artist.name)
                }
            }

            return result
        }
    }

    func invalidateArtistDisplayNameCache() {
        artistDisplayNameCacheLock.lock()
        artistDisplayNameCache.removeAll()
        artistDisplayNameCacheLock.unlock()
    }

    func getArtistDisplayName(forTrackStableId stableId: String, fallbackArtistId: Int64?) throws -> String? {
        artistDisplayNameCacheLock.lock()
        let cached = artistDisplayNameCache[stableId]
        artistDisplayNameCacheLock.unlock()
        if let cached { return cached }

        return try read { db in
            let names = try String.fetchAll(
                db,
                sql: """
                    SELECT artist.name
                    FROM track_artist
                    JOIN artist ON artist.id = track_artist.artist_id
                    WHERE track_artist.track_stable_id = ?
                    ORDER BY track_artist.position
                """,
                arguments: [stableId]
            )

            if !names.isEmpty {
                let display = names.map { ArtistNameNormalizer.displayName($0) }.joined(separator: " / ")
                self.artistDisplayNameCacheLock.lock()
                self.artistDisplayNameCache[stableId] = display
                self.artistDisplayNameCacheLock.unlock()
                return display
            }

            // Fallback results depend on fallbackArtistId, so don't cache them
            guard let fallbackArtistId else { return nil }
            return try Artist.fetchOne(db, key: fallbackArtistId).map { ArtistNameNormalizer.displayName($0.name) }
        }
    }

    func getArtistDisplayNames(
        forTrackStableIds stableIds: [String],
        fallbackArtistIdsByStableId: [String: Int64] = [:]
    ) throws -> [String: String] {
        guard !stableIds.isEmpty else { return [:] }

        artistDisplayNameCacheLock.lock()
        let cachedValues = stableIds.reduce(into: [String: String]()) { result, stableId in
            if let cached = artistDisplayNameCache[stableId] {
                result[stableId] = cached
            }
        }
        artistDisplayNameCacheLock.unlock()

        let missingStableIds = stableIds.filter { cachedValues[$0] == nil }
        guard !missingStableIds.isEmpty else { return cachedValues }

        var result = cachedValues

        try read { db in
            var groupedNames: [String: [String]] = [:]
            let chunkSize = 500

            for start in stride(from: 0, to: missingStableIds.count, by: chunkSize) {
                let end = min(start + chunkSize, missingStableIds.count)
                let chunk = Array(missingStableIds[start ..< end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT track_artist.track_stable_id AS stable_id, artist.name AS artist_name
                        FROM track_artist
                        JOIN artist ON artist.id = track_artist.artist_id
                        WHERE track_artist.track_stable_id IN (\(placeholders))
                        ORDER BY track_artist.track_stable_id, track_artist.position
                    """,
                    arguments: StatementArguments(chunk)
                )

                for row in rows {
                    let stableId: String = row["stable_id"]
                    let artistName: String = row["artist_name"]
                    groupedNames[stableId, default: []].append(artistName)
                }
            }

            for (stableId, names) in groupedNames where !names.isEmpty {
                result[stableId] = names.map { ArtistNameNormalizer.displayName($0) }.joined(separator: " / ")
            }

            let fallbackArtistIds = Set(missingStableIds.compactMap { stableId in
                result[stableId] == nil ? fallbackArtistIdsByStableId[stableId] : nil
            })

            if !fallbackArtistIds.isEmpty {
                let artists = try Artist
                    .filter(fallbackArtistIds.contains(Column("id")))
                    .fetchAll(db)
                let namesById = Dictionary(uniqueKeysWithValues: artists.compactMap { artist in
                    artist.id.map { ($0, artist.name) }
                })

                for stableId in missingStableIds where result[stableId] == nil {
                    if let artistId = fallbackArtistIdsByStableId[stableId],
                       let name = namesById[artistId] {
                        result[stableId] = ArtistNameNormalizer.displayName(name)
                    }
                }
            }
        }

        artistDisplayNameCacheLock.lock()
        for (stableId, displayName) in result {
            artistDisplayNameCache[stableId] = displayName
        }
        artistDisplayNameCacheLock.unlock()

        return result
    }
}
