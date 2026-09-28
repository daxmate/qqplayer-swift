//
//  LibraryIndexer+RenameNormalize.swift
//  QQPlayer
//
//  索引自愈改名（2026-09-28「曲库命名对齐」批 A）。
//
//  索引链路（iOS `scanLocalDocuments` / macOS `scanMusicFolder`）在扫描完成后调用
//  **同一实现**：对库里「磁盘存在且标签可解析」的曲目，按文件自身标签渲染的规范名
//  调 `TrackFileRenameService`（唯一改名入口）。两端同一实现是本批的核心约束
//  —— 防止「iOS 有一份、Mac 又写一份」的第二实现。
//
//  取数口径（2026-09-28 22:1x 用户拍板「落库全部用简体」）：**读文件自身标签**拿到
//  原始 artist / title（存量 53 条是「磁盘简体 + 标签繁体」，标签才是事实来源），
//  再经 `LibraryFileNaming` 施加**落库口径规范化**（`DisplayScriptNormalizer.canonical`
//  ——入库写入的同一入口，固定简体）后渲染——不得用随 UI 方向变的显示名
//  （`ArtistNameNormalizer.displayName`），也不得照标签原文渲染（会把磁盘简体名
//  改成繁体，与落库口径相反）。
//
//  计数与日志：每个动作由 `TrackFileRenameService` 打点（`rename:` / `dedupe:` /
//  `skip-conflict:`），本函数再打一行汇总计数。
//

import Foundation

/// 一轮索引自愈改名的汇总（可观测 + 测试断言用）。
struct RenameSweepReport: Equatable {
    var renamed = 0
    var deduped = 0
    var skippedTargetConflict = 0
    var unchanged = 0
    var notRenameable = 0
    /// 磁盘不存在（含已被本轮回环处理而归档的源文件）——跳过。
    var fileMissing = 0
    /// 标签解析失败 / 备份目录内 —— 跳过。
    var skipped = 0

    /// 本轮是否实际改动过文件（调用方据此决定是否再发刷新通知）。
    var didChangeAnything: Bool { renamed > 0 || deduped > 0 }

    var logLine: String {
        "🧹 rename sweep: renamed=\(renamed) deduped=\(deduped) "
            + "skip-conflict=\(skippedTargetConflict) unchanged=\(unchanged) "
            + "notRenameable=\(notRenameable) missing=\(fileMissing) skipped=\(skipped)"
    }
}

extension LibraryIndexer {
    /// 索引自愈：把库里可解析标签的曲目按规范名对齐（两端同一实现）。
    ///
    /// 非阻塞设计：`nonisolated`（在扫描任务的后台上下文跑，不占主线程）；文件 IO 与
    /// 标签解析都在此逐条发生。逐条尽力而为，单条失败只打日志、不影响其余。
    ///
    /// - Parameter libraryRoot: 曲库根（备份根 = 其父目录下的 `.qqplayer-rename-backup`）。
    ///   iOS = `MusicFolderResolver.iosMusicLibraryDirectoryURL()`；
    ///   macOS = `MacLibraryRoot.resolvedRootURL`。
    @discardableResult
    nonisolated func runRenameNormalizationSweep(
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) async -> RenameSweepReport {
        var report = RenameSweepReport()

        let tracks: [Track]
        do {
            tracks = try databaseManager.getAllTracks()
        } catch {
            AppLog.warn(.general, "⚠️ rename sweep: 读取曲库失败，跳过本轮：\(error)")
            return report
        }

        for track in tracks {
            if Task.isCancelled { break }
            let url = LibraryRoot.absoluteURL(forStoredPath: track.path, fileManager: fileManager)
            // 备份/台账目录内绝不处理（防御：备份文件不该被当作曲目）
            if LibraryFileNaming.isInsideRenameBackup(url) {
                report.skipped += 1
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else {
                report.fileMissing += 1
                continue
            }

            let metadata: AudioMetadata
            do {
                metadata = try await AudioMetadataParser.parseMetadata(from: url)
            } catch {
                report.skipped += 1
                continue
            }

            do {
                let outcome = try TrackFileRenameService.rename(
                    track: track,
                    artist: metadata.artist,
                    title: metadata.title,
                    libraryRoot: libraryRoot,
                    databaseManager: databaseManager,
                    fileManager: fileManager
                )
                switch outcome {
                case .unchanged: report.unchanged += 1
                case .renamed: report.renamed += 1
                case .deduped: report.deduped += 1
                case .skippedTargetConflict: report.skippedTargetConflict += 1
                case .notRenameable: report.notRenameable += 1
                }
            } catch {
                report.skipped += 1
                AppLog.warn(.general, "⚠️ rename sweep: \(url.lastPathComponent) 处理失败：\(error)")
            }
        }

        AppLog.info(.general, report.logLine)
        return report
    }
}
