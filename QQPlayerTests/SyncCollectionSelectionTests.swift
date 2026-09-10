//
//  SyncCollectionSelectionTests.swift
//  QQPlayerTests
//
//  R3a（2026-09-11）选择集模型 + 展开器 + 双向差集（纯逻辑）：
//  - 选择集规范化（去空白/丢非法/去重/升序）
//  - 空选择集语义 = 不推不拉（≠ 全库）
//  - 未知/非法歌单标识 → 忽略 + 记账（不抛）
//  - 展开器：歌单→曲目→content_hash→相对路径；歌词随歌纳入；
//    未指纹/未入库 → 跳过 + unresolved 记账（不中止整批、不伪造路径）
//  - 差集方向：对端缺→推、本端缺→拉、一致→跳过、内容不同→推（发起方权威）、
//    对端独有→忽略（不传播删除）
//
//  fixture：内存事实注入（不启模拟器、不碰 DB 单例）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 内存曲库事实（注入桩）

/// 歌单 → 曲目事实 的内存实现（纯值；unknownPlaylists 里的 id 返回 nil = 歌单不存在）。
private struct MemoryFacts: SyncCollectionFactsProviding {
    var playlistTracks: [String: [SyncCollectionTrackFact]] = [:]
    var trackByPath: [String: SyncCollectionTrackFact] = [:]
    var lyricsWirePaths: Set<String> = []

    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? {
        playlistTracks[playlistID]
    }

    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        trackByPath[relativePath]
    }

    func hasLyrics(atWirePath wirePath: String) -> Bool {
        lyricsWirePaths.contains(wirePath)
    }
}

private let hashA = String(repeating: "a", count: 64)
private let hashB = String(repeating: "b", count: 64)

// MARK: - ① 选择集规范化 / 空集合语义

@Suite("R3a 选择集模型")
struct SyncCollectionSelectionTests {
    @Test("歌单标识规范化：去空白 / 丢非法 / 去重 / 升序")
    func normalizePlaylistIDs() {
        let normalized = SyncCollectionSelection.normalizePlaylistIDs([
            "  b-list  ",
            "a-list",
            "b-list",
            "",
            "   ",
            "with/slash",
            "with\\backslash",
            ".",
            "..",
            String(repeating: "x", count: 200),
            "tab\tid",
        ])
        #expect(normalized == ["a-list", "b-list"])
    }

    @Test("空选择集 = 不推不拉（与全库语义相反）")
    func emptySelectionSemantics() {
        #expect(SyncCollectionSelection.playlists([]).isEmptySelection)
        #expect(SyncCollectionSelection.playlists(["", "  ", "bad/id"]).isEmptySelection)
        #expect(SyncCollectionSelection.relativePaths([]).isEmptySelection)
        #expect(SyncCollectionSelection.relativePaths(["../escape"]).isEmptySelection)
        #expect(!SyncCollectionSelection.all.isEmptySelection)
        #expect(SyncCollectionSelection.all.isLibraryWide)
        #expect(!SyncCollectionSelection.playlists(["p1"]).isEmptySelection)
        #expect(!SyncCollectionSelection.playlists(["p1"]).isLibraryWide)
    }

    @Test("相对路径规范化复用既有口径：丢非法 + 去重 + 升序")
    func normalizePaths() {
        let selection = SyncCollectionSelection.relativePaths([
            " Album/b.flac ",
            "Album/a.flac",
            "Album/a.flac",
            "/absolute.flac",
            "../escape.flac",
            ".",
        ])
        #expect(selection.relativePaths == ["Album/a.flac", "Album/b.flac"])
    }

    @Test("收藏是保留标识（形态合法，且与真实歌单互不干扰）")
    func favoritesReservedID() {
        #expect(SyncCollectionSelection.isValidPlaylistID(SyncCollectionSelection.favoritesPlaylistID))
        #expect(
            SyncCollectionSelection
                .normalizePlaylistIDs([SyncCollectionSelection.favoritesPlaylistID, "a-list"])
                == ["@favorites", "a-list"].sorted()
        )
    }

    @Test("normalized 等价选择集：非法值一律丢弃")
    func normalizedSelection() {
        #expect(
            SyncCollectionSelection.playlists([" b ", "a", "a", ""]).normalized
                == SyncCollectionSelection.playlists(["a", "b"])
        )
        #expect(SyncCollectionSelection.all.normalized == SyncCollectionSelection.all)
    }
}

