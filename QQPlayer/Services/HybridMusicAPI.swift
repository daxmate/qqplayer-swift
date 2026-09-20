//
//  HybridMusicAPI.swift
//  QQPlayer
//
//  Hybrid music API service that tries Spotify first, then falls back to Discogs
//

import Foundation

// MARK: - Unified Artist Model

struct UnifiedArtist {
    let id: String
    let name: String
    let profile: String
    let images: [UnifiedImage]
    let source: MusicAPISource

    // Internal data for accessing original objects if needed
    let discogsArtist: DiscogsArtist?
    let spotifyArtist: SpotifyArtist?

    init(from discogsArtist: DiscogsArtist) {
        self.id = String(discogsArtist.id)
        self.name = discogsArtist.name
        self.profile = discogsArtist.profile
        self.images = discogsArtist.images.map { UnifiedImage(from: $0) }
        self.source = .discogs
        self.discogsArtist = discogsArtist
        self.spotifyArtist = nil
    }

    init(from spotifyArtist: SpotifyArtist) {
        self.id = spotifyArtist.id
        self.name = spotifyArtist.name
        self.profile = spotifyArtist.profile
        self.images = spotifyArtist.images.map { UnifiedImage(from: $0) }
        self.source = .spotify
        self.discogsArtist = nil
        self.spotifyArtist = spotifyArtist
    }
}

struct UnifiedImage {
    let url: String
    let width: Int?
    let height: Int?

    init(from discogsImage: DiscogsImage) {
        self.url = discogsImage.uri
        self.width = discogsImage.width
        self.height = discogsImage.height
    }

    init(from spotifyImage: SpotifyImage) {
        self.url = spotifyImage.url
        self.width = spotifyImage.width
        self.height = spotifyImage.height
    }
}

enum MusicAPISource {
    case discogs
    case spotify

    var rawValue: String {
        switch self {
        case .discogs: return "discogs"
        case .spotify: return "spotify"
        }
    }
}

// MARK: - Cached Unified Artist Data

class CachedUnifiedArtistInfo: NSObject, Codable {
    let artistName: String
    let unifiedArtist: UnifiedArtist
    let cachedAt: Date

    init(artistName: String, unifiedArtist: UnifiedArtist, cachedAt: Date) {
        self.artistName = artistName
        self.unifiedArtist = unifiedArtist
        self.cachedAt = cachedAt
        super.init()
    }

    var isExpired: Bool {
        // Cache for 7 days
        return Date().timeIntervalSince(cachedAt) > 7 * 24 * 60 * 60
    }
}

// Make UnifiedArtist and UnifiedImage Codable
extension UnifiedArtist: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, profile, images, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profile = try container.decode(String.self, forKey: .profile)
        images = try container.decode([UnifiedImage].self, forKey: .images)
        source = try container.decode(MusicAPISource.self, forKey: .source)
        discogsArtist = nil
        spotifyArtist = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(profile, forKey: .profile)
        try container.encode(images, forKey: .images)
        try container.encode(source, forKey: .source)
    }
}

extension UnifiedImage: Codable {}
extension MusicAPISource: Codable {}

// MARK: - Hybrid Music API Service

class HybridMusicAPIService: ObservableObject, @unchecked Sendable {
    @MainActor static let shared = HybridMusicAPIService(
        discogsAPI: .shared,
        spotifyAPI: .shared,
        cacheDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("HybridMusicCache")
    )

    private let discogsAPI: DiscogsAPIService
    private let spotifyAPI: SpotifyAPIService

    private let cache = NSCache<NSString, CachedUnifiedArtistInfo>()
    private let cacheDirectory: URL

    /// 依赖注入 init（可测性）：生产代码只通过 `shared` 创建，行为与原先完全一致。
    init(discogsAPI: DiscogsAPIService, spotifyAPI: SpotifyAPIService, cacheDirectory: URL) {
        self.discogsAPI = discogsAPI
        self.spotifyAPI = spotifyAPI
        self.cacheDirectory = cacheDirectory

        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Configure NSCache
        cache.countLimit = 100 // Limit to 100 cached artists
    }

    // MARK: - Public API

