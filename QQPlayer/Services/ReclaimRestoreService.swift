//
//  ReclaimRestoreService.swift
//  QQPlayer
//
//  回收区恢复的**唯一入口**（2026-09-29 回收区管理批）。
//
//  用户口径（2026-09-29 原话）：「从回收区恢复到曲库中；（可以选择单曲）；恢复后自动从
//  排除清单中除掉」。
//
//  行为（严格按序）：
//   1. 条目不在了 / 不是音频 → `.skipped`（不猜、不硬搬）；
//   2. 读**文件自身标签**（`AudioMetadataParser`）→ 用 `LibraryFileNaming.canonicalFileName`
//      渲染规范名（落库简体口径；标签读不到 → **回退该文件现有名**，绝不丢文件）；
//   3. 目标 = 曲库根下同名文件；**同名冲突保守处理、绝不覆盖**（复用既有导入去重命名
//      `MacImportNaming.uniqueDestinationURL`，`name 2.ext` 递增）；
//   4. **纯 `FileManager.moveItem` 搬回曲库根**（只搬文件，**绝不写标签字节** —— 保
//      `content_hash`，跨端身份键不失效）；
//   5. 收录 + 清排除表：**必须**复用唯一入口
//      `LibraryIndexer.processExternalFileOutcome(_:allowExcludedReimport: true)`；
//   6. 收录失败 → 把文件原样搬回回收区（fail-closed：不留「文件在库、库里没这行」）；
//   7. 追加台账（与改名台账同目录同口径，见 `LibraryFileNaming.reclaimRestoreLogFileName`）。
//
//  ⚠️ 旧排除条目（如实说明）：排除表（`DeleteSettings`，UserDefaults
//  `ExcludedTrackStableIds`）按 `stableId = SHA256(标准化 path)` 记；恢复默认名与原
//  删除前名字一致时 stableId 不变，第 5 步**顺手清掉**它。若恢复名与删除前不同
//  （回收区里原名已丢、按标签渲染出新名），旧 stableId 与恢复后的 stableId 不同，
//  第 5 步只能清掉**新** stableId 的条目，旧条目成为无害残留（不会再挡任何文件）。
//
//  依赖注入只为可测：`importStep` 闭包是**测试 seam**（生产一律传
//  `LibraryIndexer.processExternalFileOutcome`，本文件不另写收录实现）。
//

import Foundation

/// 一次恢复的结果（穷尽）。
enum ReclaimRestoreOutcome: Equatable {
    /// 已搬回曲库根并收录（`importOutcome` = 唯一收录入口的返回）。
    case restored(restoredURL: URL, importOutcome: ExternalImportOutcome)
    /// 没做（文件已不在 / 不是音频）。
    case skipped(reason: ReclaimRestoreSkipReason)
    /// 做了但失败（移动失败 / 收录失败；失败时文件已尽力搬回回收区）。
    case failed(message: String)
}

/// 跳过原因。
enum ReclaimRestoreSkipReason: String, Equatable {
    /// 条目已不在磁盘（界面期间被删/被移）。
    case fileMissing
    /// 非音频格式（回收区里混入的非音频条目只能删除）。
    case notRestorable
}

enum ReclaimRestoreService {
    // MARK: - 纯逻辑（可单测）

    /// 恢复后的目标文件名：按标签渲染的规范名；标签读不到 → 回退现有名。
    /// - Parameters:
    ///   - existingName: 回收区里的现有文件名（生产 = `<内容指纹>.<扩展名>`）
    ///   - metadata: 文件自身标签（解析失败传 nil）
    static func desiredFileName(existingName: String, metadata: AudioMetadata?) -> String {
        let ext = (existingName as NSString).pathExtension
        guard let metadata, !ext.isEmpty,
              let canonical = LibraryFileNaming.canonicalFileName(
                  artist: metadata.artist,
                  title: metadata.title,
                  ext: "." + ext.lowercased()
              )
        else {
            return existingName
        }
        return canonical
    }

    /// 恢复目标 URL：曲库根下同名冲突时**保守避让，绝不覆盖**。
    /// 命名算法复用既有导入去重（`MacImportNaming.uniqueDestinationURL`，其内部用
    /// `FileManager.default` 判存在性——与真实文件系统同源），本文件不另写一份。
    static func destinationURL(in libraryRoot: URL, desiredName: String) -> URL {
        MacImportNaming.uniqueDestinationURL(in: libraryRoot, sourceName: desiredName)
    }

