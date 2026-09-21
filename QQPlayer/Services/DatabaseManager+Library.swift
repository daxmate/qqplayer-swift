//
//  DatabaseManager+Library.swift
//  QQPlayer
//
//  曲库搜索：LIKE 通配符转义与变体 OR 构造（escapeLikePattern / likePattern / likeAny）、
//  歌手 / 专辑 / 曲目 / 歌单搜索入口与曲目排名粗筛（rankedTrackSearch，Levenshtein 相似度）。
//  尾部 `private extension String` 是搜索专用的归一 / 相似度实现。
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · DatabaseManager+LibraryCRUD.swift       — 歌手 / 专辑写读、歌手显示名缓存
//    · DatabaseManager+LibraryMigrations.swift — 存量修复迁移（归名 / 合唱拆分 / 专辑合并 / 孤儿清理）
//
import Foundation
@preconcurrency import GRDB
extension DatabaseManager {

    func searchArtists(query: String, limit: Int = 20) throws -> [Artist] {
        return try read { db in
            // 简繁归一：query 生成两种字形变体（当前方向转换 + 反向转换），
            // 简体 UI 下输"周杰伦"也能匹配库里"周傑倫"（反之对称）
            return try Artist
                .filter(self.likeAny(Column("name"), variants: ArtistNameNormalizer.searchVariants(of: query)))
                .order(Column("name"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func searchAlbums(query: String, limit: Int = 30) throws -> [Album] {
        return try read { db in
            // D8：与其它搜索共用同一转义入口（用户输 `%`/`_` 不再命中整库）；
            // 简繁字形变体：库里专辑名 tag 原文不动，简中输入也要搜到繁体专辑名（反之对称）
            return try Album
                .filter(self.likeAny(Column("title"), variants: DisplayScriptNormalizer.searchVariants(of: query)))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Search operations

    /// Escapes `%`, `_` and `\` so user input is matched literally instead of
    /// acting as LIKE wildcards (audit: unescaped LIKE pattern matched the
    /// whole library for a `%` query).
    /// LIKE 通配符转义（与曲目搜索同源；调用方必须配 `.like(..., escape: "\\")`）。
    func escapeLikePattern(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 两侧通配的 LIKE 模式（= 任一字段搜索的唯一入口，避免调用方各拼 `"%\(q)%"`）。
    func likePattern(for query: String) -> String {
        "%\(escapeLikePattern(query))%"
    }

    /// 同列多字形变体的 LIKE OR 条件（变体检索的唯一入口：每个变体都走
    /// `likePattern(for:)` 转义，避免调用点各拼 OR / 各拼通配符）。
    /// 用于简繁字形不一致时的召回——库里 tag 原文不动，同一首歌可能以简体或繁体入库，
    /// 单一 LIKE 模式会漏（简中输入搜不到库里繁体曲名，反之对称）。
    private func likeAny(_ column: Column, variants: [String]) -> SQLExpression {
        precondition(!variants.isEmpty, "likeAny 需要至少一个字形变体")
        let conditions = variants.map { column.like(self.likePattern(for: $0), escape: "\\") }
        return conditions.dropFirst().reduce(conditions[0]) { $0 || $1 }
    }

    private func rankedTrackSearch(in db: Database, query: String, limit: Int?) throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var request = Track.order(Column("title"))
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }

        // 简繁字形变体：库里曲名 tag 原文不动，简中输入也要搜到繁体曲名的曲子（反之对称）
        let literalRequest = Track
            .filter(self.likeAny(Column("title"), variants: DisplayScriptNormalizer.searchVariants(of: trimmed)))
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
            // 简繁字形变体（同 searchAlbums(query:limit:)，唯一入口 likeAny）
            return try Album
                .filter(self.likeAny(Column("title"), variants: DisplayScriptNormalizer.searchVariants(of: query)))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func searchArtists(query: String) throws -> [Artist] {
        return try read { db in
            // 简繁归一：与 searchArtists(query:limit:) 一致，query 生成两种字形变体
            return try Artist
                .filter(self.likeAny(Column("name"), variants: ArtistNameNormalizer.searchVariants(of: query)))
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    func searchPlaylists(query: String) throws -> [Playlist] {
        return try read { db in
            let searchPattern = self.likePattern(for: query)
            return try Playlist
                .filter(Column("title").like(searchPattern, escape: "\\"))
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func searchTracks(query: String, limit: Int = 50) throws -> [Track] {
        return try read { db in
            try self.rankedTrackSearch(in: db, query: query, limit: limit)
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
