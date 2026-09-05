//
//  LyricsManager.swift
//  QQPlayer
//
//  Manages lyrics fetching from embedded metadata and lrclib.net
//
//  核心：actor 主体、对外接口、决策链路、手动指定歌词。
//  拆分见 LyricsModels/LyricsParsing/LyricsSearch.swift。
//

import Foundation

actor LyricsManager {
    static let shared = LyricsManager()

    var cache: [String: Lyrics] = [:]
    /// 用户手动指定歌词（搜索页选择）：stableId → Lyrics；优先级高于自动链路
    private var manualOverrides: [String: Lyrics] = [:]
    /// 手动歌词磁盘是否已恢复（init 异步预载与首次 getLyrics 的竞态窗口防护）
    private var didLoadManualOverrides = false
    let baseURL = "https://lrclib.net/api"
    let fileManager = FileManager.default
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    /// 测试注入：手动歌词存储目录（nil = 默认 Documents/lyrics-manual）
    nonisolated(unsafe) static var manualLyricsDirectoryOverride: URL?
    /// 测试注入：歌词网络请求会话（默认共享会话；MockURLProtocol 通过它拦截 lrclib/网易云请求）
    nonisolated(unsafe) static var lyricsURLSession: URLSession = .shared
    /// 测试注入：逐曲歌词缓存目录（nil = 默认 Documents/lyrics-cache/tracks）
    nonisolated(unsafe) static var lyricsCacheDirectoryOverride: URL?

    // MARK: - 缓存上限/TTL 常量

    /// 启动预加载上限：只把最近 N 条缓存载入内存，其余磁盘缓存命中时懒加载
    static let startupCacheLoadLimit = 50
    /// 磁盘缓存文件数上限（LRU 淘汰：超出删除最久未使用的；正/负面缓存都算）
    static let diskCacheFileLimit = 200
    /// 负面缓存有效期：确认无歌词的曲目在此期限内跳过全链路（与搜索缓存 TTL 一致）
    static let negativeCacheTTL: TimeInterval = 7 * 24 * 3600
    /// 扫描式标签提取只转换文件头这段（Vorbis 注释/ID3v2 都在文件头部；
    /// 整文件转 String 会让大文件内存翻倍——mapped Data 是懒页，堆上 String 是全量副本）
    static let scanTextHeaderBytes = 2 * 1024 * 1024

    private init() {
        Task {
            await loadCacheFromDisk()
            await loadManualOverridesFromDisk()
            await markManualOverridesLoaded()
        }
    }

    /// 手动歌词磁盘已恢复标记（actor 方法：init 的 Task 是 nonisolated，不能直写属性）
    private func markManualOverridesLoaded() {
        didLoadManualOverrides = true
    }

    // MARK: - Public API

    func getLyrics(for track: Track) async -> Lyrics? {
        // 手动歌词磁盘恢复兜底：init 的异步预载可能晚于首次查询（播放恢复链路
        // 启动即调 getLyrics），不补载会落到自动缓存而非手动指定——2026-09-05
        // 七里香手动 lrclib 歌词不生效实锤（UI 显示网易云头部 credits）。幂等：
        // 只补载一次；与 init 预载并发时重复加载无害（值相同）。
        if !didLoadManualOverrides {
            await loadManualOverridesFromDisk()
            didLoadManualOverrides = true
        }
        // 用户手动指定歌词优先（搜索页选择，持久化；不自动更新，尊重用户选择）
        if let manual = manualOverrides[track.stableId] {
            print("📝 Using manually specified lyrics for: \(track.title)")
            return manual
        }

        // Check memory cache first
        if let cached = cache[track.stableId] {
            print("📝 Using cached lyrics for: \(track.title)")
            return cached
        }

        // Check disk cache
        if let diskCached = await loadLyricsFromDisk(trackId: track.stableId) {
            print("📝 Loaded lyrics from disk for: \(track.title)")
            cache[track.stableId] = diskCached
            return diskCached
        }

        // 负面缓存：7 天内确认无歌词 → 跳过内嵌/网易云/lrclib 全链路直接返回
        // （此前无歌词曲目每次播放都重走全链路，每次都有网络请求）
        if await isNegativeCached(trackId: track.stableId) {
            print("⏭️ Negative lyrics cache hit, skipping fetch: \(track.title)")
            return nil
        }

        // Try embedded lyrics first
        if let embedded = await getEmbeddedLyrics(for: track) {
            print("📝 Found embedded lyrics for: \(track.title)")
            cache[track.stableId] = embedded
            await saveLyricsToDisk(lyrics: embedded, trackId: track.stableId)
            return embedded
        }

        // Fallback to netease (original + Chinese translation)
        if let fetched = await fetchFromNetease(for: track) {
            // 头部 credits 型坏数据（如部分歌网易云只返回「作词/作曲/编曲」头）
            // 不缓存、继续 lrclib fallback——避免缓存成"歌词不动"的静态几行
            if isHeaderOnlyLyrics(fetched) {
                print("⚠️ Netease returned header-only lyrics, skipping: \(track.title)")
            } else {
                print("📝 Fetched lyrics from Netease for: \(track.title)")
                cache[track.stableId] = fetched
                await saveLyricsToDisk(lyrics: fetched, trackId: track.stableId)
                return fetched
            }
        }

        // Fallback to lrclib.net
        if let fetched = await fetchFromLRCLib(for: track) {
            if isHeaderOnlyLyrics(fetched) {
                // lrclib 已是最后在线源：坏数据不缓存不记负面，下次播放重试
                print("⚠️ lrclib.net returned header-only lyrics, treating as no lyrics: \(track.title)")
                return nil
            }
            print("📝 Fetched lyrics from lrclib.net for: \(track.title)")
            cache[track.stableId] = fetched
            await saveLyricsToDisk(lyrics: fetched, trackId: track.stableId)
            return fetched
        }

        // 全链路无歌词：记录负面缓存（7 天 TTL），避免每次播放重走网络
        await recordNegativeCache(trackId: track.stableId)
        print("⚠️ No lyrics found for: \(track.title)")
        return nil
    }

    func clearCache() {
        cache.removeAll()

        // Clear disk cache
        Task {
            await clearDiskCache()
        }

        print("🗑️ Lyrics cache cleared")
    }

    /// 头部 credits 型坏歌词：synced 行全部 ≤0 时间戳且正文缺失（如部分歌曲
    /// 网易云只返回「作词/作曲/编曲」头）→ UI 显示几行静态文本"歌词不动"。
    /// 在线源命中视为不可用（不缓存、继续 fallback）；纯文本/纯音乐不命中。
    private func isHeaderOnlyLyrics(_ lyrics: Lyrics) -> Bool {
        !lyrics.syncedLyrics.isEmpty
            && lyrics.syncedLyrics.allSatisfy { ($0.timestamp ?? 0) <= 0 }
    }

    // MARK: - 手动指定歌词（搜索页选择）

    /// 当前歌曲是否已手动指定歌词（搜索页显示"恢复自动"入口）
    func hasManualLyrics(for track: Track) -> Bool {
        manualOverrides[track.stableId] != nil
    }

    /// 应用搜索候选为当前歌曲歌词（手动指定 + 持久化；getLyrics 优先返回）
    @discardableResult
    func apply(candidate: LyricsSearchCandidate, for track: Track) -> Lyrics? {
        let lyrics: Lyrics
        switch candidate.source {
        case .netease:
            lyrics = makeLyrics(fromLRC: candidate.text, tlyric: candidate.tlyric)
        case .lrclib:
            lyrics = parseLyrics(candidate.text, source: .lrclib)
        }
        setManualLyrics(lyrics, for: track)
        return lyrics
    }

    /// 手动指定歌词（内存 + 磁盘持久化；同时写入内存缓存，getLyrics 直接命中）
    func setManualLyrics(_ lyrics: Lyrics, for track: Track) {
        manualOverrides[track.stableId] = lyrics
        cache[track.stableId] = lyrics
        Task {
            await saveManualLyricsToDisk(lyrics: lyrics, trackId: track.stableId)
            await clearNegativeCache(trackId: track.stableId) // 已有歌词：清除负面标记
        }
        print("📝 Manual lyrics saved for: \(track.title) (\(lyrics.source.rawValue))")
    }

    /// 清除手动指定歌词，恢复自动获取
    func clearManualLyrics(for track: Track) {
        manualOverrides[track.stableId] = nil
        cache[track.stableId] = nil
        Task {
            await removeManualLyricsFromDisk(trackId: track.stableId)
            await clearNegativeCache(trackId: track.stableId) // 恢复自动：重走全链路，不残留旧负面标记
        }
        print("📝 Manual lyrics cleared for: \(track.title)")
    }

    // MARK: - 手动歌词磁盘存储（Documents/lyrics-manual/{stableId}.json，与自动缓存目录分离）

    private func getManualLyricsDirectory() -> URL? {
        if let override = Self.manualLyricsDirectoryOverride {
            return override
        }
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = documentsURL.appendingPathComponent("lyrics-manual", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func getManualLyricsFileURL(trackId: String) -> URL? {
        guard let dir = getManualLyricsDirectory() else { return nil }
        return dir.appendingPathComponent("\(trackId).json")
    }

    private func saveManualLyricsToDisk(lyrics: Lyrics, trackId: String) async {
        guard let fileURL = getManualLyricsFileURL(trackId: trackId) else {
            print("❌ Failed to get manual lyrics file URL")
            return
        }
        do {
            let data = try encoder.encode(lyrics)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("❌ Failed to save manual lyrics to disk: \(error)")
        }
    }

    private func removeManualLyricsFromDisk(trackId: String) async {
        guard let fileURL = getManualLyricsFileURL(trackId: trackId) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    private func loadManualOverridesFromDisk() async {
        guard let dir = getManualLyricsDirectory() else { return }
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in files where fileURL.pathExtension == "json" {
            let trackId = fileURL.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: fileURL),
                  let lyrics = try? decoder.decode(Lyrics.self, from: data) else {
                continue
            }
            manualOverrides[trackId] = lyrics
            cache[trackId] = lyrics
        }
    }

    // MARK: - Embedded Lyrics

    private func getEmbeddedLyrics(for track: Track) async -> Lyrics? {
        let url = URL(fileURLWithPath: track.path)
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            if let lyricsText = await extractFlacLyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "mp3":
            if let lyricsText = await extractID3Lyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "dsf":
            if let lyricsText = await extractDSFLyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "ogg", "opus":
            if let lyricsText = await extractScannedVorbisLyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        case "dff":
            if let lyricsText = await extractScannedID3Lyrics(from: url) {
                return parseLyrics(lyricsText, source: .embedded)
            }
        default:
            break
        }

        if let lyricsText = await extractAVFoundationLyrics(from: url) {
            return parseLyrics(lyricsText, source: .embedded)
        }

        return nil
    }

    // MARK: - Helper Methods

    func getArtistName(for track: Track) throws -> String? {
        guard let artistId = track.artistId else { return nil }
        return try DatabaseManager.shared.read { db in
            try Artist.fetchOne(db, key: artistId)?.name
        }
    }

    func getAlbumName(for track: Track) throws -> String? {
        guard let albumId = track.albumId else { return nil }
        return try DatabaseManager.shared.read { db in
            try Album.fetchOne(db, key: albumId)?.title
        }
    }
}
