//
//  LyricsSearchCache.swift
//  QQPlayer
//
//  歌词搜索候选缓存：按搜索词缓存双源搜索结果（网易云 + lrclib），
//  命中未过期缓存时直接返回，避免重复请求网络；TTL 过期自动清理。
//
//  存储：Documents/lyrics-cache/search/<sha256>.json，每个搜索词一个文件，
//  原子写入；目录可注入（测试用），与 LyricsManager.manualLyricsDirectoryOverride 同款模式。
//

import CryptoKit
import Foundation

struct LyricsSearchCache: Sendable {
    static let shared = LyricsSearchCache()

    /// 测试注入：替换缓存目录（避免污染 App 沙盒 Documents）
    nonisolated(unsafe) static var directoryOverride: URL?

    /// 缓存有效期（秒）：7 天
    private static let ttl: TimeInterval = 7 * 24 * 3600

    /// 目录文件数上限：TTL 之内的文件过多（高频搜索）时按 mtime 淘汰最久未写的。
    /// 与 LyricsManager.diskCacheFileLimit 同为 200（两侧不对称会在长会话下堆文件）。
    static let fileLimit = 200

    private struct Entry: Codable {
        let timestamp: Date
        let candidates: [LyricsSearchCandidate]
    }

    private var directory: URL {
        if let override = Self.directoryOverride {
            return override
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics-cache/search", isDirectory: true)
    }

    /// 读取缓存：命中且未过期返回候选；过期/损坏删除并返回 nil（下次搜索重新走网络）
    func load(title: String, artist: String) -> [LyricsSearchCandidate]? {
        cleanupExpired()

        let url = fileURL(title: title, artist: artist)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            // 损坏即删：避免垃圾文件堆积，下次搜索可重新写入
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard Date().timeIntervalSince(entry.timestamp) < Self.ttl else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry.candidates
    }

    /// 写入缓存（原子写，mtime 即写入时刻，作为定期清理依据）；
    /// 写完顺带清理一次（TTL + 条数上限）——此前清理只在 load 内触发，
    /// 用户停止搜索后 <sha256>.json 会长期驻留（审计 🔵-6）。
    func save(_ candidates: [LyricsSearchCandidate], title: String, artist: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let entry = Entry(timestamp: Date(), candidates: candidates)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(title: title, artist: artist), options: .atomic)
        cleanupExpired()
    }

    /// 清理：删除目录中超过 TTL 的旧缓存文件，并对 TTL 内文件执行条数上限
    /// （读写时顺带执行一次，目录文件数极少，开销可忽略）。
    func cleanupExpired() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var survivors: [(url: URL, mtime: Date)] = []
        for file in files {
            guard file.pathExtension == "json" else { continue }
            guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                // mtime 读不到：保守保留且不参与淘汰（不可能判定为旧）
                survivors.append((file, .distantFuture))
                continue
            }
            if mtime < cutoff {
                try? fm.removeItem(at: file)
            } else {
                survivors.append((file, mtime))
            }
        }

        // 条数上限：TTL 内文件仍过多时，按 mtime 淘汰最久未写的
        guard survivors.count > Self.fileLimit else { return }
        let excess = survivors.count - Self.fileLimit
        for survivor in survivors.sorted(by: { $0.mtime < $1.mtime }).prefix(excess) {
            try? fm.removeItem(at: survivor.url)
        }
    }

    // MARK: - Private

    private func fileURL(title: String, artist: String) -> URL {
        directory.appendingPathComponent(cacheKey(title: title, artist: artist) + ".json")
    }

    /// 缓存文件名键：搜索词（歌名+歌手，忽略大小写/首尾空白）的 SHA256，跨启动稳定
    private func cacheKey(title: String, artist: String) -> String {
        let raw = "\(title.trimmingCharacters(in: .whitespaces).lowercased())\u{0}\(artist.trimmingCharacters(in: .whitespaces).lowercased())"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
