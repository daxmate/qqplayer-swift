//
//  MacLegacyLibraryImporter.swift
//  QQPlayer
//
//  **旧库一次性导入**（MAS 沙盒化，批 2B 2026-10-29）。
//
//  为什么需要：开沙盒前 macOS 版数据库在 `~/Library/Application Support/QQPlayerMac/`；
//  开沙盒后 App 只看得见自己的容器（`~/Library/Containers/<bundle id>/Data/...`）。
//  不导入 = 歌单 / 收藏 / 播放历史全部「消失」（音频文件仍在原处，但需要重扫）。
//
//  口径（用户 2026-10-29 拍板 A 方案）：
//    · 只搬**数据库三件套**（qqplayer.db / -wal / -shm），音频文件原地不动、不重扫；
//    · 目标 = 容器内 `Library/Application Support/QQPlayerMac/`（与 `LibraryRoot` 同一口径）；
//    · **先备份、失败回滚**：容器内已有的 db 先复制成 `.legacy-backup-<时间戳>`，
//      任何一步失败都把容器恢复成导入前的样子；旧目录**全程只读**，绝不改动。
//
//  target: macos-only
//

import Darwin
import Foundation

enum MacLegacyLibraryImporter {
    /// 数据库三件套（顺序即拷贝顺序：主库在前）。
    static let databaseFileNames = ["qqplayer.db", "qqplayer.db-wal", "qqplayer.db-shm"]

    /// 导入结果（报告 / UI 展示用）。
    struct Outcome: Equatable {
        /// 实际落地的文件名（按拷贝顺序）。
        var copiedFiles: [String] = []
        /// 被覆盖的旧库备份文件名（无旧库 = nil）。
        var backupFileName: String?
    }

