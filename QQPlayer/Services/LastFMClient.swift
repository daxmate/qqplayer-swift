//
//  LastFMClient.swift
//  QQPlayer
//
//  推荐 v3：Last.fm 召回客户端（艺人热歌 / 相似艺人）。
//
//  - API key 只从钥匙串读（设置页写入），**不硬编码、不进日志、不进 URL 日志**。
//  - 无 key → 立即返回空数组（调用方走降级链），不抛错、不打网络。
//  - 网络 / 解析失败 → 空数组（推荐是增益功能，失败不阻塞主流程）。
//

import Foundation

// MARK: - key 存储

/// Last.fm API key 读取（生产 = 钥匙串；测试 = 内存桩）。
protocol LastFMKeyProviding: Sendable {
    func apiKey() -> String?
}

/// 钥匙串实现：service com.daxmate.qqplayer.lastfm / account api_key。
struct KeychainLastFMKeyStore: LastFMKeyProviding {
    static let service = "com.daxmate.qqplayer.lastfm"
    static let account = "api_key"

    private let keychain: any SyncKeychainStoring

    init(keychain: any SyncKeychainStoring = SystemKeychainStore()) {
        self.keychain = keychain
    }

    func apiKey() -> String? {
        guard let data = try? keychain.loadData(service: Self.service, account: Self.account),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 写入 / 覆盖（空串 = 删除）。
    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try keychain.deleteData(service: Self.service, account: Self.account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        try keychain.saveData(data, service: Self.service, account: Self.account)
    }
}

// MARK: - 模型

struct LastFMTrack: Sendable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var durationMs: Int?
    /// 来源榜内位置（0 = 第一条）。
    var rank: Int
    /// 播放数（热度；给不出 = nil）。
    var listeners: Int?
}

struct LastFMArtist: Sendable, Equatable {
    var name: String
    /// 0…1（Last.fm match；给不出 = nil）。
    var match: Double?
}

// MARK: - 客户端

struct LastFMClient: Sendable {
    var transport: any NetworkTransport
    var keyProvider: any LastFMKeyProviding

    init(
        transport: any NetworkTransport = URLSessionNetworkTransport(),
        keyProvider: any LastFMKeyProviding = KeychainLastFMKeyStore()
    ) {
        self.transport = transport
        self.keyProvider = keyProvider
    }

    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// 艺人热门曲（method=artist.gettoptracks）。无 key / 失败 → []。
    func topTracks(artist: String, limit: Int = 10) async -> [LastFMTrack] {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        guard let object = await request([
            "method": "artist.gettoptracks",
            "artist": name,
            "limit": String(max(1, min(50, limit))),
        ]) else { return [] }
        guard let tracks = (object["toptracks"] as? [String: Any])?["track"] as? [[String: Any]] else { return [] }
        return tracks.enumerated().compactMap { index, raw in
            guard let title = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { return nil }
            let artistName = ((raw["artist"] as? [String: Any])?["name"] as? String) ?? name
            let album = (raw["album"] as? [String: Any])?["title"] as? String
            return LastFMTrack(
                title: title,
                artist: artistName,
                album: album,
                durationMs: Self.milliseconds(raw["duration"]),
                rank: index,
                listeners: Self.integer(raw["listeners"])
            )
        }
    }

    /// 相似艺人（method=artist.getsimilar）。无 key / 失败 → []。
    func similarArtists(artist: String, limit: Int = 5) async -> [LastFMArtist] {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        guard let object = await request([
            "method": "artist.getsimilar",
            "artist": name,
            "limit": String(max(1, min(20, limit))),
        ]) else { return [] }
        guard let artists = (object["similarartists"] as? [String: Any])?["artist"] as? [[String: Any]] else { return [] }
        return artists.compactMap { raw in
            guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return LastFMArtist(name: name, match: Self.double(raw["match"]))
        }
    }

    // MARK: - 内部

    private func request(_ parameters: [String: String]) async -> [String: Any]? {
        guard let key = keyProvider.apiKey() else { return nil }
        var items = parameters
        items["api_key"] = key
        items["format"] = "json"
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = items
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }
        do {
            let (data, http) = try await transport.data(for: URLRequest(url: url))
            guard http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            // 不打印 URL（含 api_key）。
            AppLog.warn(.general, "⚠️ Last.fm 请求失败（已降级）")
            return nil
        }
    }

    private static func milliseconds(_ raw: Any?) -> Int? {
        guard let seconds = integer(raw), seconds > 0 else { return nil }
        return seconds * 1000
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    private static func double(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let text = raw as? String { return Double(text) }
        return nil
    }
}
