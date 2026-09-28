//
//  MacLibraryRoot.swift
//  QQPlayer
//
//  macOS「曲库 = 单一地址」的**唯一 IO 入口**（QQPlayerMac target only）。
//
//  口径（用户 2026-09-28 拍板）：曲库只能有一个地址——要么默认 `~/Music/QQPlayer`，
//  要么用户指定；**不接受「多根 + 谁排第一」**。启动时确保该根存在（没有就建到默认路径）；
//  用户指定的目录**不存在 → 静默回退默认**（不报错、不建那个目录）。
//
//  为什么单独成文件：对**曲库根**做的 `fileExists` / `createDirectory` 这类 IO 判定
//  只允许出现在这里（纯逻辑在 `MusicFolderResolver.macLibraryRootURL`）。别处再写一份
//  「根在哪 / 根在不在」= 又一个事实源（封面解析散落 5 处的教训）。
//
//  M2（2026-09-28）：设置项已从多选「曲库文件夹」收成**单值** `DeleteSettings.libraryRoot`
//  （空串 = 默认）——本文件即该单值的**唯一读取 / 解析点**。搬迁（拷贝）实现也收在本文件
//  （`MacLibraryRootCopy`）：往曲库根落文件的 IO 同理，不再另起一处。
//
// target: macos-only
//

import Foundation