// MARK: - ② 展开器

@Suite("R3a 选择集展开器")
struct SyncCollectionExpanderTests {
    @Test("全库选择不展开（调用方用本端全量 manifest）")
    func expandAll() {
        let expansion = SyncCollectionExpander.expand(selection: .all, facts: MemoryFacts())
        #expect(expansion.isLibraryWide)
        #expect(!expansion.isEmptySelection)
        #expect(expansion.entries.isEmpty)
        #expect(expansion.unresolvedCount == 0)
    }

    @Test("空选择集 → 不推不拉（不产出条目）")
    func expandEmpty() {
        let expansion = SyncCollectionExpander.expand(selection: .playlists([]), facts: MemoryFacts())
        #expect(expansion.isEmptySelection)
        #expect(!expansion.isLibraryWide)
        #expect(expansion.entries.isEmpty)
        #expect(expansion.relativePaths.isEmpty)
    }

    @Test("歌单展开：曲目 → 相对路径 + content_hash；未指纹/未入库记入 unresolved（不中止整批）")
    func expandPlaylist() {
        var facts = MemoryFacts()
        facts.playlistTracks["p1"] = [
            SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/one.flac", contentHash: hashA),
            // 未指纹 → 跳过 + 记账
            SyncCollectionTrackFact(stableId: "s2", relativePath: "Album/two.flac", contentHash: nil),
            // 未入库（拿不到相对路径）→ 跳过 + 记账
            SyncCollectionTrackFact(stableId: "s3", relativePath: nil, contentHash: hashB),
            // 哈希形态非法 → 视为未指纹
            SyncCollectionTrackFact(stableId: "s4", relativePath: "Album/four.flac", contentHash: "not a hash"),
        ]

        let expansion = SyncCollectionExpander.expand(selection: .playlists(["p1"]), facts: facts)

        #expect(expansion.entries.map(\.relativePath) == ["Album/one.flac"])
        #expect(expansion.entries.first?.contentHash == hashA)
        #expect(expansion.songEntryCount == 1)
        #expect(expansion.lyricsEntryCount == 0)
        #expect(expansion.unresolvedCount == 3)
        #expect(
            expansion.unresolved.map(\.reason).sorted()
                == [
                    SyncCollectionUnresolvedReason.notFingerprinted,
                    SyncCollectionUnresolvedReason.notFingerprinted,
                    SyncCollectionUnresolvedReason.notInLibrary,
                ].sorted()
        )
        #expect(Set(expansion.unresolved.map(\.stableId)) == ["s2", "s3", "s4"])
        #expect(expansion.unknownPlaylistIDs.isEmpty)
    }

    @Test("歌词随歌纳入：wire 路径 @lyrics/{歌曲 content_hash}.json（本端没有就不纳入）")
    func expandPlaylistWithLyrics() {
        var facts = MemoryFacts()
        facts.playlistTracks["p1"] = [
            SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/one.flac", contentHash: hashA),
            SyncCollectionTrackFact(stableId: "s2", relativePath: "Album/two.flac", contentHash: hashB),
        ]
        facts.lyricsWirePaths = [SyncLyricsNamespace.wirePath(songContentHash: hashA)!]

        let expansion = SyncCollectionExpander.expand(selection: .playlists(["p1"]), facts: facts)

        #expect(
            expansion.relativePaths
                == ["@lyrics/\(hashA).json", "Album/one.flac", "Album/two.flac"].sorted()
        )
        #expect(expansion.songEntryCount == 2)
        #expect(expansion.lyricsEntryCount == 1)
        #expect(expansion.entries.first { $0.isLyrics }?.contentHash == hashA)
        // 歌词条目按歌曲 content_hash 唯一命名，不按本端 stableId
        #expect(!expansion.relativePaths.contains { $0.contains("s1") })
    }

    @Test("未知歌单 + 非法标识 → 忽略并记账（不抛、不影响其它歌单）")
    func expandUnknownPlaylist() {
        var facts = MemoryFacts()
        facts.playlistTracks["p1"] = [
            SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/one.flac", contentHash: hashA),
        ]
        facts.playlistTracks["empty"] = []

        let expansion = SyncCollectionExpander.expand(
            selection: .playlists(["p1", "missing", "empty", "bad/id"]),
            facts: facts
        )

        #expect(expansion.entries.map(\.relativePath) == ["Album/one.flac"])
        #expect(expansion.unknownPlaylistIDs == ["bad/id", "missing"].sorted())
        #expect(expansion.unresolvedCount == 0)
    }

    @Test("多歌单并集：同曲去重、相对路径升序（确定性）")
    func expandUnionDeterministic() {
        var facts = MemoryFacts()
        facts.playlistTracks["p1"] = [
            SyncCollectionTrackFact(stableId: "s2", relativePath: "Album/b.flac", contentHash: hashB),
            SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/a.flac", contentHash: hashA),
        ]
        facts.playlistTracks["p2"] = [
            SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/a.flac", contentHash: hashA),
        ]

        let first = SyncCollectionExpander.expand(selection: .playlists(["p1", "p2"]), facts: facts)
        let second = SyncCollectionExpander.expand(selection: .playlists(["p2", "p1"]), facts: facts)

        #expect(first.relativePaths == ["Album/a.flac", "Album/b.flac"])
        #expect(first.entries == second.entries) // 与歌单顺序无关
    }

    @Test("显式路径展开：已知路径带 content_hash；未知路径记 unresolved；歌词路径直接纳入")
    func expandExplicitPaths() {
        var facts = MemoryFacts()
        facts.trackByPath["Album/one.flac"] = SyncCollectionTrackFact(
            stableId: "s1",
            relativePath: "Album/one.flac",
            contentHash: hashA
        )
        facts.lyricsWirePaths = [SyncLyricsNamespace.wirePath(songContentHash: hashA)!]

        let expansion = SyncCollectionExpander.expand(
            selection: .relativePaths([
                "Album/one.flac",
                "Album/unknown.flac",
                "@lyrics/\(hashA).json",
                "@lyrics/\(hashB).json",
            ]),
            facts: facts
        )

        // 已知歌曲 + 已存在歌词纳入；同 hash 的歌词条目去重
        #expect(
            expansion.relativePaths == ["@lyrics/\(hashA).json", "Album/one.flac"].sorted()
        )
        // 未知歌曲 + 本端不存在的歌词各记一条 unresolved
        #expect(expansion.unresolvedCount == 2)
        #expect(
            Set(expansion.unresolved.map(\.relativePath))
                == ["Album/unknown.flac", "@lyrics/\(hashB).json"]
        )
        #expect(expansion.unresolved.allSatisfy { $0.stableId.isEmpty })
    }

    @Test("expected 集合过滤本端 manifest：库级 = 不过滤；选择性 = 只留期望路径")
    func filterManifest() {
        let entries = [
            ManifestEntry(relativePath: "Album/a.flac", size: 1, mtimeMs: 0, contentHash: hashA),
            ManifestEntry(relativePath: "Album/b.flac", size: 1, mtimeMs: 0, contentHash: hashB),
            ManifestEntry(relativePath: "@lyrics/\(hashA).json", size: 1, mtimeMs: 0, contentHash: hashA),
        ]
        var facts = MemoryFacts()
        facts.playlistTracks["p1"] = [
            SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/b.flac", contentHash: hashB),
        ]

        let scoped = SyncCollectionExpander.expand(selection: .playlists(["p1"]), facts: facts)
        #expect(scoped.filter(entries).map(\.relativePath) == ["Album/b.flac"])

        let libraryWide = SyncCollectionExpander.expand(selection: .all, facts: facts)
        #expect(libraryWide.filter(entries).count == 3)
    }
}

