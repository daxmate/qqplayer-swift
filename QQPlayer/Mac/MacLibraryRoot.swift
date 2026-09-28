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
//  ⚠️ 过渡读取：本批「指定」的来源 = `DeleteSettings.libraryFolders` 的**首项**
//  （非空即视为「指定」；目录不存在则回退默认）。**M2 会把该设置项改成单选「曲库位置」**，
//  届时改读单值即可——多根 `libraryFolders` 不是设计，只是过渡形态，勿照着演进。
//
// target: macos-only
//

import Foundation

enum MacLibraryRoot {
    /// 曲库根（唯一地址）：读设置里的「指定」→ 交给纯逻辑解析（存在才用，否则回退默认）。
    static var resolvedRootURL: URL {
        MusicFolderResolver.macLibraryRootURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            specifiedPath: DeleteSettings.load().libraryFolders.first,
            directoryExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
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