enum MacLibraryRoot {
    /// 默认曲库位置 `~/Music/QQPlayer`（展示用；**不判存在性**）。
    /// 唯一的「默认根在哪」定义仍在 `MusicFolderResolver.macDefaultFolderURL`。
    static var defaultRootURL: URL {
        MusicFolderResolver.macDefaultFolderURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// 设置里指定位置的**展开后绝对路径**（`~` 按当前用户 home 展开；空串 = nil）。
    /// 只做展开，不判存在性——存在性判定收敛在 `resolvedRootURL`。
    static func expandedSpecifiedPath(_ specifiedPath: String) -> String? {
        guard !specifiedPath.isEmpty else { return nil }
        return MusicFolderResolver.expandedPath(
            specifiedPath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// 曲库根（唯一地址）：读设置里的「指定」→ 交给纯逻辑解析（存在才用，否则回退默认）。
    static var resolvedRootURL: URL {
        MusicFolderResolver.macLibraryRootURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            specifiedPath: DeleteSettings.load().libraryRoot,
            directoryExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// 指定的曲库位置当前**不存在 / 不可用**（本次解析已回退默认）→ 设置页据此给一行说明。
    /// 未指定（空串）= false。
    static func specifiedRootIsUnavailable(_ specifiedPath: String) -> Bool {
        guard let expanded = expandedSpecifiedPath(specifiedPath) else { return false }
        return !FileManager.default.fileExists(atPath: expanded)
    }

    /// 幂等确保曲库根存在（启动时调用；**必须早于 `SyncHostCenter.start()`**）。
    ///
    /// 失败只记 `AppLog.warn(.ui, …)` **不抛**：盘满 / 权限不足时宁可让后续扫描空转，
    /// 也不让启动路径崩（与 `MacImportService`「确保目录存在」同口径）。
    /// - Returns: 解析出的曲库根（无论创建成功与否，调用方可直接拿来用）。
    @discardableResult
    static func ensureRootExists() -> URL {
        let root = resolvedRootURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            AppLog.warn(.ui, "⚠️ MacLibraryRoot: 创建曲库根失败 \(root.path)：\(error)")
        }
        return root
    }
}

// MARK: - 曲库内容搬迁（更换曲库位置时的拷贝）

/// 把旧曲库根下的文件按**相同相对路径**复制到新根（更换曲库位置时的「拷贝」选项）。
///
/// 为什么「只拷贝、只按相对路径」就够：`track.path` 存的是**相对曲库根的相对路径**
/// ⇒ 按相同相对路径复制后 **DB 一行都不用改**，歌单 / 收藏 / 播放历史天然跟着走。
/// 这正是「曲库只有一个地址」的设计成立点。
///
/// 与 `LibraryLayoutMigrator`（iOS）同款的冲突策略：**目标已存在 → 跳过，绝不覆盖**；
/// 且**不删、不移动**源文件（本实现只做 `copyItem`，全程零删除动作）。
enum MacLibraryRootCopy {
    /// 一次拷贝的结果计数（`skipped` = 目标已存在而跳过；`failed` = 真出错）。
    struct Result: Sendable, Equatable {
        var copied = 0
        var skipped = 0
        var failed = 0
    }

    /// 拷贝进度（`done` / `total` 文件数）。
    struct Progress: Sendable, Equatable {
        var done = 0
        var total = 0
    }

    /// 同步执行（调用方放到后台任务里跑，别占主线程——曲库可能上千文件）。
    /// - Parameters:
    ///   - sourceRoot: 旧曲库根（只读；不会被删改）。
    ///   - destinationRoot: 新曲库根（不存在则创建）。
    ///   - onProgress: 进度回调（在调用线程上同步调用；UI 侧自行 hop 主线程）。
    @discardableResult
    static func copyContents(
        from sourceRoot: URL,
        to destinationRoot: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) -> Result {
        performCopy(from: sourceRoot, to: destinationRoot, onProgress: onProgress)
    }

    /// 后台执行包装：`nonisolated async`——从 MainActor `await` 时在全局执行器跑，
    /// 不占主线程（同 `TrackDeletionService.trash` 的形状）。
    @discardableResult
    static func copyContentsInBackground(
        from sourceRoot: URL,
        to destinationRoot: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Result {
        performCopy(from: sourceRoot, to: destinationRoot, onProgress: onProgress)
    }

    /// 同步拷贝实现（`copyContents` / `copyContentsInBackground` 共用的唯一实现）。
    @discardableResult
    private static func performCopy(
        from sourceRoot: URL,
        to destinationRoot: URL,
        onProgress: (@Sendable (Progress) -> Void)?
    ) -> Result {
        var result = Result()
        let fileManager = FileManager.default
        let sourcePath = sourceRoot.standardizedFileURL.path
        let destinationPath = destinationRoot.standardizedFileURL.path
        // 同根（或新根在旧根之内）没有可拷的语义 → 直接返回，避免把根自身递归拷进自己。
        guard sourcePath != destinationPath,
              !destinationPath.hasPrefix(sourcePath + "/")
        else {
            return result
        }
        let sourcePrefix = sourcePath + "/"

        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            AppLog.warn(.general, "⚠️ 曲库搬迁：创建新曲库根失败 \(destinationPath)：\(error)")
            result.failed += 1
            return result
        }

        // 先枚举出全部文件（用于 total 与稳定顺序）；隐藏文件跳过（与搬迁器同款）。
        var files: [URL] = []
        if let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isRegular { files.append(url) }
            }
        }

        onProgress?(Progress(done: 0, total: files.count))
        for (index, file) in files.enumerated() {
            let fullPath = file.standardizedFileURL.path
            let relative = fullPath.hasPrefix(sourcePrefix)
                ? String(fullPath.dropFirst(sourcePrefix.count))
                : file.lastPathComponent
            let destination = destinationRoot.appendingPathComponent(relative)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    // 目标已存在 → 跳过不覆盖（沿用 `LibraryLayoutMigrator` 的既有策略）。
                    result.skipped += 1
                } else {
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: file, to: destination)
                    result.copied += 1
                }
            } catch {
                result.failed += 1
                AppLog.warn(.general, "⚠️ 曲库搬迁：复制失败 \(relative)：\(error)")
            }
            onProgress?(Progress(done: index + 1, total: files.count))
        }

        AppLog.info(
            .general,
            "📦 曲库搬迁完成：拷贝 \(result.copied) / 跳过 \(result.skipped) / 失败 \(result.failed)（\(sourcePath) → \(destinationPath)）"
        )
        return result
    }
}
