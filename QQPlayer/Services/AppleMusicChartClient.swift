//
//  AppleMusicChartClient.swift
//  QQPlayer
//
//  推荐热度（chart popularity）：Apple Music「most-played 100」日榜（tw + us 双店区）。
//
//  背景（2026-11-13）：推荐此前只用 iTunes 搜索相关性序，没有任何「歌曲本身受不受欢迎」的信号。
//  本文件提供只读的榜单输入：抓取 → 解析 → 合并 → 缓存；任何失败都静默降级为空榜单，
//  **不抛错、不阻塞推荐**（热度只是打分的一个分量，缺了按中性 0.5 处理）。
//
//  端点（实测 200；rss.applemarketingtools.com 会 301 到下面这个最终域名，直接用最终域名）：
//    https://rss.marketingtools.apple.com/api/v2/{tw,us}/music/most-played/100/songs.json
//
//  ⚠️ 共享层：只依赖 Foundation，iOS / macOS 都能编。
//

import Foundation

// MARK: - 模型

/// 榜单条目（解析后的最小字段）。
struct ChartEntry: Codable, Equatable, Sendable {
    /// Apple 歌曲 id（与 iTunes search 的 `trackId` 同源，可精确匹配）。
    var id: String
    var title: String
    var artist: String
    /// 合并后的名次（从 1 开始连续编号）。
    var rank: Int
}

/// 榜单抓取错误（内部用；对外一律吞掉，只落诊断日志）。
enum AppleMusicChartError: Error, Equatable {
    case badStatusCode(Int)
    case invalidPayload
}

// MARK: - 传输契约（可注入；测试用假实现，不打真实网络）

protocol AppleMusicChartTransporting: Sendable {
    func data(from url: URL) async throws -> Data
}

/// 默认传输：一次性 ephemeral session（与 `ITunesScrapeClient` 同风格，不共享 cookie / 缓存）。
struct URLSessionAppleMusicChartTransport: AppleMusicChartTransporting {
    var timeout: TimeInterval = 8

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(MusicBrainzClient.userAgent, forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AppleMusicChartError.badStatusCode(http.statusCode)
        }
        return data
    }
}

// MARK: - 解析 / 合并（纯函数）

enum AppleMusicChartParser {
    /// 解析一店榜单：`feed.results[]` → 连续名次（缺失 id / name / artistName 的条目跳过，不整体失败）。
    ///
    /// 结构：`{ "feed": { "results": [ { id, name, artistName, ... } ] } }`；也兼容根级 `results`。
    static func entries(from data: Data) -> [ChartEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let feed = object["feed"] as? [String: Any]
        let results = (feed?["results"] as? [[String: Any]]) ?? (object["results"] as? [[String: Any]]) ?? []
        var entries: [ChartEntry] = []
        for item in results {
            guard let id = identifier(item["id"]),
                  let title = nonEmptyString(item["name"]),
                  let artist = nonEmptyString(item["artistName"]) else { continue }
            entries.append(ChartEntry(id: id, title: title, artist: artist, rank: entries.count + 1))
        }
        return entries
    }

    /// 双店区合并：tw 优先，us 中 tw 未出现的按 us 序追加；按 id 去重；重新从 1 连续编号。
    static func merged(tw: [ChartEntry], us: [ChartEntry]) -> [ChartEntry] {
        var seen: Set<String> = []
        var merged: [ChartEntry] = []
        for entry in tw + us where seen.insert(entry.id).inserted {
            merged.append(ChartEntry(id: entry.id, title: entry.title, artist: entry.artist, rank: merged.count + 1))
        }
        return merged
    }

