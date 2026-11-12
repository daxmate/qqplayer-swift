//
//  RecommendationSourceChain.swift
//  QQPlayer
//
//  推荐 P2：iTunes 主源 + 降级链（源码级实现，不复制 HTTP）。
//
//  链路：iTunes(tw) → iTunes(us) → MusicBrainz(在线) → 网易云(search)
//  - 硬失败（非 2xx / 429 / 超时 / 解析失败）立即降级
//  - 软失败（候选池不足阈值 / artistId 查不到）也降级
//  - 单次推荐请求最多降 2 级（跨意图共享 `RecommendationRunBudget`）
//  - 每次降级写结构化日志；结果带实际来源与降级原因（禁止静默）
//

import Foundation

// MARK: - 单次推荐预算

/// 一次推荐请求的共享预算：降级次数 + iTunes 调用次数（跨意图共享，开始新推荐时 reset）。
actor RecommendationRunBudget {
    static let shared = RecommendationRunBudget()

    private var maxDowngrades: Int
    private var remainingDowngrades: Int
    private var maxITunesCalls: Int
    private var remainingITunesCalls: Int

    init(maxDowngrades: Int = 2, maxITunesCalls: Int = 6) {
        self.maxDowngrades = maxDowngrades
        self.remainingDowngrades = maxDowngrades
        self.maxITunesCalls = maxITunesCalls
        self.remainingITunesCalls = maxITunesCalls
    }

    func beginRun(maxDowngrades: Int? = nil, maxITunesCalls: Int? = nil) {
        if let maxDowngrades { self.maxDowngrades = max(0, maxDowngrades) }
        if let maxITunesCalls { self.maxITunesCalls = max(0, maxITunesCalls) }
        remainingDowngrades = self.maxDowngrades
        remainingITunesCalls = self.maxITunesCalls
    }

    /// 消耗一级降级；返回 false 表示本轮预算已用尽（不再向下）。
    func consumeDowngrade() -> Bool {
        guard remainingDowngrades > 0 else { return false }
        remainingDowngrades -= 1
        return true
    }

    /// 消耗一次 iTunes 调用；false = 超出单轮调用预算（按硬失败处理）。
    func consumeITunesCall() -> Bool {
        guard remainingITunesCalls > 0 else { return false }
        remainingITunesCalls -= 1
        return true
    }

    var downgradesRemaining: Int { remainingDowngrades }
    var iTunesCallsRemaining: Int { remainingITunesCalls }
}

// MARK: - iTunes 限流 / 缓存

/// iTunes 串行 + ≥3s 间隔 + 24h 缓存（key 含 term / country / artistId）。
actor ITunesRecommendationGate {
    static let shared = ITunesRecommendationGate()

    enum Lookup<Value: Sendable>: Sendable {
        case hit(Value)
        case miss
        case unknown
    }

    private struct CacheEntry<Value> {
        var storedAt: Date
        var value: Value
    }

    private let minInterval: TimeInterval
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var lastRequestAt: Date?
    private var artistIDs: [String: CacheEntry<Int>] = [:]
    private var artistMisses: [String: Date] = [:]
    private var songLists: [String: CacheEntry<[RecommendationRemoteSong]>] = [:]

    init(
        minInterval: TimeInterval = 3,
        cacheTTL: TimeInterval = 24 * 3600,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.minInterval = minInterval
        self.cacheTTL = cacheTTL
        self.now = now
        self.sleep = sleep
    }

    /// 串行节流：离上次请求不足 minInterval 就补足等待（时钟可注入，测试不真等）。
    func awaitTurn() async {
        let current = now()
        if let lastRequestAt {
            let elapsed = current.timeIntervalSince(lastRequestAt)
            if elapsed < minInterval {
                await sleep(minInterval - elapsed)
            }
        }
        lastRequestAt = now()
    }

    func artistID(term: String, storefront: String) -> Lookup<Int> {
        let key = Self.artistKey(term: term, storefront: storefront)
        if let entry = artistIDs[key], now().timeIntervalSince(entry.storedAt) < cacheTTL {
            return .hit(entry.value)
        }
        if let missedAt = artistMisses[key], now().timeIntervalSince(missedAt) < cacheTTL {
            return .miss
        }
        return .unknown
    }

    func storeArtistID(_ id: Int, term: String, storefront: String) {
        artistIDs[Self.artistKey(term: term, storefront: storefront)] = CacheEntry(storedAt: now(), value: id)
    }

    func storeArtistMiss(term: String, storefront: String) {
        artistMisses[Self.artistKey(term: term, storefront: storefront)] = now()
    }

    func songs(artistID: Int, storefront: String) -> Lookup<[RecommendationRemoteSong]> {
        let key = Self.songsKey(artistID: artistID, storefront: storefront)
        guard let entry = songLists[key], now().timeIntervalSince(entry.storedAt) < cacheTTL else {
            return .unknown
        }
        return .hit(entry.value)
    }

    func storeSongs(_ songs: [RecommendationRemoteSong], artistID: Int, storefront: String) {
        songLists[Self.songsKey(artistID: artistID, storefront: storefront)] = CacheEntry(
            storedAt: now(),
            value: songs
        )
    }

    private static func artistKey(term: String, storefront: String) -> String {
        "artist|\(storefront)|\(term.lowercased())"
    }

    private static func songsKey(artistID: Int, storefront: String) -> String {
        "songs|\(storefront)|\(artistID)"
    }
}

