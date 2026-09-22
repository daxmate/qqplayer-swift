//
//  DatabaseHiddenLayoutRelocation.swift
//  QQPlayer
//
// target: ios-only（iOS 沙盒语义：曲库根 = `<Documents>/Music`，DB 兜底落点曾在 Documents 根；
// macOS 的 DB 落 `Application Support/QQPlayerMac/`，与 Documents 无关）
//
//  隐藏布局（2026-09-22「只留 `Music/` 可见」）里 **DB 三件套的搬迁归属**：
//  `<Documents>/MusicLibrary.sqlite(+ -shm / -wal)` → `<Documents>/.qqplayer/db/…`。
//
//  为什么归 DB 层、而不是启动后的 `LibraryLayoutMigrationV2Migrator`：
//  移动**打开中的** SQLite 文件（尤其 `-wal` / `-shm`）有一致性风险；只有在连接未开时
//  rename 才安全。所以本函数在 `DatabaseManager.getDatabaseURL()` 里、**打开连接之前**调用。
//
//  判据（保守、幂等、只搬不删）：
//   · 新位置已存在 → 不动（新位置权威）
//   · 旧位置不存在 → 无事发生（首次安装 / 已迁完）
//   · `-shm` / `-wal` 各自 best-effort（缺一个不影响主库）
//   · 任何失败 → 原件保留原处，下次启动重试
//

import Foundation

extension DatabaseManager {
    /// 打开连接前的旧库搬迁（幂等、只搬不删）。详见文件头。
    static func relocateLegacyDatabaseForHiddenLayout(fileManager: FileManager = .default) {
        guard let hiddenDirectory = LibraryRoot.databaseDirectoryURL(fileManager: fileManager),
              let documents = LibraryRoot.documentsRootURL(fileManager: fileManager)
        else { return }
        let main = LibraryRoot.musicLibraryFileName
        let hiddenMain = hiddenDirectory.appendingPathComponent(main)
        let legacyMain = documents.appendingPathComponent(main)
        guard !fileManager.fileExists(atPath: hiddenMain.path),
              fileManager.fileExists(atPath: legacyMain.path)
        else { return }
        do {
            try fileManager.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        } catch {
            AppLog.error(.migration, "🫥 HiddenLayout: DB 目录创建失败，旧库保持原位：\(error)")
            return
        }
        var moved: [String] = []
        for name in [main, "\(main)-shm", "\(main)-wal"] {
            let source = documents.appendingPathComponent(name)
            let destination = hiddenDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.moveItem(at: source, to: destination)
                moved.append(name)
            } catch {
                AppLog.warn(.migration, "🫥 HiddenLayout: DB 文件搬迁失败（原件保留）：\(name) → \(error)")
            }
        }
        if !moved.isEmpty {
            AppLog.info(.migration, "🫥 HiddenLayout: 旧库已移入隐藏根（打开连接前）：\(moved.joined(separator: ", "))")
        }
    }
}
