//
//  TrackFileRenameServiceContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-09-28「曲库命名对齐」批 A，fail-closed + 自证）。
//
//  三条契约：
//  1. **按标签改名只有一个入口** —— 全仓 `moveItem(` / `renameItem(` / `.rename(`
//     调用点只允许出现在冻结基线白名单里（唯一标签改名入口 = `TrackFileRenameService`，
//     其余为既有非标签语义落点）。新增文件带这类调用而不登记 → 红。
//  2. **规范化入口不得引用 `TagWriterService`** —— 改名入口只用 `FileManager.moveItem`
//     保字节；引用 `TagWriterService` 会经其 `writeMetadata` 重写标签 ⇒ 改
//     `content_hash`（跨端身份键）。剥注释/字符串后判定。
//  3. **备份/台账目录被扫描排除** —— 行为断言：音频扫描器不收录 `*-rename-backup`
//     目录里的文件（否则备份会被重新入库）。
//
//  口径：先剥注释与字符串字面量再匹配（组合根装配契约 / MacLibraryRoot 单源契约同款；
//  不剥的话注释里写一句就骗绿）。
//

import Foundation
import Testing

@testable import QQPlayer

private enum TrackFileRenameContract {
    /// 仓库根（`#filePath` 上两级 = QQPlayerTests/ → 仓库根）。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"

    /// 文件系统改名/搬迁调用的标记（代码域内匹配）。
    static let renameCallMarkers = ["moveItem(", "renameItem(", ".rename("]

    /// 冻结基线（2026-09-28）：当前全仓 `moveItem(` / `renameItem(` / `.rename(`
    /// 调用点的**全量**登记。唯一「按标签规范化改名」入口 = `TrackFileRenameService.swift`；
    /// 其余均为既有非标签语义落点（iCloud/沙盒搬迁、状态文件、歌词文件、下载落盘、
    /// 同步落盘、布局迁移、标签写入、身份迁移等）。
    ///
    /// 契约语义 = **未登记新增即红**：新增任何带上述调用的文件都要显式登记到这里，
    /// 强迫「这是不是又一个按标签改名的第二入口」在提交时被审一遍。
    static let baselineWhitelist: Set<String> = [
        "QQPlayer/Models/WidgetData.swift",
        "QQPlayer/Services/AlignedLyricsStore.swift",
        "QQPlayer/Services/ArtworkCache.swift",
        "QQPlayer/Services/DatabaseHiddenLayoutRelocation.swift",
        "QQPlayer/Services/DatabaseManager.swift",
        "QQPlayer/Services/DiscogsAPI.swift",
        "QQPlayer/Services/HybridMusicAPI.swift",
        "QQPlayer/Services/LibraryIndexer+RenameNormalize.swift",
        "QQPlayer/Services/LibraryIndexer+SharedImport.swift",
        "QQPlayer/Services/LibraryLayoutMigrationV2Migrator.swift",
        "QQPlayer/Services/LibraryLayoutMigrator.swift",
        "QQPlayer/Services/LogRotation.swift",
        "QQPlayer/Services/LyricsManager.swift",
        "QQPlayer/Services/LyricsSearch.swift",
        "QQPlayer/Services/LyricsSearchCache.swift",
        "QQPlayer/Services/MacOnlineDownloadService.swift",
        "QQPlayer/Services/NeteaseOnlineClient+Transport.swift",
        "QQPlayer/Services/QuarkCookieStore.swift",
        "QQPlayer/Services/ReclaimRestoreService.swift",
        "QQPlayer/Services/SandboxMigration.swift",
        "QQPlayer/Services/StateManager.swift",
        "QQPlayer/Services/TagWriterService.swift",
        "QQPlayer/Services/TrackDeletionService.swift",
        "QQPlayer/Services/TrackFileRenameService.swift",
        "QQPlayer/Services/TrackIdentityMigration.swift",
        "QQPlayer/Sync/SyncFileReceiver+StateMachine.swift",
        "QQPlayer/Sync/SyncLibraryPassiveHost.swift",
        "QQPlayer/Sync/SyncLibraryPullController.swift",
        "QQPlayer/Sync/SyncLibraryPushModels.swift",
        "QQPlayer/Sync/SyncLyricsReceiver.swift",
        "QQPlayer/Views/Playlists/PlaylistDetailScreen+CustomCover.swift",
    ]

    /// 「规范化入口」文件：这些文件引用 `TagWriterService` = 违约。
    static let namingEntryFiles: [String] = [
        "QQPlayer/Services/LibraryFileNaming.swift",
        "QQPlayer/Services/TrackFileRenameService.swift",
        "QQPlayer/Services/LibraryIndexer+RenameNormalize.swift",
    ]

    static let forbiddenMarker = "TagWriterService"