    func searchArtist(name: String) async throws -> UnifiedArtist? {
        AppLog.info(.general, "🎵 Hybrid: Searching for artist: \(name)")

        let cachedArtist = getCachedArtist(name: name)
        if let cached = cachedArtist, !cached.isExpired {
            if cached.unifiedArtist.source == .spotify {
                AppLog.info(.general, "✅ Hybrid: Found cached artist: \(name) (source: \(cached.unifiedArtist.source))")
                return cached.unifiedArtist
            }

            AppLog.info(.general, "ℹ️ Hybrid: Found cached Discogs artist for \(name); checking Spotify before reusing it")
        }

        // Prefer Spotify so artist pages can expose Spotify artwork/links when available.
        AppLog.info(.general, "🎯 Hybrid: Trying Spotify for: \(name)")
        do {
            if let spotifyArtist = try await spotifyAPI.searchArtist(name: name) {
                AppLog.info(.general, "✅ Hybrid: Found on Spotify: \(spotifyArtist.name)")
                let unifiedArtist = UnifiedArtist(from: spotifyArtist)
                cacheArtist(name: name, artist: unifiedArtist)
                return unifiedArtist
            }
        } catch {
            AppLog.warn(.general, "⚠️ Hybrid: Spotify failed: \(error.localizedDescription)")
        }

        if let cached = cachedArtist, !cached.isExpired {
            AppLog.info(.general, "✅ Hybrid: Reusing cached artist: \(name) (source: \(cached.unifiedArtist.source))")
            return cached.unifiedArtist
        }

        // Fallback to Discogs for bios and artists unavailable on Spotify.
        AppLog.info(.general, "🎯 Hybrid: Falling back to Discogs for: \(name)")
        do {
            if let discogsArtist = try await discogsAPI.searchArtist(name: name) {
                AppLog.info(.general, "✅ Hybrid: Found on Discogs: \(discogsArtist.name)")
                let unifiedArtist = UnifiedArtist(from: discogsArtist)
                cacheArtist(name: name, artist: unifiedArtist)
                return unifiedArtist
            }
        } catch {
            AppLog.warn(.general, "⚠️ Hybrid: Discogs failed: \(error.localizedDescription)")
        }

        AppLog.error(.general, "❌ Hybrid: No artist found on either platform for: \(name)")
        return nil
    }

    // Search for alternative artist - try different source than current one
    func searchAlternativeArtist(name: String, currentSource: MusicAPISource?) async throws -> UnifiedArtist? {
        AppLog.info(.general, "🔄 Hybrid: Searching for alternative artist: \(name), avoiding source: \(currentSource?.rawValue ?? "none")")

        // If current source is Discogs, try Spotify first
        if currentSource == .discogs {
            AppLog.info(.general, "🎯 Hybrid: Trying Spotify as alternative for: \(name)")
            do {
                if let spotifyArtist = try await spotifyAPI.searchArtist(name: name) {
                    AppLog.info(.general, "✅ Hybrid: Found alternative on Spotify: \(spotifyArtist.name)")
                    let unifiedArtist = UnifiedArtist(from: spotifyArtist)
                    cacheArtist(name: name, artist: unifiedArtist)
                    return unifiedArtist
                }
            } catch {
                AppLog.warn(.general, "⚠️ Hybrid: Spotify alternative failed: \(error.localizedDescription)")
            }
        }

        // If current source is Spotify, try Discogs
        if currentSource == .spotify {
            AppLog.info(.general, "🎯 Hybrid: Trying Discogs as alternative for: \(name)")
            do {
                if let discogsArtist = try await discogsAPI.searchArtist(name: name) {
                    AppLog.info(.general, "✅ Hybrid: Found alternative on Discogs: \(discogsArtist.name)")
                    let unifiedArtist = UnifiedArtist(from: discogsArtist)
                    cacheArtist(name: name, artist: unifiedArtist)
                    return unifiedArtist
                }
            } catch {
                AppLog.warn(.general, "⚠️ Hybrid: Discogs alternative failed: \(error.localizedDescription)")
            }
        }

        // If no current source or first alternative failed, try the opposite order
        if currentSource == nil {
            return try await searchArtist(name: name)
        }

        AppLog.error(.general, "❌ Hybrid: No alternative found for: \(name)")
        return nil
    }

    // Search for similar/alternative artist names
    func searchSimilarArtist(originalName: String, currentSource: MusicAPISource?) async throws -> UnifiedArtist? {
        AppLog.info(.general, "🔍 Hybrid: Searching for similar artist names for: \(originalName)")

        // Generate variations of the artist name
        let variations = generateNameVariations(originalName)

        for variation in variations {
            if variation == originalName { continue } // Skip original name

            AppLog.info(.general, "🎯 Hybrid: Trying variation: \(variation)")
            do {
                if let result = try await searchAlternativeArtist(name: variation, currentSource: currentSource) {
                    AppLog.info(.general, "✅ Hybrid: Found artist with variation '\(variation)': \(result.name)")
                    return result
                }
            } catch {
                AppLog.warn(.general, "⚠️ Hybrid: Variation '\(variation)' failed: \(error.localizedDescription)")
            }
        }

        AppLog.error(.general, "❌ Hybrid: No similar artist found for: \(originalName)")
        return nil
    }

