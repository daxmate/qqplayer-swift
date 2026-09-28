//
//  LibraryFileNaming.swift
//  QQPlayer
//
//  曲库规范化文件命名的**纯逻辑**单一入口（无 IO、无 UI 依赖、可单测）。
//
//  目标（2026-09-28 用户口径「曲库命名对齐」）：文件名对齐**落库口径的简体名**——
//  规范名 = 以「落库口径规范化后的 artist / title」套默认模板 `{artist} - {title}`
//  的渲染结果。两端（iOS / macOS）与导入落盘统一走本文件，不做第二套模板/清洗/去重逻辑。
//
//  **落库口径规范化**（2026-09-28 22:1x 用户拍板「落库全部用简体」）：复用入库写入的
//  唯一入口 `DisplayScriptNormalizer.canonical(_:)`（固定 `.toSimplified`，与 UI 语言
//  方向无关；入库 `upsertTrack` / `upsertArtist` / `upsertAlbum` 用的是同一个）。
//  **不得**改用 `display(_:direction:)` 或 `ArtistNameNormalizer.displayName`（那些随
//  UI 方向变，是显示层）；也**不得**自写繁简映射表 / 正则（第二实现）。
//
//  为什么要在渲染前归一：磁盘名是简体、而文件标签是繁体的存量（实测 53 条）若照标签
//  原文渲染，会把磁盘上的简体名改成繁体名——与落库口径相反。归一后「简体磁盘名 +
//  繁体标签」判为不变（不再改），符合同一首歌两端同名的目标。
//
//  **唯一渲染实现**是 `TagRenameLogic.renderFileName`（模板占位符 / 非法字符清洗 /
//  默认模板空值分支全部在那边）；本文件只做「落库口径归一 + 转发渲染 + Unicode 归一
//  比较」，不得重写模板/清洗/去重逻辑。
//
//  为什么需要 `isSameName`：磁盘上 NFD（分解）与 NFC（组合）两种 Unicode 形式
//  肉眼同名但字节不同（实测 15 条差异），若不归一，规范化会把这些文件**反复改名**
//  （改一次变一种形式，下次判定又「不同名」）。
//
//  备份/台账目录名也定义在此（扫描排除的单一事实源）——见 `isRenameBackupPathComponent`。
//

import Foundation

enum LibraryFileNaming {
    // MARK: - 规范名渲染（唯一入口 = TagRenameLogic）

    /// 按「落库口径规范化的 artist / title」渲染曲库规范文件名。
    /// - Parameters:
    ///   - artist: 文件标签里的 artist（本函数内部施加落库口径规范化；nil / 空 →
    ///     渲染分支按 TagRenameLogic 规则降级）
    ///   - title: 文件标签里的 title（同上）
    ///   - ext: **带点**扩展名（如 ".mp3"；与 `TagRenameLogic.renderFileName` 同口径）
    /// - Returns: 规范文件名；`nil` = 不该改名（artist 与 title 都空，或清洗后为空）。
    ///
    /// 落库口径规范化 = `DisplayScriptNormalizer.canonical`（入库写入同一入口，
    /// 固定简体、与 UI 语言无关）。`nil` 保持 `nil`（`Optional.map`），空串经
    /// `canonical` 仍为空串（其内部对空串原样返回），不改变 `TagRenameLogic` 的空值分支。
    static func canonicalFileName(artist: String?, title: String?, ext: String) -> String? {
        TagRenameLogic.renderFileName(
            template: TagRenameLogic.defaultTemplate,
            values: TagRenameLogic.Values(
                artist: artist.map(DisplayScriptNormalizer.canonical),
                title: title.map(DisplayScriptNormalizer.canonical)
            ),
            ext: ext
        )
    }

    /// Unicode 归一比较：NFC/NFD 等价视为同名（大小写敏感——大小写不同 = 不同名）。
    /// 判据 = `precomposedStringWithCanonicalMapping`（NFC）后逐字相等。
    static func isSameName(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
    }

    /// 去扩展名的同名判定（幂等判据的一部分）。
    /// 用途：文件名仅大小写/扩展名形态差异（如 `.MP3` vs `.mp3`）时不触发改名，
    /// 避免在大小写不敏感的文件系统上把「源 = 目标」判成 rename 并误入冲突分支。
    static func isSameBaseName(_ a: String, _ b: String) -> Bool {
        let baseA = (a as NSString).deletingPathExtension
        let baseB = (b as NSString).deletingPathExtension
        return isSameName(baseA, baseB)
    }

    // MARK: - 改名备份（扫描/索引必须排除）

    /// 改名备份根目录名。落在**曲库根同级**（`<libraryRoot>/../`）= 曲库之外、App 沙盒内。
    /// 前导点 ⇒ 目录被 `.skipsHiddenFiles` 天然忽略；显式排除见 `isRenameBackupPathComponent`。
    static let renameBackupDirectoryName = ".qqplayer-rename-backup"

    /// 改名台账文件名（在备份根下；每行 `ISO8601\t旧相对路径\t新相对路径\tstableId`）。
    static let renameLogFileName = "rename-log.tsv"

    /// 该路径组件是否为「改名备份」目录（`...rename-backup` / `...-rename-backup`）。
    /// 扫描、目录枚举、迁移器一律据此排除——否则备份文件会被重新收录
    /// （`SandboxMusicMigrator` 未排除 `_migrated-backup/` 的旧坑同款）。
    static func isRenameBackupPathComponent(_ name: String) -> Bool {
        name.contains("rename-backup")
    }

    /// URL 是否位于改名声明的备份目录内（任一祖先路径组件命中）。
    static func isInsideRenameBackup(_ url: URL) -> Bool {
        url.pathComponents.contains { isRenameBackupPathComponent($0) }
    }
}
