//
//  DatabaseManager+Library.swift
//  QQPlayer
//
//  Artist/Album CRUD、歌手显示名缓存、搜索（Levenshtein 粗筛）、
//  存量修复迁移（拆合唱歌手/合并分裂专辑/孤儿清理）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - Artist operations

    func upsertArtist(name: String) throws -> Artist {
        return try write { db in
            if let existing = try Artist.filter(Column("name") == name).fetchOne(db) {
                return existing
            }

            let artist = Artist(name: name)
            return try artist.insertAndFetch(db)!
        }
    }

    func getAllArtists() throws -> [Artist] {
        return try read { db in
            return try Artist.order(Column("name")).fetchAll(db)
        }
    }

    func searchArtists(query: String, limit: Int = 20) throws -> [Artist] {
        return try read { db in
            // 简繁归一：query 生成两种字形变体（当前方向转换 + 反向转换），
            // 简体 UI 下输"周杰伦"也能匹配库里"周傑倫"（反之对称）
            let patterns = ArtistNameNormalizer.searchVariants(of: query).map { "%\($0)%" }
            var request = Artist.all()
            if patterns.count == 1 {
                request = request.filter(Column("name").like(patterns[0]))
            } else {
                let conditions = patterns.map { Column("name").like($0) }
                request = request.filter(conditions.dropFirst().reduce(conditions[0]) { $0 || $1 })
            }
            return try request
                .order(Column("name"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Album operations

    func upsertAlbum(title: String, artistId: Int64?, year: Int?, albumArtist: String?, candidateArtistIds: [Int64] = []) throws -> Album {
        return try write { db in
            let normalizedTitle = self.normalizeAlbumTitle(title)

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
                let existingNormalized = self.normalizeAlbumTitle(existing.title)

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

                    let existingNormalized = self.normalizeAlbumTitle(existing.title)
                    if existingNormalized.lowercased() == normalizedTitle.lowercased() ||
                        self.areSimilarTitles(existingNormalized, normalizedTitle) {
                        return try self.albumWithYearFilled(existing, year: year, db: db)
                    }
                }
            }

            // No existing match found, create new album
            let album = Album(artistId: artistId, title: normalizedTitle, year: year, albumArtist: albumArtist)
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

    func searchAlbums(query: String, limit: Int = 30) throws -> [Album] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Album
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
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

    // MARK: - Search operations

    /// Escapes `%`, `_` and `\` so user input is matched literally instead of
    /// acting as LIKE wildcards (audit: unescaped LIKE pattern matched the
    /// whole library for a `%` query).
    private func escapeLikePattern(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func rankedTrackSearch(in db: Database, query: String, limit: Int?) throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var request = Track.order(Column("title"))
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }

        let literalRequest = Track
            .filter(Column("title").like("%\(escapeLikePattern(trimmed))%", escape: "\\"))
            .order(Column("title"))
        let literal = try (limit.map { literalRequest.limit($0) } ?? literalRequest).fetchAll(db)
        if !literal.isEmpty { return literal }

        // Siri transcription and spelling errors rarely survive a SQL LIKE.
        // Rank only a cheaply-prefiltered candidate set instead of loading the
        // whole library and Levenshtein-ing every row (audit): a length window
        // (a 0.58 similarity floor forces title length within ~0.5x-2x of the
        // query) plus a contains-first-char filter shrink the candidate set
        // from the full table to a few hundred rows. The first-char filter
        // also matches the full-width variant so 全角 queries still hit
        // half-width titles.
        let queryLength = trimmed.count
        let lowerBound = max(1, Int(Double(queryLength) * 0.5))
        let upperBound = max(queryLength + 1, Int(Double(queryLength) * 2.0) + 1)
        var request = Track.filter(
            length(Column("title")) >= lowerBound && length(Column("title")) <= upperBound
        )
        if let firstChar = trimmed.first {
            let fullWidthChar = String(firstChar)
            let halfWidthChar = fullWidthChar.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? fullWidthChar
            let escapedChar = escapeLikePattern(fullWidthChar)
            if halfWidthChar == fullWidthChar {
                request = request.filter(Column("title").like("%\(escapedChar)%", escape: "\\"))
            } else {
                let escapedHalfWidth = escapeLikePattern(halfWidthChar)
                request = request.filter(
                    Column("title").like("%\(escapedChar)%", escape: "\\")
                        || Column("title").like("%\(escapedHalfWidth)%", escape: "\\")
                )
            }
        }

        let ranked = try request.fetchAll(db).map { track in
            (track: track, score: trimmed.qqplayerSearchSimilarity(to: track.title))
        }
        .filter { $0.score >= 0.58 }
        .sorted {
            if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
            return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
        }

        let best = ranked.first?.score ?? 0
        let closeMatches = ranked.filter { $0.score >= max(0.58, best - 0.10) }.map(\.track)
        return Array(closeMatches.prefix(limit ?? 5))
    }

    func searchTracks(query: String) throws -> [Track] {
        return try read { db in
            try self.rankedTrackSearch(in: db, query: query, limit: nil)
        }
    }

    func searchAlbums(query: String) throws -> [Album] {
        return try read { db in
            let searchPattern = "%\(query)%"
            return try Album
                .filter(Column("title").like(searchPattern))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func searchArtists(query: String) throws -> [Artist] {
        return try read { db in
            // 简繁归一：与 searchArtists(query:limit:) 一致，query 生成两种字形变体
            let patterns = ArtistNameNormalizer.searchVariants(of: query).map { "%\($0)%" }
            var request = Artist.all()
            if patterns.count == 1 {
                request = request.filter(Column("name").like(patterns[0]))
            } else {
                let conditions = patterns.map { Column("name").like($0) }
                request = request.filter(conditions.dropFirst().reduce(conditions[0]) { $0 || $1 })
            }
            return try request
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    func searchPlaylists(query: String) throws -> [Playlist] {
        return try read { db in
            let searchPattern = "%\(query)%"
            return try Playlist
                .filter(Column("title").like(searchPattern))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func searchTracks(query: String, limit: Int = 50) throws -> [Track] {
        return try read { db in
            try self.rankedTrackSearch(in: db, query: query, limit: limit)
        }
    }

    /// Repairs libraries indexed before multi-artist splitting: artist rows
    /// like "A; B" or "A\\B" are split into individual artists and every
    /// reference re-linked (issue #16). Idempotent - split rows are deleted,
    /// so later launches find nothing to do.
    func migrateSplitCombinedArtistNames() throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            let combinedArtists = try Artist.fetchAll(db).filter {
                $0.name.contains(";") || $0.name.contains("\\\\")
            }

            for combinedArtist in combinedArtists {
                guard let combinedId = combinedArtist.id else { continue }

                // Same separators as LibraryIndexer.parseArtistNames
                var parts = [combinedArtist.name]
                for delimiter in [";", "\\\\", "\u{0}"] {
                    parts = parts.flatMap { $0.components(separatedBy: delimiter) }
                }
                var seen = Set<String>()
                let names: [String] = parts.compactMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    guard !trimmed.isEmpty, !seen.contains(key) else { return nil }
                    seen.insert(key)
                    return trimmed
                }
                guard names.count > 1 else { continue }

                var artistIds: [Int64] = []
                for name in names {
                    if let existing = try Artist.filter(Column("name") == name).fetchOne(db),
                       let id = existing.id {
                        artistIds.append(id)
                    } else if let inserted = try Artist(name: name).insertAndFetch(db),
                              let id = inserted.id {
                        artistIds.append(id)
                    }
                }
                guard let primaryId = artistIds.first else { continue }

                // Re-link track_artist rows to the individual artists
                let trackRows = try Row.fetchAll(
                    db,
                    sql: "SELECT track_stable_id, position FROM track_artist WHERE artist_id = ?",
                    arguments: [combinedId]
                )
                for row in trackRows {
                    let stableId: String = row["track_stable_id"]
                    let basePosition: Int = row["position"]
                    for (index, artistId) in artistIds.enumerated() {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position) VALUES (?, ?, ?)",
                            arguments: [stableId, artistId, basePosition * 100 + index]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM track_artist WHERE artist_id = ?", arguments: [combinedId])

                // Re-link album_artist_link rows
                let albumRows = try Row.fetchAll(
                    db,
                    sql: "SELECT album_id, position FROM album_artist_link WHERE artist_id = ?",
                    arguments: [combinedId]
                )
                for row in albumRows {
                    let albumId: Int64 = row["album_id"]
                    let basePosition: Int = row["position"]
                    for (index, artistId) in artistIds.enumerated() {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position) VALUES (?, ?, ?)",
                            arguments: [albumId, artistId, basePosition * 100 + index]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM album_artist_link WHERE artist_id = ?", arguments: [combinedId])

                // Repoint primary references BEFORE deleting the combined row:
                // album.artist_id cascades on artist deletion, so a stale
                // reference would take whole albums down with it
                try db.execute(sql: "UPDATE track SET artist_id = ? WHERE artist_id = ?", arguments: [primaryId, combinedId])
                try db.execute(sql: "UPDATE album SET artist_id = ? WHERE artist_id = ?", arguments: [primaryId, combinedId])

                try db.execute(sql: "DELETE FROM artist WHERE id = ?", arguments: [combinedId])
                print("🎤 Split combined artist '\(combinedArtist.name)' into: \(names.joined(separator: ", "))")
            }
        }
    }

    /// Merges albums that were split because their tracks' artist strings
    /// differed (featured guests - issue #81): same normalized title, at
    /// least one shared artist, and no conflicting year. Keeps the entry
    /// with the most tracks. Idempotent - merged duplicates are deleted.
    func migrateMergeSplitAlbums() throws {
        try write { db in
            let albums = try Album.fetchAll(db)
            var groups: [String: [Album]] = [:]
            for album in albums {
                groups[self.normalizeAlbumTitle(album.title).lowercased(), default: []].append(album)
            }

            for (_, group) in groups where group.count > 1 {
                // An album's full artist set: primary artist, linked album
                // artists, and every artist credited on its tracks
                func artistSet(for albumId: Int64, primary: Int64?) throws -> Set<Int64> {
                    var ids = Set(try Int64.fetchAll(db, sql: """
                        SELECT artist_id FROM album_artist_link WHERE album_id = ?
                        UNION SELECT artist_id FROM track WHERE album_id = ? AND artist_id IS NOT NULL
                        UNION SELECT ta.artist_id FROM track_artist ta
                              JOIN track t ON t.stable_id = ta.track_stable_id
                              WHERE t.album_id = ?
                    """, arguments: [albumId, albumId, albumId]))
                    if let primary { ids.insert(primary) }
                    return ids
                }

                let ranked: [(album: Album, trackCount: Int)] = try group.compactMap { album in
                    guard let id = album.id else { return nil }
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE album_id = ?", arguments: [id]) ?? 0
                    return (album, count)
                }.sorted { $0.trackCount > $1.trackCount }

                guard let keeper = ranked.first, let keeperId = keeper.album.id else { continue }
                var keeperArtists = try artistSet(for: keeperId, primary: keeper.album.artistId)

                for entry in ranked.dropFirst() {
                    guard let dupId = entry.album.id else { continue }
                    let dupArtists = try artistSet(for: dupId, primary: entry.album.artistId)
                    // Only merge albums that share an artist - same-titled
                    // albums by unrelated artists are legitimately separate
                    guard !keeperArtists.isDisjoint(with: dupArtists) else { continue }
                    if let keeperYear = keeper.album.year, let dupYear = entry.album.year,
                       keeperYear != dupYear { continue }

                    try db.execute(sql: "UPDATE track SET album_id = ? WHERE album_id = ?", arguments: [keeperId, dupId])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                        SELECT ?, artist_id, position + 1000 FROM album_artist_link WHERE album_id = ?
                    """, arguments: [keeperId, dupId])
                    try db.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [dupId])
                    keeperArtists.formUnion(dupArtists)
                    print("💿 Merged split album '\(entry.album.title)' into '\(keeper.album.title)'")
                }
            }
        }
    }

    /// Purges stale link rows, empty albums, and artists nothing references.
    /// Runs after every track deletion and once at startup, so libraries
    /// damaged by the old deleteTrack (which leaked track_artist rows and
    /// kept empty artists alive - issue #74) heal on next launch.
    func cleanupOrphanedLibraryEntries() throws {
        try write { db in
            // Link rows for tracks that no longer exist - track_artist has no
            // FK to track, so these never cascade and must be purged manually
            try db.execute(sql: """
                DELETE FROM track_artist
                WHERE track_stable_id NOT IN (SELECT stable_id FROM track)
            """)

            // Delete albums that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM album
                WHERE id NOT IN (
                    SELECT DISTINCT album_id
                    FROM track
                    WHERE album_id IS NOT NULL
                )
            """)

            // Link rows for albums that no longer exist - the FK cascade
            // covers this when foreign keys are on, but don't rely on it
            // (older app versions may have written without the pragma)
            try db.execute(sql: """
                DELETE FROM album_artist_link
                WHERE album_id NOT IN (SELECT id FROM album)
            """)

            // Delete artists that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM artist
                WHERE id NOT IN (
                    SELECT DISTINCT artist_id
                    FROM track
                    WHERE artist_id IS NOT NULL
                    UNION
                    SELECT DISTINCT artist_id
                    FROM track_artist
                    UNION
                    SELECT DISTINCT artist_id
                    FROM album_artist_link
                )
            """)
        }
    }
}
private extension String {
    var qqplayerSearchNormalized: String {
        let folded = folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let searchable = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
        return searchable
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }

    func qqplayerSearchSimilarity(to other: String) -> Double {
        let left = Array(qqplayerSearchNormalized)
        let right = Array(other.qqplayerSearchNormalized)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let leftString = String(left)
        let rightString = String(right)
        if leftString == rightString { return 1 }
        if rightString.contains(leftString) { return 0.95 }

        var previous = Array(0 ... right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = Swift.min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }
}