// MARK: - iTunes 推荐源

enum ITunesRecommendationError: Error, Equatable {
    case artistNotFound
    case budgetExhausted
    case emptyQuery
}

/// iTunes 主源：艺人名 → artistId → 该艺人歌曲池（复用 `ITunesScrapeClient` 的 HTTP 与店区）。
struct ITunesRecommendationProvider: OnlineSearchProviding, ArtistSearchProviding {
    var storefront: String
    var client: ITunesScrapeClient = ITunesScrapeClient()
    var gate: ITunesRecommendationGate = .shared
    var budget: RecommendationRunBudget = .shared

    var source: RecommendationSource { .itunes }

    /// 关键词 / 情绪 / 年代意图：iTunes song search 结果直接映射（不解析 artistId、不做艺人碟）。
    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw ITunesRecommendationError.emptyQuery }
        guard await budget.consumeITunesCall() else {
            throw ITunesRecommendationError.budgetExhausted
        }
        await gate.awaitTurn()
        let results = try await client.rawSearch(
            term: term,
            entity: "song",
            storefront: storefront,
            limit: ITunesScrapeClient.recommendationLimit
        )
        return results.compactMap(Self.song(from:))
    }

    /// 艺人意图：search 取 artistId → lookup 该艺人歌曲（跨店区由降级链负责）。
    func searchArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw ITunesRecommendationError.emptyQuery }
        let fetchLimit = max(limit, 20)

        switch await gate.artistID(term: term, storefront: storefront) {
        case let .hit(id):
            return try await songs(artistID: id, limit: fetchLimit)
        case .miss:
            throw ITunesRecommendationError.artistNotFound
        case .unknown:
            break
        }

        guard await budget.consumeITunesCall() else {
            throw ITunesRecommendationError.budgetExhausted
        }
        await gate.awaitTurn()
        let results = try await client.rawSearch(
            term: term,
            entity: "song",
            storefront: storefront,
            limit: ITunesScrapeClient.recommendationLimit
        )
        guard let artistID = Self.firstArtistID(in: results) else {
            await gate.storeArtistMiss(term: term, storefront: storefront)
            throw ITunesRecommendationError.artistNotFound
        }
        await gate.storeArtistID(artistID, term: term, storefront: storefront)
        return try await songs(artistID: artistID, limit: fetchLimit)
    }

    private func songs(artistID: Int, limit: Int) async throws -> [RecommendationRemoteSong] {
        switch await gate.songs(artistID: artistID, storefront: storefront) {
        case let .hit(songs):
            return Array(songs.prefix(limit))
        case .miss, .unknown:
            break
        }
        guard await budget.consumeITunesCall() else {
            throw ITunesRecommendationError.budgetExhausted
        }
        await gate.awaitTurn()
        let results = try await client.rawLookup(
            id: artistID,
            entity: "song",
            storefront: storefront,
            limit: ITunesScrapeClient.recommendationLimit
        )
        let mapped = results.compactMap(Self.song(from:))
        await gate.storeSongs(mapped, artistID: artistID, storefront: storefront)
        return Array(mapped.prefix(limit))
    }

    /// search 结果里取首个非空 artistId（iTunes 的 artistId 是稳定数字）。
    static func firstArtistID(in results: [[String: Any]]) -> Int? {
        for dict in results {
            if let number = dict["artistId"] as? NSNumber, number.intValue > 0 {
                return number.intValue
            }
            if let value = dict["artistId"] as? Int, value > 0 {
                return value
            }
            if let text = dict["artistId"] as? String, let value = Int(text), value > 0 {
                return value
            }
        }
        return nil
    }

    /// iTunes JSON → 归一候选（字段缺就 nil，不编造）。
    static func song(from dict: [String: Any]) -> RecommendationRemoteSong? {
        guard let title = dict["trackName"] as? String, !title.isEmpty,
              let artist = dict["artistName"] as? String, !artist.isEmpty else {
            return nil
        }
        let year = (dict["releaseDate"] as? String).flatMap { text in
            Int(text.prefix(4))
        }
        let duration: Int?
        if let number = dict["trackTimeMillis"] as? NSNumber {
            duration = number.intValue
        } else if let value = dict["trackTimeMillis"] as? Int {
            duration = value
        } else {
            duration = nil
        }
        let preview = (dict["previewUrl"] as? String).flatMap { URL(string: $0) }
        let trackID: Int?
        if let number = dict["trackId"] as? NSNumber {
            trackID = number.intValue
        } else {
            trackID = dict["trackId"] as? Int
        }
        return RecommendationRemoteSong(
            title: title,
            artist: artist,
            album: dict["collectionName"] as? String,
            year: year,
            songID: trackID,
            durationMs: duration,
            previewURL: preview,
            source: .itunes
        )
    }
}

