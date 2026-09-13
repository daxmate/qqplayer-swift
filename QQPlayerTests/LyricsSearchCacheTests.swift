//
//  LyricsSearchCacheTests.swift
//  QQPlayerTests
//
//  歌词搜索候选缓存测试：
//  - 命中：save 后 load 返回相同候选（含网易云翻译字段）
//  - 未命中：无缓存返回 nil
//  - 大小写/首尾空白归一：同词不同写法命中同一缓存
//  - 损坏文件：返回 nil 且文件被删除（下次搜索可重写）
//  - 过期条目：timestamp 超过 TTL 返回 nil 且文件被删除
//  - 定期清理：目录中超过 TTL 的旧文件被删除
//  - 目录隔离：不会误删 LyricsManager 的逐曲歌词缓存（tracks/ 与 search/ 分离）
//
//  通过 directoryOverride 注入临时目录，不污染 App 沙盒。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct LyricsSearchCacheTests {
    private let cacheDir: URL

    init() {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        LyricsSearchCache.directoryOverride = cacheDir
    }

    private func neteaseCandidate() -> LyricsSearchCandidate {
        LyricsSearchCandidate(
            source: .netease,
            title: "花海",
            artist: "周杰伦",
            duration: 270,
            text: "[00:01.00]花海\n[00:05.00]爱存在",
            tlyric: "[00:01.00]花海\n[00:05.00]爱存在（翻译）"
        )
    }

    private func lrclibCandidate() -> LyricsSearchCandidate {
        LyricsSearchCandidate(
            source: .lrclib,
            title: "Flower Sea",
            artist: "Jay Chou",
            duration: 270,
            text: "[00:01.00]Flower Sea",
            tlyric: nil
        )
    }

    private var cacheFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - 命中/未命中

    @Test("保存后可命中，候选内容一致（含翻译字段）")
    func loadAfterSave() {
        let candidates = [neteaseCandidate(), lrclibCandidate()]
        LyricsSearchCache.shared.save(candidates, title: "花海", artist: "周杰伦")

        let loaded = LyricsSearchCache.shared.load(title: "花海", artist: "周杰伦")
        #expect(loaded != nil)
        #expect(loaded?.count == 2)
        #expect(loaded?[0].source == .netease)
        #expect(loaded?[0].text == "[00:01.00]花海\n[00:05.00]爱存在")
        #expect(loaded?[0].tlyric == "[00:01.00]花海\n[00:05.00]爱存在（翻译）")
        #expect(loaded?[1].source == .lrclib)
        #expect(loaded?[1].tlyric == nil)
    }

    @Test("无缓存时返回 nil")
    func missWithoutCache() {
        #expect(LyricsSearchCache.shared.load(title: "不存在的歌", artist: "") == nil)
    }

    @Test("大小写/首尾空白归一：同词不同写法命中同一缓存")
    func cacheKeyNormalizesCaseAndWhitespace() {
        let candidates = [neteaseCandidate()]
        LyricsSearchCache.shared.save(candidates, title: "  HuaHai ", artist: "jay chou")

        let loaded = LyricsSearchCache.shared.load(title: "huahai", artist: "Jay Chou")
        #expect(loaded?.count == 1)
        #expect(cacheFiles.count == 1) // 同一文件，未被重复写
    }

    // MARK: - 损坏/过期

    @Test("损坏文件：返回 nil 且文件被删除")
    func corruptFileReturnsNilAndRemoved() {
        // 先写一个正常缓存拿到文件名，再覆盖为损坏内容
        LyricsSearchCache.shared.save([neteaseCandidate()], title: "坏文件", artist: "")
        let files = cacheFiles
        #expect(files.count == 1)
        try? Data("not-json{{{".utf8).write(to: files[0])

        #expect(LyricsSearchCache.shared.load(title: "坏文件", artist: "") == nil)
        #expect(cacheFiles.isEmpty) // 损坏文件已被删除，下次搜索可重新写入
    }

    @Test("过期条目：timestamp 超过 TTL 返回 nil 且文件被删除")
    func expiredEntryReturnsNil() throws {
        LyricsSearchCache.shared.save([neteaseCandidate()], title: "过期歌", artist: "")
        let files = cacheFiles
        #expect(files.count == 1)

        // 把缓存条目时间戳改写为 TTL 之前（同构 Codable，按 key 匹配）
        let oldTimestamp = Date().addingTimeInterval(-8 * 24 * 3600) // 8 天前 > 7 天 TTL
        let expiredEntry = StaleEntry(timestamp: oldTimestamp, candidates: [neteaseCandidate()])
        let data = try JSONEncoder().encode(expiredEntry)
        try data.write(to: files[0])

        #expect(LyricsSearchCache.shared.load(title: "过期歌", artist: "") == nil)
        #expect(cacheFiles.isEmpty) // 过期文件已删除
    }

    // MARK: - 定期清理

    @Test("目录隔离：load 不会把 LyricsManager 的逐曲歌词缓存当损坏/过期删除")
    func doesNotDeleteTrackLyricsCache() throws {
        // 模拟真实目录结构：父目录下 tracks/（逐曲歌词）与 search/（搜索缓存）分离
        let parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-cache-isolation-\(UUID().uuidString)", isDirectory: true)
        let tracksDir = parentDir.appendingPathComponent("tracks", isDirectory: true)
        let searchDir = parentDir.appendingPathComponent("search", isDirectory: true)
        try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: searchDir, withIntermediateDirectories: true)

        // 对方格式文件：LyricsManager 的逐曲歌词（Lyrics 编码，与搜索缓存 Entry 不同构），
        // mtime 超过 TTL（若被误扫，cleanupExpired 会把它当过期文件删掉）
        let trackFile = tracksDir.appendingPathComponent("\(String(repeating: "a", count: 64)).json")
        try Data(#"{"source":"lrclib","syncedLyrics":[]}"#.utf8).write(to: trackFile)
        let oldMtime = Date().addingTimeInterval(-8 * 24 * 3600) // 8 天前 > 7 天 TTL
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: trackFile.path)

        // 搜索缓存目录注入为 search/ 子目录（与真实布局一致）
        LyricsSearchCache.directoryOverride = searchDir

        // search/ 下写入一个过期搜索缓存，触发清理
        LyricsSearchCache.shared.save([neteaseCandidate()], title: "旧搜索", artist: "")
        let searchFiles = try FileManager.default.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)
        #expect(searchFiles.count == 1)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: searchFiles[0].path)

        _ = LyricsSearchCache.shared.load(title: "旧搜索", artist: "")

        // 自己的过期文件被清掉
        let remainingSearch = try FileManager.default.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)
        #expect(remainingSearch.isEmpty)
        // 对方（逐曲歌词）文件原样保留，未被误删
        #expect(FileManager.default.fileExists(atPath: trackFile.path))
    }

    @Test("写入即清理：save 后即调用 cleanupExpired（修复前只在 load 内触发，停止搜索后文件长期驻留）")
    func saveTriggersCleanup() throws {
        LyricsSearchCache.shared.save([neteaseCandidate()], title: "写时清理", artist: "")
        let files = cacheFiles
        #expect(files.count == 1)

        // 把已写文件 mtime 改到 TTL 之前；下一次 save 应顺手清掉它（无需任何 load）
        let oldMtime = Date().addingTimeInterval(-8 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: files[0].path)

        LyricsSearchCache.shared.save([lrclibCandidate()], title: "另一个词", artist: "")

        #expect(cacheFiles.count == 1) // 只剩刚写入的新文件
    }

    @Test("条数上限：TTL 内文件过多时按 mtime 淘汰，目录不无限增长")
    func enforcesFileLimit() {
        let limit = LyricsSearchCache.fileLimit
        for index in 0 ..< (limit + 1) {
            LyricsSearchCache.shared.save([neteaseCandidate()], title: "上限歌\(index)", artist: "")
        }

        #expect(cacheFiles.count <= limit)
    }

    @Test("定期清理：删除超过 TTL 的旧缓存文件")
    func cleanupRemovesOldFiles() throws {
        // 两个搜索词，各写一个缓存
        LyricsSearchCache.shared.save([neteaseCandidate()], title: "新歌", artist: "")
        LyricsSearchCache.shared.save([lrclibCandidate()], title: "旧歌", artist: "")
        #expect(cacheFiles.count == 2)

        // 把其中一份的文件 mtime 改到 TTL 之前（模拟 8 天前写入的旧缓存）
        let oldMtime = Date().addingTimeInterval(-8 * 24 * 3600)
        let oldFile = cacheFiles[0] // 文件名是 sha256，任取一份改旧即可
        try FileManager.default.setAttributes(
            [.modificationDate: oldMtime],
            ofItemAtPath: oldFile.path
        )

        // 任意缓存操作触发清理
        _ = LyricsSearchCache.shared.load(title: "新歌", artist: "")
        #expect(cacheFiles.count == 1) // 旧文件被清掉，只剩新歌
    }

    /// 测试用同构缓存条目（LyricsSearchCache.Entry 是 private，无法直接构造）
    private struct StaleEntry: Codable {
        let timestamp: Date
        let candidates: [LyricsSearchCandidate]
    }
}
