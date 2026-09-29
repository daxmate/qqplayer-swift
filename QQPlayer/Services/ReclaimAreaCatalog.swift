//
//  ReclaimAreaCatalog.swift
//  QQPlayer
//
//  应用回收区（`<曲库根>/.Trash`）的**只读枚举**与条目模型（2026-09-29 回收区管理批）。
//
//  背景（用户 2026-09-29 拍板）：回收区此前**没有任何界面** —— 「只从曲库移除」
//  （`DeleteSettings.deleteFromLibraryOnly`）把库内文件移进回收区后，用户既看不到、
//  也恢复不了、更清不掉。本批补「查看 / 恢复 / 彻底删除」三件事，本文件只负责第一件
//  （枚举；恢复与删除各有一个唯一入口，见 `ReclaimRestoreService` / `ReclaimPurgeService`）。
//
//  **范围（用户 2026-09-29 08:22 收窄）**：只做**生产回收区** `<曲库根>/.Trash`
//  （iOS = `Documents/Music/.Trash`）。历史遗留的 `Documents/.qqplayer/trash` /
//  `Documents/.Trash` 两处旧区**不做界面/枚举特例**（其内容由维护者手工拷进生产区）。
//
//  单一事实源（硬约束，禁第二实现）：
//   · 目录派生 = `DeleteReclaimArea.url(inLibraryRoot:)`（回收区唯一派生点；本文件
//     不得再拼 `.Trash` 字面量）；
//   · 曲库根由调用方给（生产 = `DatabaseSyncCollectionFacts.defaultLibraryRoot`）；
//   · 音频扩展名判定 = `LibraryAudioFormats.allSupported`。
//
//  纯枚举：不移动、不删除、不写任何东西；排序稳定（按文件名 `localizedStandardCompare`），
//  便于测试断言与界面呈现。
//

import Foundation

/// 回收区里的一个条目（只带展示与后续动作所需字段）。
struct ReclaimAreaEntry: Sendable, Equatable, Identifiable {
    /// 文件 URL（回收区内）。
    let url: URL
    /// 占用字节（优先「已分配」大小，回落逻辑大小）。
    let byteSize: Int64
    /// 修改时间（读不到 → nil）。
    let modificationDate: Date?

    var id: String { url.path }
    /// 现有文件名（生产回收区 = `<内容指纹>.<扩展名>`：删除时原名已丢）。
    var existingName: String { url.lastPathComponent }
    /// 是否可恢复（音频格式；非音频条目只能删除）。
    var isRestorable: Bool {
        LibraryAudioFormats.allSupported.contains(url.pathExtension.lowercased())
    }
}

enum ReclaimAreaCatalog {
    /// 回收区目录 URL（**唯一派生点** = `DeleteReclaimArea`；禁在别处手拼 Documents/.Trash）。
    static func directoryURL(libraryRoot: URL) -> URL {
        DeleteReclaimArea.url(inLibraryRoot: libraryRoot)
    }

    /// 枚举回收区条目（只读；不存在 / 读不到 → 空数组，不抛错）。
    /// - Parameters:
    ///   - libraryRoot: 曲库根（生产 = `DatabaseSyncCollectionFacts.defaultLibraryRoot`）
    ///   - fileManager: Documents 根解析缝（默认 `.default` ⇒ 生产行为不变）
    static func entries(libraryRoot: URL, fileManager: FileManager = .default) -> [ReclaimAreaEntry] {
        let directory = directoryURL(libraryRoot: libraryRoot)
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [ReclaimAreaEntry] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }
            let byteSize = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            entries.append(
                ReclaimAreaEntry(
                    url: url,
                    byteSize: byteSize,
                    modificationDate: values.contentModificationDate
                )
            )
        }
        return entries.sorted {
            $0.existingName.localizedStandardCompare($1.existingName) == .orderedAscending
        }
    }

    /// 条目总占用（确认文案用）。
    static func totalByteSize(of entries: [ReclaimAreaEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.byteSize }
    }

    /// 占用的人类可读文案（`ByteCountFormatter`；两端同一份格式）。
    static func formattedSize(_ byteSize: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: byteSize)
    }
}
