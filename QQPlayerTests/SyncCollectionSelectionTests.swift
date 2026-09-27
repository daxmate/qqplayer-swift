//
//  SyncCollectionSelectionTests.swift
//  QQPlayerTests
//
//  R3a + T7（2026-09-11）选择集模型 + 展开器 + **单向**差集（纯逻辑）：
//  - 选择集规范化（去空白/丢非法/去重/升序）
//  - 空选择集语义 = 不推不拉（≠ 全库）
//  - 未知/非法歌单标识 → 忽略 + 记账（不抛）
//  - 展开器：歌单→曲目→content_hash→相对路径；歌词随歌纳入；
//    未指纹/未入库 → 跳过 + unresolved 记账（不中止整批、不伪造路径）
//  - 差集方向（T7）：upload 只推（本端缺对端有不拉）、download 只拉
//    （对端独有 → 拉）、一致 → 跳过、内容不同 → upload 推 / download 本端保留、
//    对端独有（期望之外）→ 忽略（不传播删除）
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
/// 夹具自查（2026-09-28）：`uploadDirections` 原先把 `push.flac` 与 `same.flac` 写成同一个
/// `hashA` —— 那是**两个不同的歌**被误当成同一内容身份（跨路径判定的活值），改用独立指纹
/// 恢复 fixture 原意（断言文本不变）。
private let hashPush = String(repeating: "c", count: 64)
/// 夹具自查（2026-09-28，全仓同类别名扫描）：`downloadDirections` 的 `local` 同样把
/// `local-only.flac` 与 `same.flac` 写成同一个 `hashA`（与已修的 `uploadDirections` 同源笔误，
/// 只是 download 方向的 `localOnlySkipped` 分支不查内容身份故未暴露）。改用独立指纹，
/// 恢复「对端确实没有 local-only」的 fixture 原意（**断言文本不变**）。
private let hashLocal = String(repeating: "d", count: 64)

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

// MARK: - ③ 单向差集（T7：方向显式）

@Suite("T7 单向差集")
struct SyncCollectionDiffPlannerTests {
    private func manifest(_ pairs: [(String, String?)]) -> [ManifestEntry] {
        pairs.map { ManifestEntry(relativePath: $0.0, size: 10, mtimeMs: 0, contentHash: $0.1) }
    }

    @Test("upload：对端缺 → 推；本端缺 → 不拉（仅记账）；两侧一致 → 跳过")
    func uploadDirections() {
        // local 只持有 push + same；pull 只在远端（upload 方向**不许拉**）。
        // push.flac 与 same.flac 是**两首不同的歌**（独立指纹，勿共用）。
        let local = manifest([("Album/push.flac", hashPush), ("Album/same.flac", hashA)])
        let remote = manifest([("Album/same.flac", hashA), ("Album/pull.flac", hashB)])
        let expected = ["Album/pull.flac", "Album/push.flac", "Album/same.flac"]

        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected, local: local, remote: remote, direction: .upload
        )

