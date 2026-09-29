//
//  ReclaimAreaTests.swift
//  QQPlayerTests
//
//  回收区（生产区 `<曲库根>/.Trash`）枚举 / 恢复 / 彻底删除的纯逻辑单测
//  （2026-09-29 回收区管理批）。
//
//  覆盖：三区→单区的枚举形状（只读、排序稳定、大小/时间/可恢复判定）、恢复命名
//  （规范名 + 标签读不到回退现有名）、同名冲突保守避让、恢复核心的移动 + 收录 seam +
//  失败回搬 + 台账、彻底删除 / 清空的计数与释放字节。
//
//  不依赖 DB / 模拟器资源：恢复的收录步骤用 **测试 seam**（`importStep` 闭包）注入，
//  生产入口（`indexer:` 重载）由 `ReclaimAreaShapeContractTests` 静态钉住。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("回收区（生产区）逻辑")
struct ReclaimAreaTests {
    // MARK: - 夹具

    /// 每个用例自己的临时目录（不共享任何可变静态——Swift Testing 套件间并行）。
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 曲库根（`<root>/library`）+ 已建好的回收区目录（`<library>/.Trash`）。
    private func makeLibrary(withReclaimArea: Bool = true) throws -> (root: URL, library: URL) {
        let root = try makeRoot()
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        if withReclaimArea {
            try FileManager.default.createDirectory(
                at: DeleteReclaimArea.url(inLibraryRoot: library),
                withIntermediateDirectories: true
            )
        }
        return (root, library)
    }

    @discardableResult
    private func writeFile(_ name: String, in directory: URL, bytes: Int = 32) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// `AudioMetadata` 的最小工厂（只填本批用到的 artist / title，其余 nil）。
    private func metadata(artist: String?, title: String?) -> AudioMetadata {
        AudioMetadata(
            title: title,
            artist: artist,
            album: nil,
            albumArtist: nil,
            genre: nil,
            trackNumber: nil,
            discNumber: nil,
            year: nil,
            durationMs: nil,
            sampleRate: nil,
            bitDepth: nil,
            channels: nil,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: false
        )
    }

    private func entry(for url: URL, bytes: Int64 = 0) -> ReclaimAreaEntry {
        ReclaimAreaEntry(url: url, byteSize: bytes, modificationDate: nil)
    }

    // MARK: - 枚举

    @Test("枚举：只列常规文件、排序稳定、缺失目录返回空")
    func catalogEnumeratesRegularFilesSorted() throws {
        let (_, library) = try makeLibrary()
        let area = DeleteReclaimArea.url(inLibraryRoot: library)
        try writeFile("bbb.mp3", in: area, bytes: 10)
        try writeFile("aaa.mp3", in: area, bytes: 20)
        try writeFile("ccc.txt", in: area, bytes: 5)
        // 子目录不算条目（回收区是平铺的）
        try FileManager.default.createDirectory(
            at: area.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )

        let entries = ReclaimAreaCatalog.entries(libraryRoot: library)
        #expect(entries.map(\.existingName) == ["aaa.mp3", "bbb.mp3", "ccc.txt"])
        #expect(entries.filter(\.isRestorable).count == 2)
        #expect(entries.filter { !$0.isRestorable }.count == 1)
        #expect(ReclaimAreaCatalog.totalByteSize(of: entries) > 0)

        // 回收区不存在 → 空数组（不抛错）
        let withoutArea = try makeLibrary(withReclaimArea: false)
        #expect(ReclaimAreaCatalog.entries(libraryRoot: withoutArea.library).isEmpty)
    }

