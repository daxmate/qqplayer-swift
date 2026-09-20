//
//  SpotifyAPI.swift
//  QQPlayer
//
//  Spotify API service for fetching artist information
//

import Foundation

// MARK: - Spotify API Models

struct SpotifyAuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct SpotifySearchResponse: Codable {
    let artists: SpotifyArtistsResponse
}

struct SpotifyArtistsResponse: Codable {
    let href: String?
    let items: [SpotifyArtist]
    let limit: Int?
    let next: String?
    let offset: Int?
    let previous: String?
    let total: Int?
}

struct SpotifyArtist: Codable {
    let id: String
    let name: String
    let genres: [String]
    let images: [SpotifyImage]
    let popularity: Int
    let followers: SpotifyFollowers
    let externalUrls: SpotifyExternalUrls
    let href: String
    let uri: String

    // Computed property for bio/profile (Spotify doesn't provide artist bios)
    var profile: String {
        var bio = ""

        if !genres.isEmpty {
            let genreDescription = genres.count == 1 ? genres.first! : genres.dropLast().joined(separator: ", ") + " and " + genres.last!
            bio += "Known for their work in \(genreDescription) music"

            if popularity > 80 {
                bio += ", this highly acclaimed artist has gained significant recognition in the music industry"
            } else if popularity > 60 {
                bio += ", this popular artist continues to build their reputation"
            } else if popularity > 40 {
                bio += ", this emerging talent is making their mark"
            } else {
                bio += ", this artist brings a unique sound to their musical style"
            }

            if let followerCount = followers.total, followerCount > 0 {
                if followerCount >= 1000000 {
                    bio += " with millions of dedicated listeners"
                } else if followerCount >= 100000 {
                    bio += " with hundreds of thousands of fans"
                } else if followerCount >= 10000 {
                    bio += " with tens of thousands of followers"
                } else {
                    bio += " with a growing fanbase"
                }
            }

            bio += "."
        } else {
            bio += "An artist exploring diverse musical territories"
            if popularity > 50 {
                bio += " with notable recognition in the music scene"
            }
            bio += "."
        }

        return bio
    }

    enum CodingKeys: String, CodingKey {
        case id, name, genres, images, popularity, followers, href, uri
        case externalUrls = "external_urls"
    }
}

struct SpotifyImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

struct SpotifyFollowers: Codable {
    let href: String?
    let total: Int?
}

struct SpotifyExternalUrls: Codable {
    let spotify: String?
}

// MARK: - Cached Artist Data

class CachedSpotifyArtistInfo: NSObject, Codable {
    let artistName: String
    let spotifyArtist: SpotifyArtist
    let cachedAt: Date

    init(artistName: String, spotifyArtist: SpotifyArtist, cachedAt: Date) {
        self.artistName = artistName
        self.spotifyArtist = spotifyArtist
        self.cachedAt = cachedAt
        super.init()
    }

    var isExpired: Bool {
        // Cache for 7 days
        return Date().timeIntervalSince(cachedAt) > 7 * 24 * 60 * 60
    }
}

// MARK: - Token Cache

class SpotifyAccessToken {
    let token: String
    let expiresAt: Date

    init(token: String, expiresIn: Int) {
        self.token = token
        self.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn - 60)) // Refresh 1 minute early
    }

    var isExpired: Bool {
        return Date() >= expiresAt
    }
}

// MARK: - Spotify API Service

class SpotifyAPIService: ObservableObject, @unchecked Sendable {
    @MainActor static let shared = SpotifyAPIService(
        clientId: EnvironmentLoader.shared.spotifyClientId,
        clientSecret: EnvironmentLoader.shared.spotifyClientSecret,
        session: .shared,
        cacheDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("SpotifyCache")
    )

    private let clientId: String?
    private let clientSecret: String?
    private let baseURL = "https://api.spotify.com/v1"
    private let authURL = "https://accounts.spotify.com/api/token"
    private let session: URLSession

    private let cache = NSCache<NSString, CachedSpotifyArtistInfo>()
    private let cacheDirectory: URL
    /// accessToken 被 async 方法读写（可能并发调用）：NSLock 保护（锁临界区不跨 await，
    /// 同步 helper 内使用合法；2026-08-30 审计清尾）。
    private let tokenLock = NSLock()
    private var accessToken: SpotifyAccessToken?

    private func withTokenLocked<T>(_ body: () -> T) -> T {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return body()
    }

    private func writeTokenLocked(_ body: () -> Void) {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        body()
    }