    /// 剥掉注释（行 / 块）与字符串字面量，只留代码。
    static func codeOnly(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        let end = source.endIndex
        var inString = false
        var inBlockComment = false
        var inLineComment = false
        while i < end {
            let c = source[i]
            let nextIndex = source.index(after: i)
            let next: Character = nextIndex < end ? source[nextIndex] : "\0"
            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next == "/" {
                    inBlockComment = false
                    i = nextIndex
                }
            } else if inString {
                if c == "\\" {
                    i = nextIndex
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "/", next == "/" {
                inLineComment = true
                i = nextIndex
            } else if c == "/", next == "*" {
                inBlockComment = true
                i = nextIndex
            } else if c == "\"" {
                inString = true
            } else {
                out.append(c)
            }
            i = source.index(after: i)
        }
        return out
    }

    static func swiftFiles() throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 白名单外带改名/搬迁调用的文件（升序）。
    static func renameCallOffenders() throws -> [String] {
        let prefix = repositoryRoot.path + "/"
        var offenders: [String] = []
        for url in try swiftFiles() {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = codeOnly(source)
            let hasCall = renameCallMarkers.contains { code.contains($0) }
            if hasCall, !baselineWhitelist.contains(relative) {
                offenders.append(relative)
            }
        }
        return offenders.sorted()
    }

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case fileUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举（fail-closed）：\(path)"
            case .fileUnreadable(let path):
                return "契约测试无法读取（fail-closed）：\(path)"
            }
        }
    }
}

struct TrackFileRenameServiceContractTests {
    // MARK: - 契约 1：按标签改名只有一个入口

    @Test("白名单外出现 moveItem/rename 调用点即红（唯一改名入口 = TrackFileRenameService）")
    func renameCallHasSingleEntry() throws {
        let offenders = try TrackFileRenameContract.renameCallOffenders()
        #expect(
            offenders.isEmpty,
            "白名单外出现改名/搬迁调用点：\(offenders)（应改走 TrackFileRenameService，或显式登记基线）"
        )
    }

    // MARK: - 契约 2：规范化入口不得引用 TagWriterService

    @Test("规范化入口文件不得引用 TagWriterService（剥注释/字符串后判定）")
    func namingEntryDoesNotReferenceTagWriter() throws {
        let root = TrackFileRenameContract.repositoryRoot
        for relative in TrackFileRenameContract.namingEntryFiles {
            let url = root.appendingPathComponent(relative)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw TrackFileRenameContract.ContractError.fileUnreadable(relative)
            }
            let code = TrackFileRenameContract.codeOnly(source)
            #expect(
                !code.contains(TrackFileRenameContract.forbiddenMarker),
                "\(relative) 引用了 TagWriterService（会重写标签字节 → 改 content_hash）"
            )
        }
    }

    // MARK: - 契约 3：备份/台账目录被扫描排除

    @Test("音频扫描器不收录 rename-backup 目录里的文件（备份不会被重新入库）")
    func backupDirectoriesExcludedFromScan() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("RenameBackupScanContract-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("song.mp3"))

        // 备份根（带前导点，隐藏）
        let dotted = root.appendingPathComponent(LibraryFileNaming.renameBackupDirectoryName, isDirectory: true)
        try fm.createDirectory(at: dotted, withIntermediateDirectories: true)
        try Data([2]).write(to: dotted.appendingPathComponent("archived.mp3"))
        // 无前导点的 `-rename-backup` 形态（显式排除的判据覆盖面）
        let dashed = root.appendingPathComponent("foo-rename-backup", isDirectory: true)
        try fm.createDirectory(at: dashed, withIntermediateDirectories: true)
        try Data([3]).write(to: dashed.appendingPathComponent("other.mp3"))

        let recursive = try MusicDirectoryScanner.audioFilesSync(
            in: root,
            enabledExtensions: LibraryAudioFormats.allSupported,
            recursive: true
        )
        #expect(Set(recursive.map(\.lastPathComponent)) == ["song.mp3"])

        let singleLevel = try MusicDirectoryScanner.audioFilesSync(
            in: root,
            enabledExtensions: LibraryAudioFormats.allSupported,
            recursive: false
        )
        #expect(Set(singleLevel.map(\.lastPathComponent)) == ["song.mp3"])
    }

    // MARK: - 自证：扫描器剥注释/字符串

    @Test("扫描器自证：代码里的调用检出；注释/字符串里的不算")
    func scannerSelfProof() {
        let codeOnly = TrackFileRenameContract.codeOnly
        #expect(codeOnly("let x = fm.moveItem(at: a, to: b)").contains("moveItem("))
        #expect(!codeOnly("// fm.moveItem(at: a, to: b) 旧写法").contains("moveItem("))
        #expect(!codeOnly("/* fm.moveItem(at: a, to: b) */").contains("moveItem("))
        #expect(!codeOnly("let s = \"moveItem(at:to:)\"").contains("moveItem("))
        #expect(!codeOnly("// TagWriterService 不该出现").contains(TrackFileRenameContract.forbiddenMarker))
        #expect(codeOnly("let s = \"a\\\"b\"; fm.moveItem(at: a, to: b)").contains("moveItem("))
    }
}