    private static func identifier(_ raw: Any?) -> String? {
        if let text = raw as? String { return text.isEmpty ? nil : text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - 落盘缓存（TTL 6 小时）

/// 落盘缓存（值语义：只持有目录 URL，跨 actor 传递安全）。
struct AppleMusicChartCache: Sendable {
    /// 榜单 TTL：Apple 日榜一天一更，6 小时足够新鲜，也避免每次推荐都打网络。
    static let ttl: TimeInterval = 6 * 3600
    static let directoryComponent = "Cache/ChartPopularity"
    static let fileName = "chart-popularity.json"
    /// 缓存结构版本：模型变化即整体失效。
    static let schemaVersion = 1

    struct Snapshot: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var savedAt: Date
        var twCount: Int
        var usCount: Int
        var entries: [ChartEntry]
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// 默认缓存目录：macOS 走 App 数据根（与推荐结果缓存同惯例），iOS 走系统 Caches。
    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL? {
        #if os(macOS)
            guard let root = LibraryRoot.macAppSupportRootURL(fileManager: fileManager) else { return nil }
            return root.appendingPathComponent(directoryComponent, isDirectory: true)
        #else
            guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
            return caches.appendingPathComponent(directoryComponent, isDirectory: true)
        #endif
    }

    /// 默认缓存（目录解析失败 → nil，退化为纯内存 memo）。
    static func defaultCache(fileManager: FileManager = .default) -> AppleMusicChartCache? {
        guard let directory = defaultDirectoryURL(fileManager: fileManager) else { return nil }
        return AppleMusicChartCache(directory: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// 读缓存：解码失败 / 版本不符 → nil（静默按无缓存处理，不删不改）。
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == Self.schemaVersion else { return nil }
        return snapshot
    }

    /// 写缓存：失败静默（缓存写不进不影响推荐）。
    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 客户端（run 级缓存：一次推荐只取一次）

actor AppleMusicChartClient {
    /// 抓取顺序：tw 优先（中文原唱覆盖好），us 补位。
    static let storefronts = ["tw", "us"]

    static func url(storefront: String) -> URL? {
        URL(string: "https://rss.marketingtools.apple.com/api/v2/\(storefront)/music/most-played/100/songs.json")
    }

    private let transport: any AppleMusicChartTransporting
    private let cache: AppleMusicChartCache?
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    /// 进程内 memo：TTL 内跨意图 / 跨批次复用，避免每次推荐都读盘或打网络。
    private var memo: (savedAt: Date, index: ChartPopularityIndex)?

    init(
        transport: any AppleMusicChartTransporting = URLSessionAppleMusicChartTransport(),
        cache: AppleMusicChartCache? = AppleMusicChartCache.defaultCache(),
        ttl: TimeInterval = AppleMusicChartCache.ttl,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.cache = cache
        self.ttl = ttl
        self.clock = clock
    }

    /// 当前榜单索引（**永不抛错**）：内存 → 缓存（TTL 内）→ 网络 → 过期缓存 → 空榜单。
    func index() async -> ChartPopularityIndex {
        let now = clock()
        if let memo, now.timeIntervalSince(memo.savedAt) < ttl {
            return memo.index
        }

        var stale: ChartPopularityIndex?
        if let snapshot = cache?.load() {
            let index = ChartPopularityIndex(
                entries: snapshot.entries,
                twCount: snapshot.twCount,
                usCount: snapshot.usCount
            )
            if now.timeIntervalSince(snapshot.savedAt) < ttl {
                memo = (savedAt: snapshot.savedAt, index: index)
                return index
            }
            stale = index
        }

        if let fetched = await fetch() {
            cache?.save(
                AppleMusicChartCache.Snapshot(
                    schemaVersion: AppleMusicChartCache.schemaVersion,
                    savedAt: now,
                    twCount: fetched.twCount,
                    usCount: fetched.usCount,
                    entries: fetched.entries
                )
            )
            let index = ChartPopularityIndex(
                entries: fetched.entries,
                twCount: fetched.twCount,
                usCount: fetched.usCount
            )
            memo = (savedAt: now, index: index)
            return index
        }

        // 网络全失败：优先回落到过期缓存（旧榜单也比没有强）。
        if let stale {
            AppLog.warn(.general, "⚠️ 榜单刷新失败，回落到过期缓存（\(stale.count) 条）")
            return stale
        }
        AppLog.warn(.general, "⚠️ 榜单获取失败且无缓存，热度按中性 0.5 处理")
        return .empty
    }

    private struct Fetched {
        var entries: [ChartEntry]
        var twCount: Int
        var usCount: Int
    }

    /// 两店并发抓取；任一店失败只丢该店。两店都失败返回 nil。
    private func fetch() async -> Fetched? {
        async let twEntries = fetchEntries(storefront: "tw")
        async let usEntries = fetchEntries(storefront: "us")
        let (tw, us) = await (twEntries, usEntries)
        guard !tw.isEmpty || !us.isEmpty else { return nil }
        return Fetched(entries: AppleMusicChartParser.merged(tw: tw, us: us), twCount: tw.count, usCount: us.count)
    }

    private func fetchEntries(storefront: String) async -> [ChartEntry] {
        guard let url = Self.url(storefront: storefront) else { return [] }
        do {
            let data = try await transport.data(from: url)
            return AppleMusicChartParser.entries(from: data)
        } catch {
            AppLog.warn(.general, "⚠️ 榜单抓取失败（\(storefront)）：\(error.localizedDescription)")
            return []
        }
    }
}
