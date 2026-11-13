//
//  RecommendationV3DataSource.swift
//  QQPlayer
//
//  推荐 v3：轻量 I/O（只读）。画像输入的完整读取复用 `RecommendationDataSource`（一次 DB 读，不重复开第二份）。
//

import Foundation

enum RecommendationV3DataSource {
    /// 只要曲库归一化键（已下载标记 / 排除用；比整份画像轻）。
    static func loadLibraryKeys() async -> Set<String> {
        await Task.detached(priority: .utility) { () -> Set<String> in
            do {
                return try DatabaseManager.shared.read { db in
                    let tracks = try Track.fetchAll(db)
                    let artists = try Artist.fetchAll(db)
                    let artistNames = Dictionary(
                        artists.compactMap { artist in artist.id.map { ($0, artist.name) } },
                        uniquingKeysWith: { first, _ in first }
                    )
                    return Set(
                        tracks.map {
                            RecommendationLibraryMatcher.key(
                                title: $0.title,
                                artist: $0.artistId.flatMap { artistNames[$0] } ?? ""
                            )
                        }
                    )
                }
            } catch {
                AppLog.error(.general, "❌ 推荐 v3 曲库键读取失败：\(error)")
                return []
            }
        }.value
    }
}
