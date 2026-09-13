//
//  LyricsManagerCacheTests.swift
//  QQPlayerTests
//
//  审计 🔵-5 回归：LyricsManager 内存歌词缓存上限（LRU）。
//
//  修复前 `cache` 是无上限字典（`getLyrics` 每次命中都写入），长会话只增不减；
//  本用例在修复前必红：写入 limit+5 条后 `cache.count` = limit+5（断言 `<= limit` 失败），
//  且 `cacheLyrics(_:for:)` 这个唯一写入入口本身也是修复新增的。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct LyricsManagerCacheTests {
    private func lyrics(_ text: String) -> Lyrics {
        Lyrics(plainLyrics: text, syncedLyrics: [], isInstrumental: false, source: .lrclib)
    }

    @Test("内存缓存超过上限时淘汰最久未使用的条目")
    func evictsOldestBeyondLimit() async {
        let manager = LyricsManager.shared
        let limit = LyricsManager.memoryCacheLimit
        let overflow = 5

        for index in 0 ..< (limit + overflow) {
            await manager.cacheLyrics(lyrics("l\(index)"), for: "cap-test-\(index)")
        }

        let count = await manager.cache.count
        #expect(count <= limit)
        // 最早写入的被淘汰；最近写入的仍在
        #expect(await manager.cache["cap-test-0"] == nil)
        #expect(await manager.cache["cap-test-\(limit + overflow - 1)"] != nil)
    }

    @Test("重写已有键会刷新其 LRU 位置（不被误淘汰）")
    func rewriteRefreshesRecency() async {
        let manager = LyricsManager.shared
        let limit = LyricsManager.memoryCacheLimit

        for index in 0 ..< limit {
            await manager.cacheLyrics(lyrics("l\(index)"), for: "lru-test-\(index)")
        }
        // 重写最早写入的键 = 标记为最近使用
        await manager.cacheLyrics(lyrics("touched"), for: "lru-test-0")
        // 再写一条触发一次淘汰：应淘汰 lru-test-1（次久未用），保留刚触摸过的 lru-test-0
        await manager.cacheLyrics(lyrics("extra"), for: "lru-test-extra")

        #expect(await manager.cache["lru-test-0"] != nil)
        #expect(await manager.cache["lru-test-1"] == nil)
    }

    @Test("clearMemoryCache 只丢内存，不动磁盘缓存入口")
    func clearMemoryCacheDropsMemoryOnly() async {
        let manager = LyricsManager.shared
        await manager.cacheLyrics(lyrics("x"), for: "clear-test")
        #expect(await manager.cache["clear-test"] != nil)

        await manager.clearMemoryCache()

        #expect(await manager.cache.isEmpty)
    }
}