    // MARK: - 唯一入口

    /// 生产入口：收录走 `LibraryIndexer` 唯一入口（`allowExcludedReimport: true` ⇒ 顺手清排除表）。
    @MainActor
    static func restore(
        entry: ReclaimAreaEntry,
        libraryRoot: URL,
        indexer: LibraryIndexer,
        fileManager: FileManager = .default,
        timestamp: Date = Date()
    ) async -> ReclaimRestoreOutcome {
        await restore(
            entry: entry,
            libraryRoot: libraryRoot,
            fileManager: fileManager,
            timestamp: timestamp
        ) { url in
            await indexer.processExternalFileOutcome(url, allowExcludedReimport: true)
        }
    }

    /// 核心（`importStep` = 测试 seam；生产由上面的重载传 `LibraryIndexer` 唯一入口）。
    @MainActor
    static func restore(
        entry: ReclaimAreaEntry,
        libraryRoot: URL,
        fileManager: FileManager = .default,
        timestamp: Date = Date(),
        importStep: (URL) async -> ExternalImportOutcome
    ) async -> ReclaimRestoreOutcome {
        let source = entry.url
        guard fileManager.fileExists(atPath: source.path) else {
            AppLog.info(.general, "♻️ reclaim restore: 条目已不在，跳过 \(source.lastPathComponent)")
            return .skipped(reason: .fileMissing)
        }
        guard entry.isRestorable else {
            AppLog.info(.general, "♻️ reclaim restore: 非音频条目，跳过 \(source.lastPathComponent)")
            return .skipped(reason: .notRestorable)
        }

        let metadata = try? await AudioMetadataParser.parseMetadata(from: source)
        let desiredName = desiredFileName(existingName: source.lastPathComponent, metadata: metadata)
        let destination = destinationURL(in: libraryRoot, desiredName: desiredName)

        do {
            try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            AppLog.warn(.general, "⚠️ reclaim restore: 搬回曲库失败 \(source.lastPathComponent)：\(error)")
            return .failed(message: "\(error)")
        }

        let importOutcome = await importStep(destination)
        if case .failed(let failure) = importOutcome {
            // 收录失败 → 原样搬回回收区（不留「文件在库、库里没这行」的悬空态）。
            do {
                try fileManager.moveItem(at: destination, to: source)
            } catch {
                AppLog.warn(
                    .general,
                    "⚠️ reclaim restore: 收录失败后回搬也失败，文件停在曲库：\(destination.lastPathComponent)（\(error)）"
                )
            }
            AppLog.warn(.general, "⚠️ reclaim restore: 收录失败 \(destination.lastPathComponent)：\(failure)")
            return .failed(message: "\(failure)")
        }

        appendLedger(
            source: source,
            destination: destination,
            libraryRoot: libraryRoot,
            fileManager: fileManager,
            timestamp: timestamp
        )
        AppLog.info(.general, "♻️ reclaim restore: \(source.lastPathComponent) → \(destination.lastPathComponent)")
        return .restored(restoredURL: destination, importOutcome: importOutcome)
    }

    // MARK: - 台账

    /// 追加一行恢复台账（写入失败只告警，不把成功的恢复变成异常——同改名台账口径）。
    static func appendLedger(
        source: URL,
        destination: URL,
        libraryRoot: URL,
        fileManager: FileManager = .default,
        timestamp: Date = Date()
    ) {
        let logURL = TrackFileRenameService.backupRoot(forLibraryRoot: libraryRoot)
            .appendingPathComponent(LibraryFileNaming.reclaimRestoreLogFileName, isDirectory: false)
        let stamp = ISO8601DateFormatter().string(from: timestamp)
        let restored = LibraryRoot.relativePath(of: destination, baseDirectory: libraryRoot)
            ?? destination.lastPathComponent
        let line = [stamp, "restored", source.path, restored].joined(separator: "\t") + "\n"
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
            AppLog.warn(.general, "⚠️ reclaim-restore-log 写入失败（文件已恢复）：\(error)")
        }
    }
}