    enum ImportError: LocalizedError, Equatable {
        /// 所选目录里没有 qqplayer.db。
        case sourceMissing
        /// 目标目录建不出来 / 不可写。
        case destinationUnavailable(String)
        /// 拷贝失败（已回滚）。
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "qqplayer.db not found in the selected folder"
            case let .destinationUnavailable(path):
                return "destination is not writable: \(path)"
            case let .copyFailed(reason):
                return "copy failed: \(reason)"
            }
        }
    }

    // MARK: - 旧库位置

    /// 旧版（未沙盒）数据目录：`~/Library/Application Support/QQPlayerMac`。
    ///
    /// ⚠️ 沙盒里 `homeDirectoryForCurrentUser` 指向**容器** home，拿它拼出来的就是
    /// 新位置（自我指涉）。真实 home 只能走 `getpwuid`（libinfo 不受沙盒重定向）。
    static func legacyDirectoryURL() -> URL? {
        guard let homePath = realHomeDirectoryPath() else { return nil }
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(LibraryRoot.macAppSupportDirectoryName, isDirectory: true)
    }

    /// 旧库目录里是否真的有数据库（沙盒下未授权时这里读不到 = false，属预期）。
    static func legacyDatabaseExists(at directory: URL? = nil) -> Bool {
        guard let directory = directory ?? legacyDirectoryURL() else { return false }
        return databaseFileNames.contains { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    // MARK: - 导入

    /// 导入到 App 默认曲库目录（调用方不必自己解析容器路径——路径口径只留在服务层）。
    @discardableResult
    static func importDatabase(
        from sourceDirectory: URL,
        timestamp: Date = Date()
    ) throws -> Outcome {
        try importDatabase(from: sourceDirectory, into: defaultDestinationDirectory(), timestamp: timestamp)
    }

    /// 默认目标目录 = 容器内曲库数据目录（与 `LibraryRoot` 同一口径）。
    static func defaultDestinationDirectory() throws -> URL {
        guard let root = LibraryRoot.macAppSupportRootURL() else {
            throw ImportError.destinationUnavailable("Application Support")
        }
        return root
    }

    /// 把旧目录的数据库三件套拷进目标目录（覆盖前备份，失败回滚）。
    ///
    /// - Parameters:
    ///   - sourceDirectory: 用户经 NSOpenPanel 选中的旧目录（只读）
    ///   - destinationDirectory: 容器内曲库数据目录（`LibraryRoot.macAppSupportRootURL()`）
    ///   - timestamp: 备份文件名里的时间戳（注入便于测试/固定输出）
    @discardableResult
    static func importDatabase(
        from sourceDirectory: URL,
        into destinationDirectory: URL,
        timestamp: Date = Date()
    ) throws -> Outcome {
        let fileManager = FileManager.default
        let sourceDatabase = sourceDirectory.appendingPathComponent("qqplayer.db")
        guard fileManager.fileExists(atPath: sourceDatabase.path) else {
            throw ImportError.sourceMissing
        }
        try ensureDestination(destinationDirectory, fileManager: fileManager)

        var outcome = Outcome()
        // 1) 备份：把目标里**已存在**的同名文件复制一份（复制而非移动 = 原库一直在）。
        let stamp = backupStamp(timestamp)
        var backups: [(destination: URL, backup: URL?)] = []
        for name in databaseFileNames {
            let destination = destinationDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: destination.path) else {
                backups.append((destination, nil))
                continue
            }
            let backup = destinationDirectory.appendingPathComponent("\(name).legacy-backup-\(stamp)")
            do {
                if fileManager.fileExists(atPath: backup.path) {
                    try fileManager.removeItem(at: backup)
                }
                try fileManager.copyItem(at: destination, to: backup)
            } catch {
                try? rollback(backups, fileManager: fileManager)
                throw ImportError.copyFailed("\(name) 备份失败：\(error.localizedDescription)")
            }
            if name == "qqplayer.db" { outcome.backupFileName = backup.lastPathComponent }
            backups.append((destination, backup))
        }

        // 2) 拷贝（-wal / -shm 不存在属正常：干净关闭的库没有它们）。
        for name in databaseFileNames {
            let source = sourceDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = destinationDirectory.appendingPathComponent(name)
            do {
                try replaceFile(at: destination, with: source, fileManager: fileManager)
                outcome.copiedFiles.append(name)
            } catch {
                try? rollback(backups, fileManager: fileManager)
                throw ImportError.copyFailed("\(name) 拷贝失败：\(error.localizedDescription)")
            }
        }

        AppLog.info(
            .ui,
            "📦 旧库导入完成：\(outcome.copiedFiles.joined(separator: ", ")) → \(destinationDirectory.path)"
        )
        return outcome
    }

    // MARK: - 内部

    private static func ensureDestination(_ directory: URL, fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ImportError.destinationUnavailable(directory.path)
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw ImportError.destinationUnavailable(directory.path)
        }
    }

    /// 发布拷贝：目标已存在 → 先拷到同目录临时文件，再 `replaceItemAt` 原子替换（旧库另有备份）；
    /// 目标不存在 → 直接 `copyItem` 落盘（首装路径，无覆盖风险，不必绕临时文件）。
    ///
    /// 导入器**只做复制**，不做改名/搬迁语义（按标签改名的唯一入口是 `TrackFileRenameService`）。
    private static func replaceFile(at destination: URL, with source: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.copyItem(at: source, to: destination)
            return
        }
        let temporary = destination.appendingPathExtension("legacy-importing")
        if fileManager.fileExists(atPath: temporary.path) {
            try fileManager.removeItem(at: temporary)
        }
        try fileManager.copyItem(at: source, to: temporary)
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    }

    /// 回滚：恢复每个目标文件的导入前状态（有备份 → 备份复制回目标后再删备份；无备份 → 删掉新写入的）。
    private static func rollback(
        _ backups: [(destination: URL, backup: URL?)],
        fileManager: FileManager
    ) throws {
        for entry in backups {
            if fileManager.fileExists(atPath: entry.destination.path) {
                try? fileManager.removeItem(at: entry.destination)
            }
            guard let backup = entry.backup, fileManager.fileExists(atPath: backup.path) else { continue }
            do {
                try fileManager.copyItem(at: backup, to: entry.destination)
                try? fileManager.removeItem(at: backup)
            } catch {
                // 复制不回就**保留备份文件**（宁留一个 .legacy-backup-*，也别让旧库只剩一份丢在临时名里）。
                AppLog.warn(.ui, "⚠️ 回滚复制失败，旧库备份保留在：\(backup.path)")
            }
        }
        // -wal / -shm 未被 importDatabase 的备份循环覆盖到的情况（目标原本不存在）已由上面的删档处理。
        AppLog.warn(.ui, "⚠️ 旧库导入失败，已回滚到导入前状态")
    }

    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func realHomeDirectoryPath() -> String? {
        guard let passwordEntry = getpwuid(getuid()) else { return nil }
        return String(cString: passwordEntry.pointee.pw_dir)
    }
}