// MARK: - ③ 双向差集

@Suite("R3a 双向差集")
struct SyncCollectionDiffPlannerTests {
    private func manifest(_ pairs: [(String, String?)]) -> [ManifestEntry] {
        pairs.map { ManifestEntry(relativePath: $0.0, size: 10, mtimeMs: 0, contentHash: $0.1) }
    }

    @Test("对端缺 → 推；本端缺 → 拉；两侧一致 → 跳过")
    func directions() {
        // local 只持有 push + same；pull 只在远端（本端缺 → 拉）。
        // ⚠️ 2026-09-11 修正：原先 local 里多写了一条 pull.flac，而两侧同 hash
        // ⇒ 判据只能是「一致」而非「本端缺」，与用例名/其余断言矛盾（CI 929 用例唯一红点）。
        let local = manifest([("Album/push.flac", hashA), ("Album/same.flac", hashA)])
        let remote = manifest([("Album/same.flac", hashA), ("Album/pull.flac", hashB)])
        let expected = ["Album/pull.flac", "Album/push.flac", "Album/same.flac"]

        let diff = SyncCollectionDiffPlanner.plan(expected: expected, local: local, remote: remote)

        #expect(diff.toPush == ["Album/push.flac"])
        #expect(diff.toPull == ["Album/pull.flac"])
        #expect(diff.unchanged == ["Album/same.flac"])
        #expect(diff.missingBoth.isEmpty)
        #expect(diff.remoteOnlyIgnored.isEmpty)
    }

