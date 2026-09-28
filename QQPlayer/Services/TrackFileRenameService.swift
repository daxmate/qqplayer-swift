//
//  TrackFileRenameService.swift
//  QQPlayer
//
//  **按标签规范化文件名的唯一入口**（执行 IO；2026-09-28「曲库命名对齐」批 A）。
//
//  与既有改名机制的边界（硬约束）：
//  - 本文件**绝不** import / 引用 `TagWriterService`，**绝不**调用任何标签写入 API。
//    原因：`TagWriterService.writeTags` 无条件 `copy → writeMetadata → replace`，
//    即使只改名也会重写标签字节 ⇒ 可能改变 `content_hash`（跨端身份键）⇒ 对账翻
//    `toFetch`、两端各留一份。本服务只用 `FileManager.moveItem`，音频字节零改动。
//  - 引用迁移**必须**走唯一入口 `DatabaseManager.moveTrack`（内部经
//    `TrackIdentityMigration`：favorite / playlist_item / track_artist / play_history
//    四表 + 书签 plist + 三个歌词目录 + `ArtworkMapping.plist`）。
//  - 命名渲染**必须**走 `LibraryFileNaming.canonicalFileName`（= `TagRenameLogic`），
//    本文件不重写模板/清洗/去重逻辑（禁第二实现）。
//
//  行为（严格按序，见 `rename(track:artist:title:libraryRoot:...)`）：
//  1. 渲染规范名；空值 → `.notRenameable`
//  2. 同名（NFC / 去扩展名）→ `.unchanged`（幂等）
//  3. 目标不存在 → 纯 `moveItem` + `moveTrack` 迁引用 → `.renamed`
//  4. 目标存在：两侧 `content_hash` 相同 → 去重（归档源文件 + 引用并入目标 + 删源行）
//     → `.deduped`；否则 `.skippedTargetConflict`（不改、不覆盖、**不加 `(2)`**）
//
//  改名台账：`<backupRoot>/rename-log.tsv`（可回退），每次 `.renamed` / `.deduped`
//  追加一行 `ISO8601\t旧相对路径\t新相对路径\tstableId`。
//

import Foundation

/// 单次「按标签规范化改名」的结果。
enum TrackFileRenameOutcome: Equatable {
    /// 已是规范名（NFC / 去扩展名同名）——幂等，无动作。
    case unchanged
    /// 目标不存在 → 已 rename（纯文件系统搬迁 + 引用迁移）。
    case renamed(from: String, to: String)
    /// 目标已存在且两侧内容一致 → 已去重（源文件归档到备份根，引用并入目标曲目）。
    case deduped(removedPath: String, backupPath: String)
    /// 目标已存在但内容不同 / 缺 hash → 保守跳过（不覆盖、不加 `(2)`）。
    case skippedTargetConflict(existingPath: String)
    /// 无法渲染规范名（artist/title 都空，或无扩展名）。
    case notRenameable(reason: String)
}

enum TrackFileRenameService {
    // MARK: - 路径约定

    /// 备份根：`<libraryRoot>/../.qqplayer-rename-backup`（**曲库之外**、App 沙盒内）。
    static func backupRoot(forLibraryRoot libraryRoot: URL) -> URL {
        libraryRoot
            .deletingLastPathComponent()
            .appendingPathComponent(LibraryFileNaming.renameBackupDirectoryName, isDirectory: true)
    }

    /// 改名台账 URL（备份根下）。
    static func renameLogURL(forLibraryRoot libraryRoot: URL) -> URL {
        backupRoot(forLibraryRoot: libraryRoot)
            .appendingPathComponent(LibraryFileNaming.renameLogFileName, isDirectory: false)
    }

    // MARK: - 唯一入口

    /// 按标签规范化某个曲目的文件名。**只改文件名，绝不触碰音频字节。**
    /// - Parameters:
    ///   - track: 曲库行（`path` 接受存储形态或绝对路径）
    ///   - artist: 文件**自身标签**的 artist（不是 DB 显示名——显示名做过繁简归一，会误判）
    ///   - title: 文件自身标签的 title
    ///   - libraryRoot: 曲库根（备份根 = 其父目录下的 `.qqplayer-rename-backup`）
    ///   - databaseManager: 库（引用迁移走 `moveTrack` 唯一入口）
    ///   - fileManager: Documents 根解析缝（默认 `.default` ⇒ 生产行为不变）
    ///   - timestamp: 备份子目录/台账时间戳注入缝（测试用；默认 `Date()`）
    /// - Returns: 结果枚举（穷尽）。
    @discardableResult
    static func rename(
        track: Track,
        artist: String?,
        title: String?,
        libraryRoot: URL,
        databaseManager: DatabaseManager,
        fileManager: FileManager = .default,
        timestamp: Date = Date()
    ) throws -> TrackFileRenameOutcome {
        let sourceURL = LibraryRoot.absoluteURL(forStoredPath: track.path, fileManager: fileManager)
        let ext = sourceURL.pathExtension
        guard !ext.isEmpty else { return .notRenameable(reason: "noExtension") }

        // 1. 渲染规范名（唯一实现 = TagRenameLogic，经 LibraryFileNaming 转发）
        guard let canonicalName = LibraryFileNaming.canonicalFileName(
            artist: artist,
            title: title,
            ext: "." + ext.lowercased()
        ) else {
            return .notRenameable(reason: "emptyArtistAndTitle")
        }

        let currentName = sourceURL.lastPathComponent
        // 2. 幂等：NFC 同名（含去扩展名）→ unchanged
        if LibraryFileNaming.isSameName(canonicalName, currentName)
            || LibraryFileNaming.isSameBaseName(canonicalName, currentName) {
            return .unchanged
        }

        let directory = sourceURL.deletingLastPathComponent()
        let targetURL = directory.appendingPathComponent(canonicalName, isDirectory: false)

        // 3. 目标不存在 → 纯文件系统搬迁 + 引用迁移（唯一入口 moveTrack）
        if !fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
            try databaseManager.moveTrack(
                from: sourceURL.path,
                to: targetURL.path,
                fileManager: fileManager
            )
            appendLog(
                RenameLogEntry(
                    event: "renamed",
                    sourceURL: sourceURL,
                    targetURL: targetURL,
                    libraryRoot: libraryRoot,
                    stableId: track.stableId,
                    timestamp: timestamp
                ),
                fileManager: fileManager
            )
            AppLog.info(.general, "📛 rename: \(currentName) → \(canonicalName)")
            return .renamed(from: sourceURL.path, to: targetURL.path)
        }

