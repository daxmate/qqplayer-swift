//
//  TrackIdentityMigration.swift
//  QQPlayer
//
//  **stableId 变更的唯一入口**（审计 2026-09-12 B2 D3/D5）。
//
//  一次 stableId 变更（刮削改名、外部文件移动、iCloud 容器 UUID 变化、旧库
//  filename→path 迁移）牵动六处引用：
//    1. DB 四表：favorite / playlist_item / track_artist / play_history
//    2. 外部文件书签：Documents/ExternalFileBookmarks.plist（键 = stableId）
//    3. 手动歌词：Documents/lyrics-manual/{stableId}.json
//    4. 对齐歌词：Documents/lyrics-aligned/{stableId}.json（**参与随歌同步**）
//    5. 网络歌词缓存：Documents/lyrics-cache/tracks/{stableId}.json
//    6. 封面映射：Documents/ArtworkMapping.plist（键 = stableId）
//
//  为什么收敛：此前迁移散落在 moveTrack / migrateTrackStableIdAndPath / 旧库
//  迁移块 / upsertTrack 去重 / cleanupStaleUnplayableDuplicates / resolveBookmarkForTrack
//  六处，各迁一部分（DB 四表、书签键各写各的，歌词与封面映射完全没人迁），
//  于是刮削改名后手动/对齐歌词静默消失；resolveBookmarkForTrack 更是只改 path
//  不改 stableId，破坏 `stable_id == SHA256(标准化 path)` 不变量（D5）。
//  目录名一律取 `LyricsStoreKind`（存储命名空间的单一事实源），不写字面量；
//  书签键迁移一律经 `ExternalFileBookmarkStore`（唯一文件入口，见 D2）。
//
//  用法（**决定谁负责什么**）：
//  - DB 侧：`migrateDatabaseReferences(_:from:to:)` 在**调用方写事务内**调用，
//    与 track 行的 stable_id 变更同事务提交（保证引用与身份原子一致）。
//  - 文件侧：`migrateFileReferences(...)` 在**事务外**调用（文件 IO 不进写事务），
//    入参就是事务内收集的 old→new 映射。
//
//  幂等性：DB 侧 `UPDATE ... OR IGNORE` + 清残留（重跑 = 无行可迁）；
//  文件侧只在"源在、目标不在"时改名（重跑 = 无事发生），可安全重复调用。
//

import Foundation
@preconcurrency import GRDB

/// 文件侧迁移结果（日志与测试断言用；失败不抛——文件侧是尽力而为，DB 侧才是事务）。
struct TrackIdentityFileMigrationReport: Equatable {
    var bookmarksRenamed = 0
    var lyricsFilesRenamed = 0
    var artworkKeysRenamed = 0
    /// 被跳过的项（目标已存在等），格式 "kind:reason:old→new"。
    var skipped: [String] = []
}

enum TrackIdentityMigration {
    // MARK: - DB 侧（调用方事务内；与 track 行的 stable_id 变更同事务）

    /// 四表引用跟随新 stableId。`favorite`/`playlist_item`/`track_artist` 有主键或
    /// 唯一约束 → `OR IGNORE` 迁移后清掉旧行残留；`play_history` 无唯一约束 →
    /// 直接 UPDATE 全部行（历史跟随歌曲，不被删除，P0-3）。
    ///
    /// `OR IGNORE` 是 D6 的修复点：没有它，新旧 id 同时存在引用行时 UPDATE 撞
    /// 主键抛错，会回滚**整次入库事务**（文件静默不入库）。
    ///
    /// 幂等：old == new 或旧 id 已无引用行时为无操作。
    static func migrateDatabaseReferences(_ db: Database, from oldStableId: String, to newStableId: String) throws {
        guard oldStableId != newStableId else { return }
        try migrateDatabaseReferences(db, remapping: [oldStableId: newStableId])
    }