    // MARK: - Helper Methods

    /// 生成相似艺人名变体（确定顺序、去重、截断到 3 个）。
    /// 有序去重：Set 迭代顺序不稳定，会让前缀截取的结果随进程随机变化。
    func generateNameVariations(_ originalName: String) -> [String] {
        var variations: [String] = []

        // Remove common suffixes like "- Topic", ", the", etc.
        let commonSuffixes = ["- Topic", " - Topic", ", The", ", the", " (Official)", " Official"]
        for suffix in commonSuffixes where originalName.contains(suffix) {
            let cleaned = originalName.replacingOccurrences(of: suffix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned != originalName {
                variations.append(cleaned)
            }
        }

        // Remove brackets and parentheses content
        let bracketsPattern = "\\[[^\\]]*\\]|\\([^\\)]*\\)"
        if let regex = try? NSRegularExpression(pattern: bracketsPattern, options: []) {
            let range = NSRange(location: 0, length: originalName.count)
            let cleaned = regex.stringByReplacingMatches(in: originalName, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned != originalName {
                variations.append(cleaned)
            }
        }

        // Try with "The" prefix if not present, or without if present
        if originalName.lowercased().hasPrefix("the ") {
            let withoutThe = String(originalName.dropFirst(4))
            variations.append(withoutThe)
        } else {
            variations.append("The " + originalName)
        }

        // 保持生成顺序去重（Set 顺序不稳定，避免结果随进程随机），再截断到 3 个
        var seen = Set<String>()
        return variations.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    // MARK: - Caching

    private func getCachedArtist(name: String) -> CachedUnifiedArtistInfo? {
        let key = NSString(string: name.lowercased())

        // Check memory cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Check disk cache
        // 文件名安全编码：非字母数字统一替换为 _（2026-08-30 审计清尾）
        let filename = HybridMusicAPIService.safeCacheFilename(name) + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)

        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedUnifiedArtistInfo.self, from: data) else {
            return nil
        }

        // Reclaim the file as soon as it is known to be stale. Callers discard
        // expired entries anyway, and previously the file was left behind
        // until it happened to be overwritten by a fresh lookup.
        if cached.isExpired {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        // Store in memory cache
        cache.setObject(cached, forKey: key)
        return cached
    }

    private func cacheArtist(name: String, artist: UnifiedArtist) {
        let cached = CachedUnifiedArtistInfo(artistName: name, unifiedArtist: artist, cachedAt: Date())
        let key = NSString(string: name.lowercased())

        // Store in memory cache
        cache.setObject(cached, forKey: key)

        // Store in disk cache
        let filename = HybridMusicAPIService.safeCacheFilename(name) + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)

        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL)
            AppLog.info(.general, "💾 Hybrid: Cached artist data for: \(name) (source: \(artist.source))")
        } catch {
            AppLog.error(.general, "❌ Hybrid: Failed to cache artist data: \(error)")
        }
    }

    /// Deletes cache files whose contents have expired. Entries were only ever
    /// checked for staleness on read and then ignored, so the directory grew
    /// without bound - including for artists no longer in the library.
    func purgeExpiredDiskCache() async {
        // Walking the directory and decoding each entry is file work, so keep
        // it off the main thread - this runs during post-index maintenance,
        // alongside the UI.
        let directory = cacheDirectory
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []

            var removed = 0
            for fileURL in files where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL) else { continue }

                // Undecodable entries are stale by definition (format changed
                // or the file is truncated) and can never be served, so drop
                // them too.
                let cached = try? JSONDecoder().decode(CachedUnifiedArtistInfo.self, from: data)
                guard cached == nil || cached!.isExpired else { continue }

                do {
                    try FileManager.default.removeItem(at: fileURL)
                    removed += 1
                } catch {
                    AppLog.error(.general, "❌ Hybrid: Failed to remove expired cache file: \(error)")
                }
            }

            if removed > 0 {
                AppLog.info(.general, "🗑️ Hybrid: Removed \(removed) expired cache file(s)")
            }
        }.value
    }
}

// MARK: - 缓存文件名安全编码（非字母数字统一替换为 _，防路径分隔/逃逸，2026-08-30 审计清尾）

extension HybridMusicAPIService {
    static func safeCacheFilename(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
