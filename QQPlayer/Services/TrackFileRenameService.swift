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
//  - 命名渲染**必须**走 `LibraryFileNaming.canonicalFileName`（内部先施加落库口径
//    规范化 `DisplayScriptNormalizer.canonical`，再交 `TagRenameLogic` 渲染）；
//    本文件不重写繁简映射/模板/清洗/去重逻辑（禁第二实现）。
//
//  行为（严格按序，见 `rename(track:artist:title:libraryRoot:...)`）：
//  1. 渲染规范名；空值 → `.notRenameable`
//  2. 同名（NFC / 去扩展名）→ `.unchanged`（幂等）
//  3. **源与目标是同一个文件**（仅大小写差异；大小写不敏感卷上 `fileExists` 会命中源
//     文件本身）→ **两段式改名** `source → 同目录临时名 → target`，**绝不进 dedupe**
//     → `.renamed`（唯一副本不得被归档；见 `isSameFile`）
//  4. 目标不存在 → 纯 `moveItem` + `moveTrack` 迁引用 → `.renamed`
//  5. 目标存在：两侧 `content_hash` 相同 → 去重（归档源文件 + 引用并入目标 + 删源行）
//     → `.deduped`；否则 `.skippedTargetConflict`（不改、不覆盖、**不加 `(2)`**）
//
//  ⚠️ 步骤 3 是 2026-09-28 批 A″ 补的护栏。缺它的后果（批 A′ 上报、maintainer 核实）：
//  macOS 默认 APFS **大小写不敏感**，`Connie Talbot - Count On Me.mp3` 想改成规范名
//  `… - Count on Me.mp3` 时 `fileExists(target)` 为真（实为同一文件）⇒ 落步骤 5 ⇒ 两侧
//  hash 相等 ⇒ **把唯一副本归档、库行迁到不存在的目标路径** ⇒ 曲目悬空、曲库少一首。
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
    ///   - artist: 曲目**文件自身标签**的 artist（原始标签值；本服务内部经
    ///     `LibraryFileNaming` 施加落库口径规范化——**不得**传入 `ArtistNameNormalizer.displayName`
    ///     那种随 UI 方向变的显示名）
    ///   - title: 文件自身标签的 title（同上；落库口径规范化的唯一入口在 `LibraryFileNaming`）
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

        // 1. 渲染规范名（落库口径归一 + 唯一渲染实现 TagRenameLogic，均经 LibraryFileNaming）
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

        // 3. 源与目标是**同一个文件**（大小写不敏感卷上的仅大小写差异）：
        //    绝不进 dedupe（唯一副本不得被归档）→ 两段式改名。
        if isSameFile(sourceURL, targetURL, fileManager: fileManager) {
            return try renameCaseOnlySameFile(
                CaseOnlyRenameRequest(
                    stableId: track.stableId,
                    sourceURL: sourceURL,
                    targetURL: targetURL,
                    libraryRoot: libraryRoot,
                    databaseManager: databaseManager,
                    fileManager: fileManager,
                    timestamp: timestamp
                )
            )
        }

        // 4. 目标不存在 → 纯文件系统搬迁 + 引用迁移（唯一入口 moveTrack）
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

        // 5. 目标存在 → 判定内容是否同一首歌
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

    // MARK: - 同一文件（仅大小写差异）

    /// 源与目标是否指向**同一个文件**。
    ///
    /// 判据（2026-09-28 实测，macOS 26.6 / APFS 默认大小写不敏感卷）：
    /// 1. 首选 `URLResourceValues.fileResourceIdentifier` 相等 —— 实测 `Count On Me.mp3`
    ///    与 `Count on Me.mp3` 返回**同一**标识；而内容完全相同但确为两个文件的对照样本返回
    ///    **不同**标识（不会把真去重场景误判成同一文件）。
    /// 2. 回落 `FileManager.attributesOfItem` 的 `.systemNumber`（st_dev）+ `.systemFileNumber`
    ///    （st_ino）同时相等（inode 级同一）。
    ///
    /// 目标路径**不存在** → 直接 `false`：大小写敏感卷上仅大小写差异是两个不同文件，
    /// 走普通改名（行为与批 A 一致）。
    static func isSameFile(_ a: URL, _ b: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: b.path) else { return false }
        let identifiers = [a, b].map {
            (try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        }
        if let first = identifiers[0] as? NSObject, let second = identifiers[1] as? NSObject {
            return first.isEqual(second)
        }
        guard let attributesA = try? fileManager.attributesOfItem(atPath: a.path),
              let attributesB = try? fileManager.attributesOfItem(atPath: b.path),
              let deviceA = attributesA[.systemNumber] as? NSNumber,
              let deviceB = attributesB[.systemNumber] as? NSNumber,
              let inodeA = attributesA[.systemFileNumber] as? NSNumber,
              let inodeB = attributesB[.systemFileNumber] as? NSNumber
        else {
            return false
        }
        return deviceA == deviceB && inodeA == inodeB
    }

    /// 同目录临时名（隐藏 + UUID）：不会被扫描器收录（`.skipsHiddenFiles`），也不撞已有文件。
    private static func temporaryRenameURL(in directory: URL, sourceName: String) -> URL {
        let ext = (sourceName as NSString).pathExtension
        let token = UUID().uuidString
        let name = ext.isEmpty ? ".rename-tmp-\(token)" : ".rename-tmp-\(token).\(ext)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// 仅大小写差异改名（同一文件）的参数束（收束参数，避免超长参数列表）。
    private struct CaseOnlyRenameRequest {
        var stableId: String
        var sourceURL: URL
        var targetURL: URL
        var libraryRoot: URL
        var databaseManager: DatabaseManager
        var fileManager: FileManager
        var timestamp: Date
    }

    /// **同一文件的两段式改名** `source → 同目录临时名 → target`（保证大小写真的改变，
    /// 在任何卷上都安全——直接 `moveItem(source, target)` 在大小写不敏感卷上会因目标
    /// 「已存在」（实为同一文件）而失败）。**绝不归档、绝不进 dedupe。**
    ///
    /// 失败处理（**不得留下「库行指向不存在文件」**）：
    /// - 第一段失败 → 源文件未动，直接抛出（库行仍有效）。
    /// - 第二段失败 → 尽力把文件还原到 `source`；还原也失败（文件停在临时名）时把库行
    ///   迁到临时名，保持「行 ↔ 文件」一致；随后抛出。
    /// - 引用迁移失败 → 两段式改回原名，保持「行 ↔ 文件」一致；随后抛出。
    private static func renameCaseOnlySameFile(
        _ request: CaseOnlyRenameRequest
    ) throws -> TrackFileRenameOutcome {
        let sourceURL = request.sourceURL
        let targetURL = request.targetURL
        let fileManager = request.fileManager
        let databaseManager = request.databaseManager
        let temporaryURL = temporaryRenameURL(
            in: sourceURL.deletingLastPathComponent(),
            sourceName: sourceURL.lastPathComponent
        )

        // 第一段：source → 临时名
        do {
            try fileManager.moveItem(at: sourceURL, to: temporaryURL)
        } catch {
            AppLog.warn(.general, "⚠️ rename(case-only): 移入临时名失败，源文件未动：\(error)")
            throw error
        }

        // 第二段：临时名 → target
        do {
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
        } catch {
            let moveError = error
            do {
                try fileManager.moveItem(at: temporaryURL, to: sourceURL)
            } catch {
                AppLog.warn(
                    .general,
                    "⚠️ rename(case-only): 还原到原名失败，文件停在 \(temporaryURL.lastPathComponent)：\(error)"
                )
                try? databaseManager.moveTrack(
                    from: sourceURL.path,
                    to: temporaryURL.path,
                    fileManager: fileManager
                )
            }
            AppLog.warn(.general, "⚠️ rename(case-only): 落到目标失败：\(moveError)")
            throw moveError
        }

        // 引用迁移（唯一入口）。失败 → 两段式改回原名，保持「行 ↔ 文件」一致。
        do {
            try databaseManager.moveTrack(from: sourceURL.path, to: targetURL.path, fileManager: fileManager)
        } catch {
            let migrationError = error
            do {
                try fileManager.moveItem(at: targetURL, to: temporaryURL)
                try fileManager.moveItem(at: temporaryURL, to: sourceURL)
            } catch {
                AppLog.warn(.general, "⚠️ rename(case-only): 引用迁移失败且回退改名失败：\(error)")
            }
            AppLog.warn(.general, "⚠️ rename(case-only): 引用迁移失败，已尽力回退文件名：\(migrationError)")
            throw migrationError
        }

        appendLog(
            RenameLogEntry(
                event: "renamed",
                sourceURL: sourceURL,
                targetURL: targetURL,
                libraryRoot: request.libraryRoot,
                stableId: request.stableId,
                timestamp: request.timestamp
            ),
            fileManager: fileManager
        )
        AppLog.info(
            .general,
            "📛 rename(case-only): \(sourceURL.lastPathComponent) → \(targetURL.lastPathComponent)"
        )
        return .renamed(from: sourceURL.path, to: targetURL.path)
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
