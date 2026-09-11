//
//  SyncTransferDirectionTests.swift
//  QQPlayerTests
//
//  T7（2026-09-11）「上传 / 下载」两个精确方向（纯逻辑，零 IO）：
//  - 选择集 → 对端请求集合（`SyncCollection`）的方向敏感映射
//  - 期望集合（对账基准）按方向取（`SyncExpectedPlanner`）
//  - 回归：「全库（`.all`）两个方向都不再空转」；download 能拉对端独有
//
//  fixture：纯值（ManifestEntry / SyncCollectionExpansion），不碰 DB 与文件系统。
//

import Foundation
import Testing

@testable import QQPlayer

private let hashA = String(repeating: "a", count: 64)
private let hashB = String(repeating: "b", count: 64)

private func entry(_ path: String, hash: String? = nil) -> ManifestEntry {
    ManifestEntry(relativePath: path, size: 10, mtimeMs: 0, contentHash: hash)
}

// MARK: - ① 选择集 → 对端请求集合

@Suite("T7 对端请求集合映射")
struct SyncRemoteRequestCollectionTests {
    @Test("upload：选择在本端执行 → 一律请求全量")
    func uploadRequestsAll() {
        #expect(SyncCollectionSelection.all.remoteRequestCollection(for: .upload) == .all)
        #expect(SyncCollectionSelection.playlists(["p1"]).remoteRequestCollection(for: .upload) == .all)
        #expect(SyncCollectionSelection.relativePaths(["Album/a.flac"]).remoteRequestCollection(for: .upload) == .all)
    }

    @Test("download：全库 → .all；歌单 → .playlists(规范化 id)；相对路径 → .all（对端表达不了路径过滤）")
    func downloadMapping() {
        #expect(SyncCollectionSelection.all.remoteRequestCollection(for: .download) == .all)
        #expect(
            SyncCollectionSelection.playlists([" p2 ", "p1", "p1"]).remoteRequestCollection(for: .download)
                == SyncCollection.playlists(["p1", "p2"])
        )
        #expect(
            SyncCollectionSelection.relativePaths(["Album/a.flac"]).remoteRequestCollection(for: .download) == .all
        )
    }

    @Test("download + 空/非法歌单 → 空集合（绝不把空选择集升成全库）")
    func downloadEmptyPlaylistsStaysEmpty() {
        let empty = SyncCollectionSelection.playlists([]).remoteRequestCollection(for: .download)
        #expect(empty.isEmptySelection)

        let invalid = SyncCollectionSelection.playlists(["bad/id", "  "]).remoteRequestCollection(for: .download)
        #expect(invalid.isEmptySelection)
    }
}

// MARK: - ② 期望集合（对账基准）按方向取

@Suite("T7 期望集合按方向取")
struct SyncExpectedPlannerTests {
    private let localManifest = [entry("Album/local-only.flac", hash: hashA), entry("Album/same.flac", hash: hashA)]
    private let remoteManifest = [entry("Album/same.flac", hash: hashA), entry("Album/peer-only.flac", hash: hashB)]

