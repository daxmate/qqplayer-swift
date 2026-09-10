//
//  SyncLocalLibraryScanner.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3b）本端曲库清单采集（iOS/macOS 共用）：一次同步扫描
//  → manifest 生成输入 / 条目。两端（Mac Host 应答 manifest、iOS Client 对账）
//  必须用同一口径，否则对账键/内容判定会漂移——这里就是那个唯一入口。
//
//  口径（与 SyncManifestGenerator 的分工）：
//  - 枚举：MusicDirectoryScanner.audioFilesSync（扩展名过滤 / 跳过隐藏 / 仅常规文件）
//  - 相对路径：SyncManifestGenerator.relativePath(of:baseDirectory:)
//  - size/mtime：URLResourceValues（扫描时顺手取，无额外 IO）
//  - content_hash / stableId：DatabaseManager 现有入口——getTrack(byPath:) 命中即用，
//    未指纹回落 DatabaseManager.contentHashIfFilePresent（惰性回填语义）
//
//  线程：纯同步（会话线程上会被同步调用）；DatabaseManager 自身线程安全。
//

import Foundation

enum SyncLocalLibraryScanner {
    /// 曲库根 → manifest 生成输入（相对路径升序由生成器统一排序）。
    static func sourceFiles(
        in root: URL,
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default
    ) -> [SyncManifestSourceFile] {
        let enabled = MusicDirectoryScanner.enabledExtensions(from: DeleteSettings.load())
        guard let urls = try? MusicDirectoryScanner.audioFilesSync(
            in: root,
            enabledExtensions: enabled
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard let relative = SyncManifestGenerator.relativePath(of: url, baseDirectory: root) else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let track = try? database.getTrack(byPath: url.path)
            let size = Int64(values?.fileSize ?? 0)
            let mtimeMs = Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            let contentHash = track?.contentHash?.isEmpty == false
                ? track?.contentHash
                : DatabaseManager.contentHashIfFilePresent(atPath: url.path)
            return SyncManifestSourceFile(
                relativePath: relative,
                size: size,
                mtimeMs: mtimeMs,
                contentHash: contentHash,
                stableId: track?.stableId
            )
        }
    }

    /// 曲库根 → 全量 manifest 条目（未过滤；集合过滤由 SyncCollection.filter 做）。
    static func entries(
        in root: URL,
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default
    ) -> [ManifestEntry] {
        SyncManifestGenerator.generate(files: sourceFiles(in: root, database: database, fileManager: fileManager))
    }

    /// 曲库根 → 集合过滤后的 manifest 条目（Host 应答 manifest 用）。
    static func entries(
        in root: URL,
        collection: SyncCollection,
        members: SyncCollectionMembers = SyncCollectionMembers(),
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default
    ) -> [ManifestEntry] {
        collection.filter(
            entries(in: root, database: database, fileManager: fileManager),
            members: members
        )
    }
}