        #expect(diff.toPush == ["Album/push.flac"])
        #expect(diff.toPull.isEmpty)
        #expect(diff.peerOnlySkipped == ["Album/pull.flac"])
        #expect(diff.unchanged == ["Album/same.flac"])
        #expect(diff.missingBoth.isEmpty)
        #expect(diff.remoteOnlyIgnored.isEmpty)
    }

    @Test("download：对端独有 → 拉；本端独有 → 不推不删（仅记账）")
    func downloadDirections() {
        let local = manifest([("Album/local-only.flac", hashLocal), ("Album/same.flac", hashA)])
        let remote = manifest([("Album/same.flac", hashA), ("Album/peer-only.flac", hashB)])
        let expected = ["Album/peer-only.flac", "Album/local-only.flac", "Album/same.flac"]

        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected, local: local, remote: remote, direction: .download
        )

        #expect(diff.toPull == ["Album/peer-only.flac"])
        #expect(diff.toPush.isEmpty)
        #expect(diff.localOnlySkipped == ["Album/local-only.flac"])
        #expect(diff.unchanged == ["Album/same.flac"])
    }

    @Test("内容不同：upload → 只推（本端权威）；download → 本端保留、不覆盖")
    func contentDiffersPerDirection() {
        let local = manifest([("Album/x.flac", hashA)])
        let remote = manifest([("Album/x.flac", hashB)])

        let upload = SyncCollectionDiffPlanner.plan(
            expected: ["Album/x.flac"], local: local, remote: remote, direction: .upload
        )
        #expect(upload.toPush == ["Album/x.flac"])
        #expect(upload.toPull.isEmpty)
        #expect(upload.unchanged.isEmpty)

        let download = SyncCollectionDiffPlanner.plan(
            expected: ["Album/x.flac"], local: local, remote: remote, direction: .download
        )
        #expect(download.conflictingKept == ["Album/x.flac"])
        #expect(download.toPush.isEmpty)
        #expect(download.toPull.isEmpty)
        #expect(download.transferCount == 0)
    }

    @Test("任一侧未指纹（content_hash 为 nil）→ upload 保守判为需推送；download 保守判为本端保留")
    func unknownHashPerDirection() {
        let localUnknown = manifest([("Album/x.flac", nil)])
        let remoteKnown = manifest([("Album/x.flac", hashA)])
        #expect(
            SyncCollectionDiffPlanner
                .plan(expected: ["Album/x.flac"], local: localUnknown, remote: remoteKnown, direction: .upload)
                .toPush == ["Album/x.flac"]
        )
        #expect(
            SyncCollectionDiffPlanner
                .plan(expected: ["Album/x.flac"], local: localUnknown, remote: remoteKnown, direction: .download)
                .conflictingKept == ["Album/x.flac"]
        )

        let localKnown = manifest([("Album/x.flac", hashA)])
        let remoteUnknown = manifest([("Album/x.flac", nil)])
        #expect(
            SyncCollectionDiffPlanner
                .plan(expected: ["Album/x.flac"], local: localKnown, remote: remoteUnknown, direction: .upload)
                .toPush == ["Album/x.flac"]
        )
        #expect(
            SyncCollectionDiffPlanner
                .plan(expected: ["Album/x.flac"], local: localKnown, remote: remoteUnknown, direction: .download)
                .conflictingKept == ["Album/x.flac"]
        )
    }

    @Test("对端独有 → 只记账、不动手（绝不跨端删除；两方向一致）")
    func remoteOnlyIgnored() {
        let local = manifest([("Album/keep.flac", hashA)])
        let remote = manifest([
            ("Album/keep.flac", hashA),
            ("Imported/device-only.flac", hashB),
            ("Imported/device-only-2.flac", nil),
        ])

        for direction in [SyncTransferDirection.upload, .download] {
            let diff = SyncCollectionDiffPlanner.plan(
                expected: ["Album/keep.flac"], local: local, remote: remote, direction: direction
            )
            #expect(diff.unchanged == ["Album/keep.flac"])
            #expect(diff.toPush.isEmpty)
            #expect(diff.toPull.isEmpty)
            #expect(diff.remoteOnlyIgnored == ["Imported/device-only-2.flac", "Imported/device-only.flac"])
            #expect(diff.transferCount == 0)
        }
    }

    @Test("期望路径两侧都没有实体 → missingBoth（不伪造、不动手）")
    func missingBoth() {
        let diff = SyncCollectionDiffPlanner.plan(
            expected: ["Album/ghost.flac"], local: [], remote: [], direction: .upload
        )
        #expect(diff.missingBoth == ["Album/ghost.flac"])
        #expect(diff.transferCount == 0)
    }

    @Test("差集输出升序（确定性，便于比对与日志）")
    func deterministicOrder() {
        // 夹具自查（2026-09-28）：三首不同的歌原先共用 `hashA`（含跨路径内容身份的活值）；
        // 改用三个独立指纹（本用例只锁升序，断言文本不变）。
        let local = manifest([("Album/c.flac", hashPush), ("Album/a.flac", hashA), ("Album/b.flac", hashB)])
        let diff = SyncCollectionDiffPlanner.plan(
            expected: ["Album/c.flac", "Album/a.flac", "Album/b.flac"],
            local: local,
            remote: [],
            direction: .upload
        )
        #expect(diff.toPush == ["Album/a.flac", "Album/b.flac", "Album/c.flac"])
    }

    // MARK: 跨路径内容身份（2026-09-28）——锁「对端/本端已持有同内容 → 不计入待传输」

    @Test("★内容身份（upload）：对端已持有同内容（路径不同）→ 不进 toPush、计 alreadyPresent")
    func uploadSkipsContentAlreadyHeldByPeer() {
        // 实况形态：同一首歌两端命名顺序不同（`歌手 - 标题` vs `标题-歌手`），内容逐字节相同。
        let local = manifest([("歌手 - 标题.mp3", hashA)])
        let remote = manifest([("标题-歌手.mp3", hashA)])

        let diff = SyncCollectionDiffPlanner.plan(
            expected: ["歌手 - 标题.mp3"], local: local, remote: remote, direction: .upload
        )

        #expect(diff.toPush.isEmpty, "对端已有同内容 → 不推（否则『本轮要传 N 首』虚高）")
        #expect(diff.alreadyPresent == ["歌手 - 标题.mp3"], "独立桶，且不并入 unchanged")
        #expect(diff.unchanged.isEmpty, "unchanged 语义不变（同路径同内容）")
        #expect(diff.transferCount == 0)
    }

    @Test("★内容身份（download）对称：本端已持有同内容（路径不同）→ 不进 toPull、计 alreadyPresent")
    func downloadSkipsContentAlreadyHeldLocally() {
        let local = manifest([("标题-歌手.mp3", hashA)])
        let remote = manifest([("歌手 - 标题.mp3", hashA)])

        let diff = SyncCollectionDiffPlanner.plan(
            expected: ["歌手 - 标题.mp3"], local: local, remote: remote, direction: .download
        )

        #expect(diff.toPull.isEmpty, "本端已有同内容 → 不拉（不重复落盘）")
        #expect(diff.alreadyPresent == ["歌手 - 标题.mp3"])
        #expect(diff.unchanged.isEmpty)
        #expect(diff.transferCount == 0)
    }

    @Test("★计划计数不虚高：待传输数 == 实际需要传的条目数（已持有/一致都不计）")
    func plannedTransferCountMatchesActual() {
        // 三首本端曲目：a 对端已有同内容（另一路径）、b 对端确实缺、c 两侧同路径同内容。
        let local = manifest([("Album/a.flac", hashA), ("Album/b.flac", hashB), ("Album/c.flac", hashPush)])
        let remote = manifest([("Other/a-别名.flac", hashA), ("Album/c.flac", hashPush)])
        let expected = ["Album/a.flac", "Album/b.flac", "Album/c.flac"]

        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected, local: local, remote: remote, direction: .upload
        )

        #expect(diff.toPush == ["Album/b.flac"])
        #expect(diff.alreadyPresent == ["Album/a.flac"])
        #expect(diff.unchanged == ["Album/c.flac"])
        #expect(diff.remoteOnlyIgnored == ["Other/a-别名.flac"])
        #expect(diff.transferCount == 1, "实际待传输 = 1（不是选择集 3）→ 上屏总数不再虚高")
        #expect(diff.toPush.count + diff.toPull.count == diff.transferCount, "计划数 = 待传输数")
        #expect(
            diff.toPush.count + diff.toPull.count + diff.alreadyPresent.count
                + diff.unchanged.count + diff.missingBoth.count
                + diff.peerOnlySkipped.count + diff.localOnlySkipped.count
                + diff.conflictingKept.count == expected.count,
            "账目守恒：每条期望项恰好落一个桶"
        )
    }

    @Test("保守侧：指纹 nil / 空串不参与内容身份判定 → 照旧进待传输集（不静默不传）")
    func conservativeWhenFingerprintMissingOrEmpty() {
        // upload：本端未指纹 → 不得判「对端已有」→ 照推
        #expect(
            SyncCollectionDiffPlanner
                .plan(
                    expected: ["Album/new.flac"],
                    local: manifest([("Album/new.flac", nil)]),
                    remote: manifest([("Album/other.flac", hashA)]),
                    direction: .upload
                )
                .toPush == ["Album/new.flac"]
        )
        // upload：对端空串指纹不入索引 → 照推
        let uploadEmptyPeer = SyncCollectionDiffPlanner.plan(
            expected: ["Album/new.flac"],
            local: manifest([("Album/new.flac", hashA)]),
            remote: manifest([("Album/other.flac", "")]),
            direction: .upload
        )
        #expect(uploadEmptyPeer.toPush == ["Album/new.flac"])
        #expect(uploadEmptyPeer.alreadyPresent.isEmpty)

        // download：本端未指纹 → 不得判「本端已有」→ 照拉
        let downloadUnknownLocal = SyncCollectionDiffPlanner.plan(
            expected: ["Album/new.flac"],
            local: manifest([("Album/other.flac", nil)]),
            remote: manifest([("Album/new.flac", hashA)]),
            direction: .download
        )
        #expect(downloadUnknownLocal.toPull == ["Album/new.flac"])
        #expect(downloadUnknownLocal.alreadyPresent.isEmpty)
        // download：本端空串指纹不入索引 → 照拉
        let downloadEmptyLocal = SyncCollectionDiffPlanner.plan(
            expected: ["Album/new.flac"],
            local: manifest([("Album/other.flac", "")]),
            remote: manifest([("Album/new.flac", hashA)]),
            direction: .download
        )
        #expect(downloadEmptyLocal.toPull == ["Album/new.flac"])
        #expect(downloadEmptyLocal.alreadyPresent.isEmpty)
    }

    @Test("歌词命名空间不参与跨路径内容身份（同字节不同 wire 路径 → 照传，否则丢歌词）")
    func lyricsNamespaceNotCrossPathMatched() {
        let localLyrics = manifest([("@lyrics/\(hashA).json", hashPush)])
        let remoteLyrics = manifest([("@lyrics/\(hashB).json", hashPush)])

        // download：本端已有另一 wire 路径的同字节歌词 → 不得判「已有」→ 照拉
        let download = SyncCollectionDiffPlanner.plan(
            expected: ["@lyrics/\(hashB).json"],
            local: localLyrics,
            remote: remoteLyrics,
            direction: .download
        )
        #expect(download.toPull == ["@lyrics/\(hashB).json"])
        #expect(download.alreadyPresent.isEmpty)

        // upload 对称：对端已有另一 wire 路径的同字节歌词 → 照推
        let upload = SyncCollectionDiffPlanner.plan(
            expected: ["@lyrics/\(hashA).json"],
            local: localLyrics,
            remote: remoteLyrics,
            direction: .upload
        )
        #expect(upload.toPush == ["@lyrics/\(hashA).json"])
        #expect(upload.alreadyPresent.isEmpty)
    }
}