        // 4. 目标存在 → 判定内容是否同一首歌
        let sourceHash = track.contentHash ?? DatabaseManager.contentHashIfFilePresent(atPath: sourceURL.path)
        let targetHash = DatabaseManager.contentHashIfFilePresent(atPath: targetURL.path)
        if let sourceHash, let targetHash, sourceHash == targetHash {
            // 去重：源文件归档到备份根（不删）；引用并入目标曲目后删源行。
            // `moveTrack(from: 源, to: 目标)` 在目标行存在时走「合并引用 + 删旧行」分支，
            // 目标行不存在时则把源行改指目标路径——两种情形引用都不丢，故统一走它。
            let backupURL = try archiveToBackup(
                sourceURL: sourceURL,
                libraryRoot: libraryRoot,
                timestamp: timestamp,
                fileManager: fileManager
            )
            try databaseManager.moveTrack(
                from: sourceURL.path,
                to: targetURL.path,
                fileManager: fileManager
            )
            appendLog(
                RenameLogEntry(
                    event: "deduped",
                    sourceURL: sourceURL,
                    targetURL: targetURL,
                    libraryRoot: libraryRoot,
                    stableId: track.stableId,
                    timestamp: timestamp
                ),
                fileManager: fileManager
            )
            AppLog.info(.general, "📛 dedupe: \(currentName) 与 \(canonicalName) 内容一致，源文件已归档至备份")
            return .deduped(removedPath: sourceURL.path, backupPath: backupURL.path)
        }

        // 内容不同 / 缺 hash → 保守跳过（不改、不覆盖、不加 `(2)`）
        AppLog.info(.general, "📛 skip-conflict: \(currentName) 目标已存在且内容不同（保留两侧）")
        return .skippedTargetConflict(existingPath: targetURL.path)
    }

    // MARK: - 内部

    /// 把源文件移到 `<backupRoot>/<yyyyMMdd-HHmmss>/<原文件名>`（**不覆盖**：同名再避让）。
    /// - Returns: 归档目标 URL。
    private static func archiveToBackup(
        sourceURL: URL,
        libraryRoot: URL,
        timestamp: Date,
        fileManager: FileManager
    ) throws -> URL {
        let directory = backupRoot(forLibraryRoot: libraryRoot)
            .appendingPathComponent(Self.backupStamp(timestamp), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            var index = 2
            while fileManager.fileExists(atPath: destination.path) {
                let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                destination = directory.appendingPathComponent(name, isDirectory: false)
                index += 1
            }
        }
        try fileManager.moveItem(at: sourceURL, to: destination)
        return destination
    }

    /// 备份子目录名（`yyyyMMdd-HHmmss`，本地时区）。
    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 台账条目（收束参数，避免超长参数列表）。
    private struct RenameLogEntry {
        var event: String
        var sourceURL: URL
        var targetURL: URL
        var libraryRoot: URL
        var stableId: String
        var timestamp: Date
    }

    /// 追加一行改名台账（ISO8601 时间 + 旧/新相对路径 + stableId）。台账写入失败只告警，不抛出
    /// （文件已改名，日志失败不该把成功动作变成异常）。
    private static func appendLog(_ entry: RenameLogEntry, fileManager: FileManager) {
        let logURL = renameLogURL(forLibraryRoot: entry.libraryRoot)
        let stamp = ISO8601DateFormatter().string(from: entry.timestamp)
        let line = [
            stamp,
            entry.event,
            relativePath(of: entry.sourceURL, libraryRoot: entry.libraryRoot),
            relativePath(of: entry.targetURL, libraryRoot: entry.libraryRoot),
            entry.stableId,
        ].joined(separator: "\t") + "\n"
        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: logURL, options: .atomic)
            }
        } catch {
            AppLog.warn(.general, "⚠️ rename-log 写入失败（文件已改名）：\(error)")
        }
    }

    /// 绝对 URL → 相对曲库根的路径（不在根内时回落文件所在目录相对根 / 末段名）。
    private static func relativePath(of url: URL, libraryRoot: URL) -> String {
        LibraryRoot.relativePath(of: url, baseDirectory: libraryRoot) ?? url.lastPathComponent
    }
}
