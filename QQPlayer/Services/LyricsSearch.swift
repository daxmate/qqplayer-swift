//
//  LyricsSearch.swift
//  QQPlayer
//
//  歌词网络获取编排（网易云/lrclib）与磁盘缓存（正缓存 + 负面缓存 + LRU 上限）。
//

import Foundation

extension LyricsManager {
    // MARK: - Netease API

    func fetchFromNetease(for track: Track) async -> Lyrics? {
        guard let artistName = try? getArtistName(for: track),
              !track.title.isEmpty else {
            print("⚠️ Missing metadata for Netease lookup")
            return nil
        }

        let provider = NeteaseLyricsProvider.shared

        do {
            // 搜索候选，选最匹配的歌曲（桌面版逻辑：标题精确匹配 + 歌手包含；否则取第一个候选）
            let query = "\(track.title) \(artistName)".trimmingCharacters(in: .whitespaces)
            let candidates = try await provider.search(query: query, limit: 8)
            guard !candidates.isEmpty else { return nil }

            let best = NeteaseLyricsProvider.selectBestCandidate(
                candidates,
                title: track.title,
                artistName: artistName
            )
            guard let best else { return nil }

            guard let result = try await provider.getLyric(songID: best.id) else {
                print("⚠️ Netease returned no lyrics for: \(track.title)")
                return nil
            }

            return makeLyrics(fromLRC: result.lrc, tlyric: result.tlyric)
        } catch {
            print("❌ Failed to fetch from Netease: \(error)")
            return nil
        }
    }

    /// LRC 文本 + 可选翻译 → Lyrics；翻译按时间戳（容差 0.6s）合并进对应行
    func makeLyrics(fromLRC lrcText: String, tlyric: String?) -> Lyrics {
        let base = parseLyrics(lrcText, source: .netease)
        guard var synced = base.syncedLyrics.isEmpty ? nil : base.syncedLyrics,
              let tlyric, !tlyric.isEmpty else {
            return base
        }

        let translationLines = parseSyncedLyrics(tlyric)
        guard !translationLines.isEmpty else { return base }

        for i in synced.indices {
            guard let ts = synced[i].timestamp else { continue }
            // 找时间戳最接近的翻译行（容差 0.6s，与桌面版 merge_translation 一致）
            let match = translationLines.first { tLine in
                guard let t = tLine.timestamp else { return false }
                return abs(t - ts) <= 0.6
            }
            if let match {
                synced[i].translation = match.text
            }
        }

        return Lyrics(
            plainLyrics: base.plainLyrics,
            syncedLyrics: synced,
            isInstrumental: base.isInstrumental,
            source: .netease
        )
    }

    // MARK: - LRCLIB API

    func fetchFromLRCLib(for track: Track) async -> Lyrics? {
        guard let artistName = try? getArtistName(for: track),
              let albumName = try? getAlbumName(for: track),
              !artistName.isEmpty else {
            print("⚠️ Missing metadata for lrclib.net lookup")
            return nil
        }

        let durationSeconds = Double((track.durationMs ?? 0)) / 1000.0

        // Try direct get first
        if let lyrics = await fetchDirectFromLRCLib(
            trackName: track.title,
            artistName: artistName,
            albumName: albumName,
            duration: durationSeconds
        ) {
            // If we got synced lyrics, return immediately
            if !lyrics.syncedLyrics.isEmpty {
                print("✅ Got synced lyrics from /api/get")
                return lyrics
            }

            // We got plain lyrics, but let's try to find synced via search
            print("⚠️ Got plain lyrics, searching for synced version...")
        }

        // Try search to find synced lyrics
        if let syncedLyrics = await searchForSyncedLyrics(
            trackName: track.title,
            artistName: artistName,
            duration: durationSeconds
        ) {
            print("✅ Found synced lyrics via /api/search")
            return syncedLyrics
        }

        // Return whatever we got from direct fetch (could be plain lyrics or nil)
        return await fetchDirectFromLRCLib(
            trackName: track.title,
            artistName: artistName,
            albumName: albumName,
            duration: durationSeconds
        )
    }

