//
//  LibraryIndexerMetadataRefreshTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  P1（2026-09-22）「重装后首启永不自愈」的回归。
//
//  背景：`LibraryIndexer.needsMetadataRefresh` 过去只看指纹（mtime / size）。iOS 重装换数据
//  容器 UUID 后全库 `track.path` 悬空，而文件本身一个字节没变 ⇒ 主扫对每个文件都判定
//  「元数据最新」整批跳过（真机 266 条 `⏭️ Track metadata is current`），path 永远停在旧
//  容器前缀；播放取 `URL(fileURLWithPath:)` → `fileExists` 失败 → `PlayerError.fileNotFound`
//  → 红条 `playback_error_generic`。只能杀 App 重开（行被清空后整库重新入库）才恢复。
//
//  新分支：**指纹未变 + 入库 path 已不存在** → 判定需要处理，且实现路径是**只回写 path**
//  （不重解析、不动其余元数据）。
//
//  纯判定级用例：无音频文件解析、无扫描、无模拟器交互。
//

import Foundation
import Testing

@testable import QQPlayer

@MainActor
struct LibraryIndexerMetadataRefreshTests {
    /// 旧数据容器下的悬空 path（真机取证里的前缀 D1917C90-…）。
    private var staleContainerPath: String {
        "/private/var/mobile/Containers/Data/Application/D1917C90-5506-4FD0-ACD9-636334DA54C1/Documents/song.flac"
    }

    /// 在临时目录下造一个**真实存在**的文件（充当「现容器里的那份」）。
    private func makeExistingFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-metadata-refresh-\(UUID().uuidString)/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("song.flac")
        try Data("x".utf8).write(to: file)
        return file
    }

    private func makeTrack(
        path: String,
        modificationDate: Int64? = 1000,
        fileSize: Int64? = 42
    ) -> Track {
        Track(
            stableId: "sid",
            title: "Song",
            durationMs: 213_000,
            path: path,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
    }

    private var unchangedFingerprint: FileFingerprint {
        FileFingerprint(modificationDate: 1000, fileSize: 42)
    }

    @Test("P1：指纹未变 + 入库 path 已失效 → 判定需要处理，且实现路径 = 只回写 path（不重解析）")
    func staleStoredPathWithUnchangedFingerprintNeedsPathResync() throws {
        let existingFile = try makeExistingFile()
        let track = makeTrack(path: staleContainerPath)
        let indexer = LibraryIndexer()

        let needsRefresh = indexer.needsMetadataRefresh(
            track,
            fingerprint: unchangedFingerprint,
            currentPath: existingFile.path
        )
        #expect(needsRefresh)

        let decision = indexer.metadataRefreshDecision(
            track,
            fingerprint: unchangedFingerprint,
            currentPath: existingFile.path
        )
        #expect(decision == .resyncPathOnly)

        // 唯一入口只是判定，不写库：回写由调用方走 migrateTrackForMovedFile
        let stale = indexer.staleStoredPath(track, currentPath: existingFile.path)
        #expect(stale == staleContainerPath)
    }

    @Test("对照：指纹未变 + 入库 path 就是当前 path → current（不给每次扫描加刷新）")
    func unchangedFingerprintAndLivePathSkips() throws {
        let existingFile = try makeExistingFile()
        let track = makeTrack(path: existingFile.path)
        let indexer = LibraryIndexer()

        let needsRefresh = indexer.needsMetadataRefresh(
            track,
            fingerprint: unchangedFingerprint,
            currentPath: existingFile.path
        )
        #expect(!needsRefresh)

        let decision = indexer.metadataRefreshDecision(
            track,
            fingerprint: unchangedFingerprint,
            currentPath: existingFile.path
        )
        #expect(decision == .current)
        #expect(indexer.staleStoredPath(track, currentPath: existingFile.path) == nil)
    }

    @Test("对照：指纹变了（mtime / size / 无指纹）→ reparse，不吃「只回写 path」的捷径")
    func changedFingerprintStillReparses() throws {
        let existingFile = try makeExistingFile()
        let indexer = LibraryIndexer()
        let track = makeTrack(path: staleContainerPath)

        let newerModification = FileFingerprint(modificationDate: 2000, fileSize: 42)
        #expect(indexer.metadataRefreshDecision(
            track,
            fingerprint: newerModification,
            currentPath: existingFile.path
        ) == .reparse)

        let resized = FileFingerprint(modificationDate: 1000, fileSize: 99)
        #expect(indexer.metadataRefreshDecision(
            track,
            fingerprint: resized,
            currentPath: existingFile.path
        ) == .reparse)

        // 旧库无指纹的行：照旧刷一次（既有语义）
        let legacyTrack = makeTrack(path: staleContainerPath, modificationDate: nil)
        #expect(indexer.metadataRefreshDecision(
            legacyTrack,
            fingerprint: unchangedFingerprint,
            currentPath: existingFile.path
        ) == .reparse)
    }

    @Test("对照：入库 path 与当前 path 不同但旧 path 仍在 → current（两份副本不算悬空）")
    func differingButLiveStoredPathSkips() throws {
        let existingFile = try makeExistingFile()
        let otherLiveFile = try makeExistingFile()
        let track = makeTrack(path: otherLiveFile.path)
        let indexer = LibraryIndexer()

        let decision = indexer.metadataRefreshDecision(
            track,
            fingerprint: unchangedFingerprint,
            currentPath: existingFile.path
        )
        #expect(decision == .current)
        #expect(indexer.staleStoredPath(track, currentPath: existingFile.path) == nil)
    }

    @Test("兼容入口：不带 currentPath 的旧签名只看指纹（既有调用点行为零变化）")
    func legacyOverloadIgnoresPathDimension() throws {
        let indexer = LibraryIndexer()
        let track = makeTrack(path: staleContainerPath)

        // 指纹未变：即使库内 path 悬空，旧签名也判 false（外部文件路径不受容器 UUID 影响）
        let needsRefresh = indexer.needsMetadataRefresh(track, fingerprint: unchangedFingerprint)
        #expect(!needsRefresh)

        // 旧实现的既有分支全部保留
        #expect(indexer.needsMetadataRefresh(
            makeTrack(path: staleContainerPath, modificationDate: nil),
            fingerprint: unchangedFingerprint
        ))
        #expect(indexer.needsMetadataRefresh(
            track,
            fingerprint: FileFingerprint(modificationDate: 2000, fileSize: 42)
        ))
        #expect(indexer.needsMetadataRefresh(
            track,
            fingerprint: FileFingerprint(modificationDate: 1000, fileSize: 99)
        ))
    }
}
