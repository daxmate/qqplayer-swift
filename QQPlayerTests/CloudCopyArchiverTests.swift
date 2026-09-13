//
//  CloudCopyArchiverTests.swift
//  QQPlayerTests
//
//  审计 🔵-10 回归：iCloud 副本归档（SandboxMusicMigrator.cleanupCloudCopies 的落盘动作）。
//
//  修复前执行器迁移完成后直接 `FileManager.removeItem` 删掉 iCloud 原件
//  （判据仅 content_hash 相等，无备份、不可逆）；修复后改为移动到
//  `<cloudRoot>/_migrated-backup/<相对路径>`，原文件内容仍在、可人工恢复。
//
//  CloudCopyArchiver 是平台无关的纯文件操作类型（带 FileManager 注入），
//  因此可在 iOS 测试 target 直接驱动真实文件系统验证。
//

import Foundation
import Testing

@testable import QQPlayer

struct CloudCopyArchiverTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("归档 = 移动到 _migrated-backup：原位置让出，内容仍在（可恢复）")
    func archiveMovesFileIntoBackup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("sub").appendingPathComponent("曲.flac")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio-bytes".utf8).write(to: source)

        let archived = try #require(try CloudCopyArchiver.archive(relativePath: "sub/曲.flac", cloudRoot: root))

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(archived.path.hasSuffix("_migrated-backup/sub/曲.flac"))
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(try Data(contentsOf: archived) == Data("audio-bytes".utf8))
    }

    @Test("备份目标已存在 → 返回 nil，不动原件（不覆盖、不删除）")
    func archiveSkipsWhenBackupAlreadyExists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("a.flac")
        try Data("original".utf8).write(to: source)

        _ = try CloudCopyArchiver.archive(relativePath: "a.flac", cloudRoot: root)
        // 原件再放回原位置（模拟同名文件重新出现），再次归档应跳过
        try Data("second".utf8).write(to: source)

        let second = try CloudCopyArchiver.archive(relativePath: "a.flac", cloudRoot: root)

        #expect(second == nil)
        #expect(FileManager.default.fileExists(atPath: source.path)) // 原件保留
        #expect(try Data(contentsOf: source) == Data("second".utf8))
    }

    @Test("源文件不存在 → 返回 nil，不抛错")
    func archiveMissingSourceReturnsNil() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archived = try CloudCopyArchiver.archive(relativePath: "nope.flac", cloudRoot: root)

        #expect(archived == nil)
    }

    @Test("备份根就在云端容器内（同卷 rename，不产生双份本地占用）")
    func backupRootLivesUnderCloudRoot() {
        let root = URL(fileURLWithPath: "/cloud/Documents", isDirectory: true)
        #expect(CloudCopyArchiver.backupRoot(for: root).path == "/cloud/Documents/_migrated-backup")
    }
}