// MARK: - MusicBrainz 在线源

/// MusicBrainz 在线候选（1 req/s + UA 由 `MusicBrainzClient` 负责；不建本地库）。
struct MusicBrainzSearchProvider: OnlineSearchProviding {
    var client: MusicBrainzClient = MusicBrainzClient()

    var source: RecommendationSource { .musicbrainz }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let candidates = try await client.searchRecordings(byArtist: query, limit: max(limit, 50))
        return candidates.compactMap { candidate in
            guard let title = candidate.title, !title.isEmpty,
                  let artist = candidate.artist, !artist.isEmpty else {
                return nil
            }
            return RecommendationRemoteSong(
                title: title,
                artist: artist,
                album: candidate.album,
                year: candidate.year,
                durationMs: candidate.durationMs,
                source: .musicbrainz
            )
        }
    }
}

// MARK: - 降级链

/// 链路里一级来源。
struct RecommendationChainStep: Sendable {
    enum Kind: String, Sendable {
        case itunesTW = "itunes-tw"
        case itunesUS = "itunes-us"
        case musicbrainz
        case netease
    }

    var kind: Kind
    var provider: any OnlineSearchProviding
    /// 产出少于该条数视为软失败（继续降级）；0 = 只按硬失败判断。
    var minimumCandidates: Int
    /// 到达这一级时给结果打的降级原因（nil = 原级来源）。
    var degradedReason: String?
}

/// 降级链诊断（一次推荐共享；summary 日志读取）。
final class RecommendationChainAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [String] = []
    private var downgrades: [String] = []
    private var blocked = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        attempts = []
        downgrades = []
        blocked = 0
    }

    func recordAttempt(_ step: RecommendationChainStep.Kind, songs: Int, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        attempts.append("\(step.rawValue):\(failed ? "fail" : "ok"):\(songs)")
    }

    func recordDowngrade(from: RecommendationChainStep.Kind, to: RecommendationChainStep.Kind, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        downgrades.append("\(from.rawValue)>\(to.rawValue):\(reason)")
    }

    func recordBlocked() {
        lock.lock()
        defer { lock.unlock() }
        blocked += 1
    }

    /// 日志字段：attempts / downgrades / blocked（固定顺序、可 grep）。
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let attemptText = attempts.joined(separator: ",")
        let downgradeText = downgrades.joined(separator: ",")
        return "attempts=\(attemptText.isEmpty ? "-" : attemptText);"
            + "downgrades=\(downgradeText.isEmpty ? "-" : downgradeText);"
            + "blocked=\(blocked)"
    }
}

/// 降级链 provider：引擎每意图调用一次，内部按级尝试；结果带真实来源。
struct RecommendationDegradingProvider: OnlineSearchProviding, ArtistSearchProviding {
    var steps: [RecommendationChainStep]
    var budget: RecommendationRunBudget = .shared
    var audit: RecommendationChainAudit?

    var source: RecommendationSource { steps.first?.provider.source ?? .itunes }

