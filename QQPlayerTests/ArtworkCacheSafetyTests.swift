//
//  ArtworkCacheSafetyTests.swift
//  QQPlayerTests
//
//  2026-09-22 用户可见回归「封面全部显示不出来」的回归锁。
//
//  —— 事故链（真机日志实证，时间戳为 UTC）——
//   1. `06:47:13Z` `🗑️ Cleaned up 1 unused artwork files`：曲库文件夹化把映射表搬进了
//      **缓存目录内部**（`Documents/Artwork/ArtworkMapping.plist`），而 `cleanupOrphanedArtwork`
//      把该目录下**每个文件**都当 `<hash>.jpg`（名字不在 `usedHashes` 里就删）⇒ 映射表被当
//      「未引用的缓存文件」删掉。
//   2. `06:50:44Z` `🗑️ Cleaned up 194 unused artwork files`：映射表文件没了 ⇒ 下次启动
//      `loadMapping()` 什么都读不到 ⇒ 内存映射为空 ⇒ `usedHashes` 为空 ⇒ **全部** 194 个
//      缓存文件被当孤儿删光。调用侧只有「DB 没有曲目」的守卫，没有「映射为空」的守卫。
//
//  —— 本文件锁住的契约（纯函数，单一判据）——
//   · `shouldPruneArtworkCache`：映射为空 / 读失败 ⇒ **不许**清理（fail-safe，不是 fail-destructive）。
//   · `deletableArtworkCacheFileNames`：只认 `<64 位 hex>.jpg` 缓存命名；映射表等元数据永不被删。
//   · `mergedMapping`：两处映射合并，键冲突**新位置优先**（旧位置只读兼容不能丢条目）。
//
//  为什么用纯函数而不是端到端跑 `cleanupOrphanedArtwork`：`ArtworkManager` 是
//  `private init` 的 `@MainActor` 单例，其缓存/映射路径在 `init` 时定死，测试无法注入；
//  而删除动作正是「用这两个判据筛出文件集合后逐个 removeItem」——
//  判据被锁住 + 落盘命名口径唯一，删除集合即确定。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("封面缓存清理：fail-safe 判据 + 元数据保护")
struct ArtworkCacheSafetyTests {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)

    // MARK: - 判据：映射不可信时不许清理

    @Test("映射为空时禁止清理缓存（空 = 可能只是映射丢了，不是全部封面成孤儿）")
    func emptyMappingNeverPrunes() {
        #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [:], mappingUnreadable: false) == false)
    }

    @Test("映射存在但读失败时禁止清理缓存（内容未知 ≠ 空）")
    func unreadableMappingNeverPrunes() {
        #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [hashA: hashB], mappingUnreadable: true) == false)
        #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [:], mappingUnreadable: true) == false)
    }

    @Test("映射已加载且非空时才允许清理")
    func loadedMappingPrunes() {
        #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [hashA: hashB], mappingUnreadable: false))
    }

    // MARK: - 元数据保护：映射表与缓存同目录

    @Test("映射表文件永不被当孤儿缓存删除（事故第 1 步：06:47:13Z 删的就是它）")
    func mappingFileIsNeverArtworkCache() {
        #expect(ArtworkManager.isArtworkCacheFileName(LibraryRoot.artworkMappingFileName) == false)
        // 即使 usedHashes 为空（正是第二步「全量清空」的入参），映射表也不在删除集合里。
        let deletable = ArtworkManager.deletableArtworkCacheFileNames(
            [LibraryRoot.artworkMappingFileName, "\(hashA).jpg"],
            usedHashes: []
        )
        #expect(deletable == ["\(hashA).jpg"])
    }

    @Test("非缓存命名的文件一律不删（临时文件 / 其它元数据 / 目录里混进的任何东西）")
    func nonCacheNamesAreUntouched() {
        let names = [
            "notahash.jpg", // 长度/字符不符
            "\(hashA).png", // 扩展名不符
            "\(hashA.uppercased()).jpg", // 大写不是落盘命名（SHA256 hex 输出恒小写）
            "ArtworkMapping.plist",
            ".DS_Store",
            hashA, // 无扩展名
        ]
        #expect(ArtworkManager.deletableArtworkCacheFileNames(names, usedHashes: []).isEmpty)
        #expect(names.allSatisfy { ArtworkManager.isArtworkCacheFileName($0) == false })
    }

    @Test("反向验证（事故完整入参）：映射为空时『未引用』筛子会选走全部缓存 ⇒ 必须靠判据拦住，而不是靠筛子")
    func incidentScenarioGuardIsWhatSavesTheCache() {
        let names = ["\(hashA).jpg", "\(hashB).jpg", "\(String(repeating: "c", count: 64)).jpg", LibraryRoot.artworkMappingFileName]

        // 修复前口径是「`usedHashes` 为空 ⇒ 名字不在里面的都删」——目录里 3 个缓存文件
        // 全部命中（映射表反而因命名不符被旧口径一并删了）；这正是
        // 06:50:44Z `Cleaned up 194 unused artwork files` 的成因。
        // 所以真正的防线不是筛子，而是入口判据：映射为空时**根本不进入**删除流程。
        #expect(ArtworkManager.deletableArtworkCacheFileNames(names, usedHashes: []).count == 3) // 3 个缓存文件（映射表不在内）
        #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [:], mappingUnreadable: false) == false) // 判据拦住 ⇒ 实际删除 0 个
    }

    @Test("映射非空时：只删未被引用的缓存文件，被引用的保留")
    func prunesOnlyUnreferencedCaches() {
        let names = ["\(hashA).jpg", "\(hashB).jpg", LibraryRoot.artworkMappingFileName]

        let deletable = ArtworkManager.deletableArtworkCacheFileNames(names, usedHashes: [hashA])

        #expect(deletable == ["\(hashB).jpg"])
    }

    // MARK: - 合并：旧位置只读兼容

    @Test("合并映射：键冲突新位置优先，旧位置独有条目保留")
    func mergeKeepsLegacyOnlyEntriesAndPrefersCurrent() {
        let merged = ArtworkManager.mergedMapping(
            current: ["sid-1": "hash-new", "sid-2": "hash-2"],
            legacy: ["sid-1": "hash-old", "sid-3": "hash-3"]
        )

        #expect(merged["sid-1"] == "hash-new") // 冲突 → 新位置优先
        #expect(merged["sid-2"] == "hash-2")
        #expect(merged["sid-3"] == "hash-3") // 旧位置独有 → 绝不丢
        #expect(merged.count == 3)
    }

    @Test("合并映射：任一侧缺失时退化为另一侧（不把缺失当空覆盖）")
    func mergeHandlesMissingSides() {
        #expect(ArtworkManager.mergedMapping(current: nil, legacy: ["sid-1": "hash-1"]) == ["sid-1": "hash-1"])
        #expect(ArtworkManager.mergedMapping(current: ["sid-1": "hash-1"], legacy: nil) == ["sid-1": "hash-1"])
        #expect(ArtworkManager.mergedMapping(current: nil, legacy: nil).isEmpty)
    }

    // MARK: - 读盘判据

    @Test("readMapping：文件不存在返回 nil；写入后可读回")
    func readMappingRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-artwork-mapping-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ArtworkManager.readMapping(at: url) == nil) // 不存在 → nil（不是空表）

        let mapping = ["sid-1": "hash-1"]
        let data = try PropertyListSerialization.data(fromPropertyList: mapping, format: .xml, options: 0)
        try data.write(to: url)

        #expect(ArtworkManager.readMapping(at: url) == mapping)
        #expect(ArtworkManager.mappingFileExistsUnreadable(url, parsed: ArtworkManager.readMapping(at: url)) == false)
    }

    @Test("readMapping：文件存在但内容损坏 → nil，且判为「存在但读不出来」（未知）")
    func readMappingFlagsCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-artwork-mapping-corrupt-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a plist".utf8).write(to: url)

        let parsed = ArtworkManager.readMapping(at: url)

        #expect(parsed == nil)
        // 关键：损坏文件算「未知」⇒ `shouldPruneArtworkCache` 会拦住清理（不删缓存）。
        #expect(ArtworkManager.mappingFileExistsUnreadable(url, parsed: parsed))
        #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [:], mappingUnreadable: true) == false)
    }
}