    /// 批量版（旧库全表迁移用）。
    static func migrateDatabaseReferences(_ db: Database, remapping: [String: String]) throws {
        for (oldStableId, newStableId) in remapping where oldStableId != newStableId {
            try db.execute(
                sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                arguments: [newStableId, oldStableId]
            )
            try db.execute(
                sql: "UPDATE OR IGNORE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                arguments: [newStableId, oldStableId]
            )
            try db.execute(
                sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                arguments: [newStableId, oldStableId]
            )
            // OR IGNORE 会因主键冲突留下旧行（同一曲目在新旧 id 下都已存在）→ 清残留
            try db.execute(sql: "DELETE FROM favorite WHERE track_stable_id = ?", arguments: [oldStableId])
            try db.execute(sql: "DELETE FROM playlist_item WHERE track_stable_id = ?", arguments: [oldStableId])
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [oldStableId])

            // play_history 没有 UNIQUE 约束：一次 UPDATE 迁移全部行，无需补 DELETE
            try db.execute(
                sql: "UPDATE play_history SET track_stable_id = ? WHERE track_stable_id = ?",
                arguments: [newStableId, oldStableId]
            )
        }
    }

    // MARK: - 文件侧（事务外；幂等，可重复调用/失败重试）

    /// 单个 stableId 变更的文件侧迁移。
    @discardableResult
    static func migrateFileReferences(
        from oldStableId: String,
        to newStableId: String,
        documentsURL: URL? = nil
    ) -> TrackIdentityFileMigrationReport {
        migrateFileReferences(remapping: [oldStableId: newStableId], documentsURL: documentsURL)
    }

    /// 书签 + 三个歌词目录 + 封面映射。**不抛错**：文件侧失败不该回滚已提交的
    /// DB 迁移（下次入库/对账会再走一遍本函数）。所有失败都打进日志与 report。
    @discardableResult
    static func migrateFileReferences(
        remapping: [String: String],
        documentsURL: URL? = nil
    ) -> TrackIdentityFileMigrationReport {
        var report = TrackIdentityFileMigrationReport()
        guard !remapping.isEmpty else { return report }

        // 1. 外部文件书签（原子写；读失败不写，避免抹掉还能救的书签）
        if let store = bookmarkStore(documentsURL: documentsURL) {
            do {
                report.bookmarksRenamed = try store.renameKeys(remapping)
            } catch {
                print("⚠️ TrackIdentityMigration: bookmark key rename failed: \(error)")
                report.skipped.append("bookmarks:readFailed")
            }
        }

        // 2. 三个歌词目录（目录名取 LyricsStoreKind 单一事实源）
        if let documentsURL = resolvedDocumentsURL(documentsURL) {
            for kind in LyricsStoreKind.allCases {
                let directory = documentsURL.appendingPathComponent(kind.directoryName, isDirectory: true)
                for (oldStableId, newStableId) in remapping where oldStableId != newStableId {
                    let source = directory.appendingPathComponent("\(oldStableId).json")
                    let destination = directory.appendingPathComponent("\(newStableId).json")
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        // 目标已存在：不覆盖、不删除（宁可留孤儿文件，也不丢用户歌词）
                        print("🎤 TrackIdentityMigration: \(kind.rawValue) lyrics already exist for new id, kept source")
                        report.skipped.append("\(kind.rawValue):targetExists")
                        continue
                    }
                    do {
                        try FileManager.default.moveItem(at: source, to: destination)
                        report.lyricsFilesRenamed += 1
                    } catch {
                        print("⚠️ TrackIdentityMigration: \(kind.rawValue) lyrics rename failed: \(error)")
                        report.skipped.append("\(kind.rawValue):renameFailed")
                    }
                }
            }
        }

        // 3. 封面映射：**必须经 ArtworkManager**（它持有内存副本 + 去抖写盘，
        //    背着它改 plist 会被下一次 saveMapping() 覆盖回去）。ArtworkManager 是
        //    @MainActor 单例，而本函数在索引后台线程调用 → 主线程跳一次；
        //    封面映射失效只是重新解包（自愈），故这里尽力而为、不阻塞调用方。
        let artworkRemapping = remapping.filter { $0.key != $0.value }
        if !artworkRemapping.isEmpty {
            Task { @MainActor in
                if migrateArtworkMappingKeys(remapping: artworkRemapping) {
                    print("🖼️ TrackIdentityMigration: artwork mapping key(s) migrated")
                }
            }
        }

        report.artworkKeysRenamed = artworkRemapping.count
        return report
    }

    /// 映射键重写（**纯函数**，封面映射决策的单一事实源，可单测）。
    /// 目标键已存在时保留目标键、不动旧键（宁可重新解包一次，也不覆盖真实映射）。
    static func remappedArtworkMapping(
        _ mapping: [String: String],
        remapping: [String: String]
    ) -> (mapping: [String: String], changed: Bool) {
        var updated = mapping
        var changed = false
        for (oldStableId, newStableId) in remapping where oldStableId != newStableId {
            guard let artworkHash = updated[oldStableId], updated[newStableId] == nil else { continue }
            updated.removeValue(forKey: oldStableId)
            updated[newStableId] = artworkHash
            changed = true
        }
        return (updated, changed)
    }

    /// 把纯函数结果落到 ArtworkManager（主线程：其内存映射是 plist 的事实源）。
    /// - Returns: 是否发生了改写。
    @MainActor
    @discardableResult
    static func migrateArtworkMappingKeys(remapping: [String: String]) -> Bool {
        let manager = ArtworkManager.shared
        let result = remappedArtworkMapping(manager.artworkMapping, remapping: remapping)
        guard result.changed else { return false }
        manager.artworkMapping = result.mapping
        manager.saveMapping()
        return true
    }

    // MARK: - 内部

    private static func resolvedDocumentsURL(_ documentsURL: URL?) -> URL? {
        documentsURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func bookmarkStore(documentsURL: URL?) -> ExternalFileBookmarkStore? {
        if let documentsURL {
            return ExternalFileBookmarkStore(documentsURL: documentsURL)
        }
        return .default
    }
}