    /// 依赖注入 init（可测性）：生产代码只通过 `shared` 创建，行为与原先完全一致。
    init(clientId: String?, clientSecret: String?, session: URLSession, cacheDirectory: URL) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.session = session
        self.cacheDirectory = cacheDirectory

        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Configure NSCache
        cache.countLimit = 100 // Limit to 100 cached artists
    }

    // MARK: - Public API

    func searchArtist(name: String) async throws -> SpotifyArtist? {
        AppLog.info(.scrape, "🎵 Spotify: Searching for artist: \(name)")

        // Check cache first
        if let cached = getCachedArtist(name: name), !cached.isExpired {
            AppLog.info(.scrape, "✅ Spotify: Found cached artist: \(name)")
            return cached.spotifyArtist
        }

        // Ensure we have a valid access token
        try await ensureValidAccessToken()

        // Search for artist
        let artists = try await performSearch(query: name, type: "artist")

        // Find best match
        guard let bestMatch = findBestMatch(for: name, in: artists) else {
            AppLog.error(.scrape, "❌ Spotify: No matching artist found for: \(name)")
            return nil
        }

        AppLog.info(.scrape, "🎯 Spotify: Found match: \(bestMatch.name)")

        // Cache the result
        cacheArtist(name: name, artist: bestMatch)

        return bestMatch
    }

    // MARK: - Authentication

    private func ensureValidAccessToken() async throws {
        let token = withTokenLocked { accessToken }
        if let token, !token.isExpired {
            return // Token is still valid
        }

        // Need to get a new token
        AppLog.info(.scrape, "🔐 Spotify: Getting new access token...")
        let newToken = try await getAccessToken()
        writeTokenLocked { accessToken = newToken }
        AppLog.info(.scrape, "✅ Spotify: Successfully obtained access token")
    }

    private func getAccessToken() async throws -> SpotifyAccessToken {
        // Spotify needs both API keys; without them the feature is disabled
        // instead of crashing at startup.
        guard let clientId, let clientSecret, !clientId.isEmpty, !clientSecret.isEmpty else {
            throw SpotifyAPIError.authenticationError
        }
        guard let url = URL(string: authURL) else {
            throw SpotifyAPIError.invalidURL
        }

        // Create credentials string and encode it in base64
        let credentials = "\(clientId):\(clientSecret)"
        guard let credentialsData = credentials.data(using: .utf8) else {
            throw SpotifyAPIError.authenticationError
        }
        let base64Credentials = credentialsData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "grant_type=client_credentials"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            AppLog.info(.scrape, "📡 Spotify Auth: Response status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                throw SpotifyAPIError.httpError(httpResponse.statusCode)
            }
        }

        let authResponse = try JSONDecoder().decode(SpotifyAuthResponse.self, from: data)
        return SpotifyAccessToken(token: authResponse.accessToken, expiresIn: authResponse.expiresIn)
    }

    // MARK: - Search

    private func performSearch(query: String, type: String) async throws -> [SpotifyArtist] {
        let accessToken = withTokenLocked { self.accessToken }
        guard let accessToken else {
            throw SpotifyAPIError.noAccessToken
        }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/search?q=\(encodedQuery)&type=\(type)&limit=10"

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        AppLog.info(.scrape, "🌐 Spotify: Making request to: \(urlString)")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            AppLog.info(.scrape, "📡 Spotify: Response status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                let responseBody = String(data: data, encoding: .utf8)
                if let responseBody, !responseBody.isEmpty {
                    AppLog.error(.scrape, "📡 Spotify: Error response: \(responseBody)")
                }

                if httpResponse.statusCode == 403 {
                    throw SpotifyAPIError.forbidden(responseBody)
                }

                throw SpotifyAPIError.httpError(httpResponse.statusCode)
            }
        }

        let searchResponse = try JSONDecoder().decode(SpotifySearchResponse.self, from: data)
        AppLog.info(.scrape, "🔍 Spotify: Found \(searchResponse.artists.items.count) results")

        return searchResponse.artists.items
    }

    private func findBestMatch(for artistName: String, in results: [SpotifyArtist]) -> SpotifyArtist? {
        let normalizedName = artistName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        // Try exact match first
        for result in results {
            let resultName = result.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if resultName == normalizedName {
                return result
            }
        }

        // Try partial match
        for result in results {
            let resultName = result.name.lowercased()
            if resultName.contains(normalizedName) || normalizedName.contains(resultName) {
                return result
            }
        }

        // Return first result if no exact match
        return results.first
    }

    // MARK: - Caching

    private func getCachedArtist(name: String) -> CachedSpotifyArtistInfo? {
        let key = NSString(string: name.lowercased())

        // Check memory cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Check disk cache
        // 文件名安全编码：歌手名可能含 /、.. 等路径特殊字符（AC/DC 曾静默写失败、
        // 极端名可逃逸缓存目录，2026-08-30 审计清尾）：非字母数字统一替换为 _。
        let filename = Self.safeCacheFilename(name) + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)

        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedSpotifyArtistInfo.self, from: data) else {
            return nil
        }

        // Store in memory cache
        cache.setObject(cached, forKey: key)
        return cached
    }

    private func cacheArtist(name: String, artist: SpotifyArtist) {
        let cached = CachedSpotifyArtistInfo(artistName: name, spotifyArtist: artist, cachedAt: Date())
        let key = NSString(string: name.lowercased())

        // Store in memory cache
        cache.setObject(cached, forKey: key)

        // Store in disk cache
        let filename = Self.safeCacheFilename(name) + ".json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)

        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL)
            AppLog.info(.scrape, "💾 Spotify: Cached artist data for: \(name)")
        } catch {
            AppLog.error(.scrape, "❌ Spotify: Failed to cache artist data: \(error)")
        }
    }
}

// MARK: - Errors

enum SpotifyAPIError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)
    case forbidden(String?)
    case authenticationError
    case noAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let code):
            return "HTTP Error: \(code)"
        case .forbidden(let message):
            if let message, !message.isEmpty {
                return "Spotify access forbidden: \(message)"
            }
            return "Spotify access forbidden. Check that Web API access is enabled for this Spotify app and that the client credentials are from the correct app."
        case .authenticationError:
            return "Authentication Error"
        case .noAccessToken:
            return "No valid access token"
        }
    }
}

/// 缓存文件名安全编码：非字母数字统一替换为 _（防路径分隔/逃逸，2026-08-30 审计清尾）
extension SpotifyAPIService {
    static func safeCacheFilename(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