    /// 关键词意图：逐级走普通 search（iTunes 级为 song search）。
    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        try await perform(query: query, limit: limit, artistMode: false)
    }

    /// 艺人意图：逐级优先 artist 路径（iTunes 级 search→artistId→lookup）。
    func searchArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        try await perform(query: name, limit: limit, artistMode: true)
    }

    private func perform(query: String, limit: Int, artistMode: Bool) async throws -> [RecommendationRemoteSong] {
        var lastError: Error?
        for (index, step) in steps.enumerated() {
            if index > 0 {
                let previous = steps[index - 1]
                let reason = Self.reason(for: lastError)
                guard await budget.consumeDowngrade() else {
                    audit?.recordBlocked()
                    AppLog.info(.general, "🎵 推荐降级：预算用尽，停在 \(previous.kind.rawValue)（原因 \(reason)）")
                    break
                }
                audit?.recordDowngrade(from: previous.kind, to: step.kind, reason: reason)
                AppLog.info(.general, "🎵 推荐降级：\(previous.kind.rawValue) → \(step.kind.rawValue)（原因 \(reason)）")
            }

            do {
                let songs = try await fetchSongs(from: step, query: query, limit: limit, artistMode: artistMode)
                let passes = songs.count >= step.minimumCandidates
                    && (step.minimumCandidates > 0 || !songs.isEmpty)
                audit?.recordAttempt(step.kind, songs: songs.count, failed: !passes)
                if passes {
                    return songs.map { song in
                        var song = song
                        song.source = song.source ?? step.provider.source
                        if let degradedReason = step.degradedReason {
                            song.degradedReason = degradedReason
                        }
                        return song
                    }
                }
                lastError = RecommendationDegradationError.softFailure(
                    step: step.kind.rawValue,
                    count: songs.count,
                    minimum: step.minimumCandidates
                )
            } catch {
                audit?.recordAttempt(step.kind, songs: 0, failed: true)
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private func fetchSongs(
        from step: RecommendationChainStep,
        query: String,
        limit: Int,
        artistMode: Bool
    ) async throws -> [RecommendationRemoteSong] {
        if artistMode, let artistProvider = step.provider as? any ArtistSearchProviding {
            return try await artistProvider.searchArtist(query, limit: limit)
        }
        return try await step.provider.search(query: query, limit: limit)
    }

    private static func reason(for error: Error?) -> String {
        guard let error else { return "unknown" }
        if let soft = error as? RecommendationDegradationError {
            return soft.logReason
        }
        if let error = error as? ITunesHTTPError {
            switch error {
            case .rateLimited: return "http_429"
            case let .httpStatus(code): return "http_\(code)"
            case .invalidPayload: return "bad_payload"
            }
        }
        if let error = error as? ITunesRecommendationError {
            switch error {
            case .artistNotFound: return "artist_not_found"
            case .budgetExhausted: return "budget_exhausted"
            case .emptyQuery: return "empty_query"
            }
        }
        if error is URLError { return "network" }
        return "error"
    }
}

// MARK: - 默认链路工厂

enum RecommendationSourceChain {
    /// 源版本：进缓存键（链路 / 阈值变化 → 缓存失效）。
    static let sourceVersion = "p2-itunes-chain-1"

    /// 生产默认链：iTunes(tw) → iTunes(us) → MusicBrainz → 网易云(search)。
    ///
    /// 阈值：链是**每意图调用一次**，因此只做「非空即通过」（tw/us/MB = 1）；
    /// 池级 ≥60 / 每批相关性留给整轮 gather 与日志判断。网易云最后兜底（0 门槛，结果标降级）。
    static func defaultProvider(
        budget: RecommendationRunBudget,
        audit: RecommendationChainAudit
    ) -> any OnlineSearchProviding {
        RecommendationDegradingProvider(
            steps: [
                RecommendationChainStep(
                    kind: .itunesTW,
                    provider: ITunesRecommendationProvider(storefront: "tw", budget: budget),
                    minimumCandidates: 1,
                    degradedReason: nil
                ),
                RecommendationChainStep(
                    kind: .itunesUS,
                    provider: ITunesRecommendationProvider(storefront: "us", budget: budget),
                    minimumCandidates: 1,
                    degradedReason: "itunes_us_fallback"
                ),
                RecommendationChainStep(
                    kind: .musicbrainz,
                    provider: MusicBrainzSearchProvider(),
                    minimumCandidates: 1,
                    degradedReason: "musicbrainz_fallback"
                ),
                RecommendationChainStep(
                    kind: .netease,
                    provider: NeteaseSearchProvider(),
                    minimumCandidates: 0,
                    degradedReason: "netease_fallback"
                ),
            ],
            budget: budget,
            audit: audit
        )
    }
}

enum RecommendationDegradationError: Error, Equatable {
    case softFailure(step: String, count: Int, minimum: Int)

    var logReason: String {
        switch self {
        case let .softFailure(_, count, minimum):
            return "soft_failure(\(count)<\(minimum))"
        }
    }
}