    func fetchDirectFromLRCLib(
        trackName: String,
        artistName: String,
        albumName: String,
        duration: Double
    ) async -> Lyrics? {
        var components = URLComponents(string: "\(baseURL)/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName),
            URLQueryItem(name: "album_name", value: albumName),
            URLQueryItem(name: "duration", value: String(format: "%.0f", duration)),
        ]

        guard let url = components?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("QQPlayer/1.0 (https://github.com/daxmate/qqplayer-ios)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await Self.lyricsURLSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            if httpResponse.statusCode == 404 {
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                return nil
            }

            let lrcResponse = try decoder.decode(LRCLibResponse.self, from: data)
            return parseLRCLibResponse(lrcResponse)

        } catch {
            print("❌ Failed to fetch from lrclib.net: \(error)")
            return nil
        }
    }

    func searchForSyncedLyrics(
        trackName: String,
        artistName: String,
        duration: Double
    ) async -> Lyrics? {
        var results = await fetchLRCLibSearchResults(
            trackName: trackName, artistName: artistName
        )

        // lrclib 收录的中文歌 artist 多为拉丁拼写（「孙燕姿」→ Stefanie Sun），
        // 带中文 artist 搜索必然 0 条——兑底只按歌名重搜，靠 duration 过滤保证相关度
        if results.isEmpty {
            print("⚠️ lrclib search with artist returned 0, retrying by track name only")
            results = await fetchLRCLibSearchResults(trackName: trackName, artistName: nil)
        }

        guard !results.isEmpty else { return nil }

        // Filter and prioritize:
        // 1. Must have synced lyrics
        // 2. Prefer duration match (within ±2 seconds)
        // 3. Pick the first matching result

        let syncedResults = results.filter {
            $0.syncedLyrics != nil && !($0.syncedLyrics?.isEmpty ?? true)
        }

        // Try exact duration match first (±2 seconds)
        if let exactMatch = syncedResults.first(where: {
            abs($0.duration - duration) <= 2
        }) {
            print("📝 Found exact duration match with synced lyrics")
            return parseLRCLibResponse(exactMatch)
        }

        // Otherwise take first synced result
        if let firstSynced = syncedResults.first {
            print("📝 Using first synced lyrics result (duration mismatch)")
            return parseLRCLibResponse(firstSynced)
        }

        return nil
    }

    /// lrclib /api/search 请求 + 解析；artistName 为 nil 时只按歌名搜
    /// （中文歌 artist 是拉丁拼写匹配不上，兑底路径用）
    private func fetchLRCLibSearchResults(
        trackName: String,
        artistName: String?
    ) async -> [LRCLibResponse] {
        var components = URLComponents(string: "\(baseURL)/search")
        var queryItems = [URLQueryItem(name: "track_name", value: trackName)]
        if let artistName, !artistName.isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: artistName))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("QQPlayer/1.0 (https://github.com/daxmate/qqplayer-ios)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await Self.lyricsURLSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            return (try? decoder.decode([LRCLibResponse].self, from: data)) ?? []

        } catch {
            print("❌ Failed to search lrclib.net: \(error)")
            return []
        }
    }

    private func parseLRCLibResponse(_ response: LRCLibResponse) -> Lyrics {
        if response.instrumental {
            return Lyrics(plainLyrics: "", syncedLyrics: [], isInstrumental: true, source: .lrclib)
        }

        let plainLyrics = response.plainLyrics ?? ""
        var syncedLines: [LyricsLine] = []

        if let syncedText = response.syncedLyrics {
            syncedLines = parseSyncedLyrics(syncedText)
        }

        return Lyrics(plainLyrics: plainLyrics, syncedLyrics: syncedLines, isInstrumental: false, source: .lrclib)
    }

    // MARK: - Disk Cache

    private func getLyricsCacheDirectory() -> URL? {
        if let override = Self.lyricsCacheDirectoryOverride {
            return override
        }
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheDir = documentsURL.appendingPathComponent("lyrics-cache/tracks", isDirectory: true)

        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        return cacheDir
    }

    private func getLyricsFileURL(trackId: String) -> URL? {
        guard let cacheDir = getLyricsCacheDirectory() else { return nil }
        return cacheDir.appendingPathComponent("\(trackId).json")
    }

    func saveLyricsToDisk(lyrics: Lyrics, trackId: String) async {
        guard let fileURL = getLyricsFileURL(trackId: trackId) else { return }

        do {
            let data = try encoder.encode(lyrics)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("❌ Failed to save lyrics to disk: \(error)")
        }
        await enforceDiskCacheLimit()
    }

    func loadLyricsFromDisk(trackId: String) async -> Lyrics? {
        guard let fileURL = getLyricsFileURL(trackId: trackId),
              fileManager.fileExists(atPath: fileURL.path) else {
            return nil // 未命中磁盘缓存是正常路径，不打日志（此前每首歌都打一条 ⚠️）
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let lyrics = try decoder.decode(Lyrics.self, from: data)
            // 命中即刷新 mtime：真 LRU——最近读过的缓存不被启动预载/写盘淘汰误删
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return lyrics
        } catch {
            // 损坏即删（单行日志，不逐文件刷屏）
            print("⚠️ Corrupted lyrics cache, removing: \(fileURL.lastPathComponent)")
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    func loadCacheFromDisk() async {
        guard let cacheDir = getLyricsCacheDirectory() else { return }

        do {
            let files = try fileManager.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let jsonFiles = files.filter { $0.pathExtension == "json" }
            // 只预载最近 N 条（按 mtime 倒序），其余磁盘缓存命中时懒加载——
            // 播放越多内存不再无限增长（此前把全部 .json 解码进内存）
            let dated = jsonFiles.compactMap { url -> (url: URL, mtime: Date)? in
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    return nil
                }
                return (url, mtime)
            }
            let recent = dated.sorted { $0.mtime > $1.mtime }.prefix(Self.startupCacheLoadLimit)

            var loadedCount = 0
            for item in recent {
                let trackId = item.url.deletingPathExtension().lastPathComponent
                if let lyrics = await loadLyricsFromDisk(trackId: trackId) {
                    cacheLyrics(lyrics, for: trackId)
                    loadedCount += 1
                }
            }
            // 单行汇总（此前每文件 3-4 条日志，几百首歌上千行噪音）
            print("📁 Lyrics disk cache: loaded \(loadedCount)/\(recent.count) recent of \(jsonFiles.count) files")
        } catch {
            print("❌ Failed to load lyrics cache from disk: \(error)")
        }
    }

    func clearDiskCache() async {
        guard let cacheDir = getLyricsCacheDirectory() else { return }

        do {
            try fileManager.removeItem(at: cacheDir)
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            print("💾 Cleared lyrics disk cache")
        } catch {
            print("❌ Failed to clear lyrics disk cache: \(error)")
        }
    }

    // MARK: - 负面缓存（确认无歌词的曲目，7 天 TTL；与正缓存同目录，统一参与 LRU）

    /// 负面标记文件：{stableId}.negative，mtime 即记录时刻（原子写，无内容）
    private func negativeCacheFileURL(trackId: String) -> URL? {
        guard let cacheDir = getLyricsCacheDirectory() else { return nil }
        return cacheDir.appendingPathComponent("\(trackId).negative")
    }

    func isNegativeCached(trackId: String) async -> Bool {
        guard let fileURL = negativeCacheFileURL(trackId: trackId),
              let mtime = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        if Date().timeIntervalSince(mtime) < Self.negativeCacheTTL {
            return true
        }
        // 过期：删除标记，下次全链路后重新写入
        try? fileManager.removeItem(at: fileURL)
        return false
    }

    func recordNegativeCache(trackId: String) async {
        guard let fileURL = negativeCacheFileURL(trackId: trackId) else { return }
        // 原子写（空内容），mtime 即记录时刻
        try? Data().write(to: fileURL, options: .atomic)
        await enforceDiskCacheLimit()
    }

    func clearNegativeCache(trackId: String) async {
        guard let fileURL = negativeCacheFileURL(trackId: trackId) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    /// LRU 上限：缓存文件数（.json 正缓存 + .negative 负面缓存）超出上限时
    /// 删除最久未使用的（按 mtime，最近读/写的保留）
    private func enforceDiskCacheLimit() async {
        guard let cacheDir = getLyricsCacheDirectory() else { return }
        let files = cacheFiles(in: cacheDir)
        guard files.count > Self.diskCacheFileLimit else { return }

        let dated = files.compactMap { url -> (url: URL, mtime: Date)? in
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return nil
            }
            return (url, mtime)
        }
        let keep = Set(dated.sorted { $0.mtime > $1.mtime }.prefix(Self.diskCacheFileLimit).map(\.url))
        for url in dated.map(\.url) where !keep.contains(url) {
            try? fileManager.removeItem(at: url)
        }
        print("📁 Lyrics disk cache trimmed to \(Self.diskCacheFileLimit) files")
    }

    /// 缓存目录内参与 LRU 的文件
    private func cacheFiles(in dir: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "json" || $0.pathExtension == "negative" } ?? []
    }
}

// MARK: - API Models

private struct LRCLibResponse: Codable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}