    @Test("来源映射：upload×.all=本端全量；upload×选择集=本端展开；download×.all/.playlists=对端清单；download×路径=选择集本身")
    func sourceMapping() {
        #expect(
            SyncExpectedPlanner.source(selection: .all, direction: .upload) == .localManifest
        )
        #expect(
            SyncExpectedPlanner.source(selection: .playlists(["p1"]), direction: .upload) == .expansion
        )
        #expect(
            SyncExpectedPlanner.source(selection: .relativePaths(["Album/a.flac"]), direction: .upload) == .expansion
        )
        #expect(SyncExpectedPlanner.source(selection: .all, direction: .download) == .remoteManifest)
        #expect(
            SyncExpectedPlanner.source(selection: .playlists(["p1"]), direction: .download) == .remoteManifest
        )
        #expect(
            SyncExpectedPlanner.source(selection: .relativePaths(["Album/a.flac"]), direction: .download)
                == .selectionPaths
        )
    }

    @Test("upload × .all：期望 = 本端全量（修「全库空转」）")
    func uploadAllUsesLocalManifest() {
        let expansion = SyncCollectionExpander.expand(selection: .all, facts: MemoryNoFacts())
        #expect(expansion.isLibraryWide)

        let expected = SyncExpectedPlanner.expected(
            selection: .all,
            direction: .upload,
            expansion: expansion,
            localManifest: localManifest,
            remoteManifest: remoteManifest
        )
        #expect(expected == ["Album/local-only.flac", "Album/same.flac"])

        // 回归：期望非空 → 全库 upload 真的产出计划（旧语义下差集恒空）
        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected, local: localManifest, remote: remoteManifest, direction: .upload
        )
        #expect(diff.toPush == ["Album/local-only.flac"])
        #expect(diff.transferCount == 1)
    }

    @Test("download × .all：期望 = 对端清单（对端独有 → 能拉回来）")
    func downloadAllUsesRemoteManifest() {
        let expected = SyncExpectedPlanner.expected(
            selection: .all,
            direction: .download,
            expansion: SyncCollectionExpander.expand(selection: .all, facts: MemoryNoFacts()),
            localManifest: localManifest,
            remoteManifest: remoteManifest
        )
        #expect(expected == ["Album/peer-only.flac", "Album/same.flac"])

        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected, local: localManifest, remote: remoteManifest, direction: .download
        )
        #expect(diff.toPull == ["Album/peer-only.flac"])
        #expect(diff.transferCount == 1)
    }

    @Test("download × .playlists：期望 = 对端清单（对端已按歌单收口）")
    func downloadPlaylistsUsesRemoteManifest() {
        let expansion = SyncCollectionExpander.expand(
            selection: .playlists(["p1"]),
            facts: MemoryPlaylistFacts()
        )
        let expected = SyncExpectedPlanner.expected(
            selection: .playlists(["p1"]),
            direction: .download,
            expansion: expansion,
            localManifest: localManifest,
            remoteManifest: remoteManifest
        )
        #expect(expected == ["Album/peer-only.flac", "Album/same.flac"])
    }

    @Test("download × .relativePaths：期望 = 选择集本身（本端展开查不到的歌正是要拉的）")
    func downloadRelativePathsUsesSelection() {
        // 本端展开对这两条都查不到 → expansion.entries 为空（unresolved），但仍要拉
        let expansion = SyncCollectionExpander.expand(
            selection: .relativePaths(["Album/peer-only.flac", "Album/same.flac"]),
            facts: MemoryNoFacts()
        )
        #expect(expansion.relativePaths.isEmpty)
        #expect(expansion.unresolvedCount == 2)

        let expected = SyncExpectedPlanner.expected(
            selection: .relativePaths(["Album/peer-only.flac", "Album/same.flac"]),
            direction: .download,
            expansion: expansion,
            localManifest: localManifest,
            remoteManifest: remoteManifest
        )
        #expect(expected == ["Album/peer-only.flac", "Album/same.flac"])

        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected, local: localManifest, remote: remoteManifest, direction: .download
        )
        #expect(diff.toPull == ["Album/peer-only.flac"])
        #expect(diff.unchanged == ["Album/same.flac"])
    }

    @Test("expected 去重 + 升序（确定性）")
    func expectedDeterministic() {
        let expected = SyncExpectedPlanner.expected(
            selection: .all,
            direction: .upload,
            expansion: SyncCollectionExpansion(),
            localManifest: [entry("Album/b.flac"), entry("Album/a.flac"), entry("Album/b.flac")],
            remoteManifest: []
        )
        #expect(expected == ["Album/a.flac", "Album/b.flac"])
    }
}

// MARK: - 测试用曲库事实桩

/// 什么都没有（显式路径一律 unresolved）。
private struct MemoryNoFacts: SyncCollectionFactsProviding {
    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? { nil }
    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? { nil }
    func hasLyrics(atWirePath wirePath: String) -> Bool { false }
}

/// 只有一个歌单 p1（对 `.playlists` 展开的用例）。
private struct MemoryPlaylistFacts: SyncCollectionFactsProviding {
    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]? {
        guard playlistID == "p1" else { return nil }
        return [SyncCollectionTrackFact(stableId: "s1", relativePath: "Album/same.flac", contentHash: hashA)]
    }

    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact? { nil }
    func hasLyrics(atWirePath wirePath: String) -> Bool { false }
}