    @Test("内容不同 → 只推不回拉（发起方权威，避免来回互相覆盖）")
    func contentDiffersPushesOnly() {
        let local = manifest([("Album/x.flac", hashA)])
        let remote = manifest([("Album/x.flac", hashB)])

        let diff = SyncCollectionDiffPlanner.plan(expected: ["Album/x.flac"], local: local, remote: remote)

        #expect(diff.toPush == ["Album/x.flac"])
        #expect(diff.toPull.isEmpty)
        #expect(diff.unchanged.isEmpty)
    }

    @Test("任一侧未指纹（content_hash 为 nil）→ 保守判为需推送")
    func unknownHashPushes() {
        let local = manifest([("Album/x.flac", nil)])
        let remote = manifest([("Album/x.flac", hashA)])
        #expect(
            SyncCollectionDiffPlanner.plan(expected: ["Album/x.flac"], local: local, remote: remote).toPush
                == ["Album/x.flac"]
        )

        let localKnown = manifest([("Album/x.flac", hashA)])
        let remoteUnknown = manifest([("Album/x.flac", nil)])
        #expect(
            SyncCollectionDiffPlanner.plan(expected: ["Album/x.flac"], local: localKnown, remote: remoteUnknown).toPush
                == ["Album/x.flac"]
        )
    }

    @Test("对端独有 → 只记账、不动手（绝不跨端删除）")
    func remoteOnlyIgnored() {
        let local = manifest([("Album/keep.flac", hashA)])
        let remote = manifest([
            ("Album/keep.flac", hashA),
            ("Imported/device-only.flac", hashB),
            ("Imported/device-only-2.flac", nil),
        ])

        let diff = SyncCollectionDiffPlanner.plan(expected: ["Album/keep.flac"], local: local, remote: remote)

        #expect(diff.unchanged == ["Album/keep.flac"])
        #expect(diff.toPush.isEmpty)
        #expect(diff.toPull.isEmpty)
        #expect(diff.remoteOnlyIgnored == ["Imported/device-only-2.flac", "Imported/device-only.flac"])
        #expect(diff.transferCount == 0)
    }

    @Test("期望路径两侧都没有实体 → missingBoth（不伪造、不动手）")
    func missingBoth() {
        let diff = SyncCollectionDiffPlanner.plan(expected: ["Album/ghost.flac"], local: [], remote: [])
        #expect(diff.missingBoth == ["Album/ghost.flac"])
        #expect(diff.transferCount == 0)
    }

    @Test("差集输出升序（确定性，便于比对与日志）")
    func deterministicOrder() {
        let local = manifest([("Album/c.flac", hashA), ("Album/a.flac", hashA), ("Album/b.flac", hashA)])
        let diff = SyncCollectionDiffPlanner.plan(
            expected: ["Album/c.flac", "Album/a.flac", "Album/b.flac"],
            local: local,
            remote: []
        )
        #expect(diff.toPush == ["Album/a.flac", "Album/b.flac", "Album/c.flac"])
    }
}