    @Test("枚举：回收区派生自 DeleteReclaimArea（曲库根内），不是 Documents 根")
    func reclaimDirectoryDerivesFromLibraryRoot() throws {
        let (_, library) = try makeLibrary()
        let expected = library.appendingPathComponent(".Trash", isDirectory: true)
        #expect(ReclaimAreaCatalog.directoryURL(libraryRoot: library).standardizedFileURL.path
            == expected.standardizedFileURL.path)
    }

    // MARK: - 恢复命名

    @Test("恢复命名：标签可读 → 规范名（落库简体口径）")
    func desiredNameUsesCanonicalName() {
        let name = ReclaimRestoreService.desiredFileName(
            existingName: "d41d8cd9.mp3",
            metadata: metadata(artist: "周华健", title: "愛相隨")
        )
        #expect(name == "周华健 - 爱相随.mp3", "繁体标签应经落库口径归一为简体")
    }

    @Test("恢复命名：标签读不到 / 都为空 → 回退现有名（绝不丢文件）")
    func desiredNameFallsBackToExistingName() {
        #expect(
            ReclaimRestoreService.desiredFileName(existingName: "abc123.mp3", metadata: nil)
                == "abc123.mp3"
        )
        #expect(
            ReclaimRestoreService.desiredFileName(
                existingName: "abc123.flac",
                metadata: metadata(artist: nil, title: nil)
            ) == "abc123.flac"
        )
        // 无扩展名 → 渲染不了规范名 → 回退
        #expect(
            ReclaimRestoreService.desiredFileName(
                existingName: "abc123",
                metadata: metadata(artist: "A", title: "T")
            ) == "abc123"
        )
    }

    @Test("恢复目标：同名冲突保守避让（绝不覆盖）")
    func destinationAvoidsSameNameCollision() throws {
        let (_, library) = try makeLibrary()
        try writeFile("A - T.mp3", in: library, bytes: 8)
        let destination = ReclaimRestoreService.destinationURL(in: library, desiredName: "A - T.mp3")
        #expect(destination.lastPathComponent == "A - T 2.mp3")
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    // MARK: - 恢复核心

    @MainActor
    @Test("恢复：搬回曲库 + 收录（seam）+ 台账")
    func restoreMovesFileAndImports() async throws {
        let (_, library) = try makeLibrary()
        let area = DeleteReclaimArea.url(inLibraryRoot: library)
        let source = try writeFile("hash1.mp3", in: area, bytes: 64)

        var importedURL: URL?
        let outcome = await ReclaimRestoreService.restore(
            entry: entry(for: source, bytes: 64),
            libraryRoot: library,
            timestamp: Date(timeIntervalSince1970: 0)
        ) { url in
            importedURL = url
            return .imported
        }

        guard case .restored(let restoredURL, let importOutcome) = outcome else {
            Issue.record("期望 .restored，实际 \(outcome)")
            return
        }
        #expect(importOutcome == .imported)
        #expect(importedURL == restoredURL, "收录必须作用在搬回后的目标 URL 上")
        #expect(FileManager.default.fileExists(atPath: source.path) == false, "回收区源文件应已搬走")
        #expect(FileManager.default.fileExists(atPath: restoredURL.path))
        #expect(LibraryRoot.relativePath(of: restoredURL, baseDirectory: library) != nil)

        // 台账：备份根下的恢复台账有一行（含源路径与恢复后的相对路径）
        let log = TrackFileRenameService.backupRoot(forLibraryRoot: library)
            .appendingPathComponent(LibraryFileNaming.reclaimRestoreLogFileName)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("restored"))
        #expect(text.contains(source.path))
    }

    @MainActor
    @Test("恢复：收录失败 → 文件原样搬回回收区（不留悬空态），不写台账")
    func restoreRollsBackWhenImportFails() async throws {
        let (_, library) = try makeLibrary()
        let area = DeleteReclaimArea.url(inLibraryRoot: library)
        let source = try writeFile("hash2.mp3", in: area, bytes: 16)

        let outcome = await ReclaimRestoreService.restore(
            entry: entry(for: source, bytes: 16),
            libraryRoot: library
        ) { _ in
            .failed(.processing)
        }

        guard case .failed = outcome else {
            Issue.record("期望 .failed，实际 \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: source.path), "失败后文件必须回到回收区")
        #expect(ReclaimAreaCatalog.entries(libraryRoot: library).count == 1)
        let log = TrackFileRenameService.backupRoot(forLibraryRoot: library)
            .appendingPathComponent(LibraryFileNaming.reclaimRestoreLogFileName)
        #expect(FileManager.default.fileExists(atPath: log.path) == false, "失败不应写台账")
    }

    @MainActor
    @Test("恢复：文件已不在 / 非音频 → skipped（不猜、不硬搬）")
    func restoreSkipsMissingAndNonAudio() async throws {
        let (_, library) = try makeLibrary()
        let area = DeleteReclaimArea.url(inLibraryRoot: library)
        let missing = area.appendingPathComponent("gone.mp3", isDirectory: false)
        let nonAudio = try writeFile("notes.txt", in: area, bytes: 4)

        var importCalls = 0
        let missingOutcome = await ReclaimRestoreService.restore(
            entry: entry(for: missing),
            libraryRoot: library
        ) { _ in
            importCalls += 1
            return .imported
        }
        let nonAudioOutcome = await ReclaimRestoreService.restore(
            entry: entry(for: nonAudio),
            libraryRoot: library
        ) { _ in
            importCalls += 1
            return .imported
        }

        #expect(missingOutcome == .skipped(reason: .fileMissing))
        #expect(nonAudioOutcome == .skipped(reason: .notRestorable))
        #expect(importCalls == 0)
        #expect(FileManager.default.fileExists(atPath: nonAudio.path), "非音频条目不得被动过")
    }

    // MARK: - 彻底删除 / 清空

    @Test("彻底删除：选中条目删除并计数，缺失条目跳过，其余完好")
    func purgeSelectedReportsCounts() throws {
        let (_, library) = try makeLibrary()
        let area = DeleteReclaimArea.url(inLibraryRoot: library)
        let first = try writeFile("a.mp3", in: area, bytes: 100)
        let keep = try writeFile("b.mp3", in: area, bytes: 200)
        let missing = area.appendingPathComponent("c.mp3", isDirectory: false)

        let summary = ReclaimPurgeService.purge([
            entry(for: first, bytes: 100),
            entry(for: missing, bytes: 50),
        ])

        #expect(summary.deleted == 1)
        #expect(summary.freedBytes == 100)
        #expect(summary.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test("清空：删光整区并汇报释放字节")
    func purgeAllEmptiesArea() throws {
        let (_, library) = try makeLibrary()
        let area = DeleteReclaimArea.url(inLibraryRoot: library)
        try writeFile("a.mp3", in: area, bytes: 10)
        try writeFile("b.flac", in: area, bytes: 20)

        // byteSize 口径 = **已分配大小（块对齐）**（见 `ReclaimAreaCatalog.entries`：
        // `totalFileAllocatedSize` 优先，回落逻辑大小）⇒ 不写死字节字面量：
        // 夹具只有 10/20 逻辑字节，块对齐后必然不是 30。期望值取 **purge 之前**
        // 由目录自己算出的总量（既有唯一入口 `ReclaimAreaCatalog`）。
        let expectedFreed = ReclaimAreaCatalog.totalByteSize(
            of: ReclaimAreaCatalog.entries(libraryRoot: library)
        )
        #expect(expectedFreed > 0, "夹具未就位 → 下面的相等断言会失去判别力")

        let summary = ReclaimPurgeService.purgeAll(libraryRoot: library)
        #expect(summary.deleted == 2)
        #expect(summary.freedBytes == expectedFreed)
        #expect(ReclaimAreaCatalog.entries(libraryRoot: library).isEmpty)
    }

    @Test("占用文案：非空且随大小变化")
    func formattedSizeIsHumanReadable() {
        #expect(!ReclaimAreaCatalog.formattedSize(0).isEmpty)
        #expect(ReclaimAreaCatalog.formattedSize(1_500_000) != ReclaimAreaCatalog.formattedSize(1_500))
    }
}
