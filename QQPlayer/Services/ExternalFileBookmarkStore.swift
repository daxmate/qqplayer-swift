//
//  ExternalFileBookmarkStore.swift
//  QQPlayer
//
//  外部文件书签 plist（Documents/ExternalFileBookmarks.plist）的**唯一入口**
//  （审计 2026-09-12 B2 D2）。
//
//  为什么收敛：同一份 plist 此前有 7 处读写（LibraryIndexer 存书签/读书签/键迁移、
//  DatabaseManager 键迁移/删条目、FileCleanupManager 解析、LibraryView 存书签），
//  其中 3 处是非原子写——进程被杀/掉电时文件截断会让**全部**书签失效，进而
//  外部文件不再导入、且清理路径把仍在磁盘上的曲目当"文件不存在"删库。
//  本文件把两条不变量收在一处，所有调用方共用：
//    1. **原子写**（`.atomic`，失败不改动原文件）；
//    2. **读失败 ≠ 无条目**（load() 返回 unreadable，调用方必须保守处理）。
//

import Foundation

/// 读取结果：必须区分「文件/条目不存在」与「文件在但读不出来」——
/// 前者是事实（可据此判定曲目真没了），后者是未知（清理路径必须保守保留曲目）。
enum ExternalFileBookmarkLoadOutcome {
    /// plist 不存在（= 尚无任何书签）或解析成功。
    case loaded([String: Data])
    /// plist 在磁盘上但读取/解析失败 → **未知**，不得当作"无书签"。
    case unreadable(Error)
}

/// 书签 plist 的读写入口。结构 = `[stableId: 书签 Data]`（PropertyList XML）。
struct ExternalFileBookmarkStore {
    enum StoreError: Error, CustomStringConvertible {
        case unexpectedFormat
        case documentsDirectoryUnavailable

        var description: String {
            switch self {
            case .unexpectedFormat: return "ExternalFileBookmarks.plist 内容不是 [String: Data]"
            case .documentsDirectoryUnavailable: return "Documents 目录不可用"
            }
        }
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(documentsURL: URL) {
        self.init(fileURL: documentsURL.appendingPathComponent("ExternalFileBookmarks.plist"))
    }

    /// 生产默认实例（Documents/ExternalFileBookmarks.plist）。
    static var `default`: ExternalFileBookmarkStore? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ExternalFileBookmarkStore(documentsURL: documentsURL)
    }

    // MARK: - 读

    /// 缺文件 = `.loaded([:])`（尚无书签是事实）；读/解析失败 = `.unreadable`。
    func load() -> ExternalFileBookmarkLoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .loaded([:])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                return .unreadable(StoreError.unexpectedFormat)
            }
            return .loaded(bookmarks)
        } catch {
            return .unreadable(error)
        }
    }

    /// 便利读：仅用于"未知也不是问题"的场景（如纯展示）。清理判定请用 `load()`。
    func loadedBookmarksOrEmpty() -> [String: Data] {
        switch load() {
        case .loaded(let bookmarks): return bookmarks
        case .unreadable: return [:]
        }
    }

    // MARK: - 写（一律原子）

    /// 原子写：先写临时文件再 rename，任何失败都不破坏原文件（原文件保持旧内容）。
    func save(_ bookmarks: [String: Data]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 单条 upsert。读失败时不写（避免用空字典覆盖掉还能救的书签）。
    @discardableResult
    func upsert(_ bookmarkData: Data, forStableId stableId: String) throws -> [String: Data] {
        var bookmarks = try mutableBookmarks()
        bookmarks[stableId] = bookmarkData
        try save(bookmarks)
        return bookmarks
    }

    /// 单条删除。返回是否真的删掉了条目（读失败或本就没有 → false，不写文件）。
    @discardableResult
    func remove(forStableId stableId: String) throws -> Bool {
        var bookmarks = try mutableBookmarks()
        guard bookmarks.removeValue(forKey: stableId) != nil else { return false }
        try save(bookmarks)
        return true
    }

    /// stableId 变更后的键迁移（幂等）。
    ///
    /// 目标键已存在时**保留目标键、不动旧键**（保守：宁可留一个解析不到曲目的
    /// 孤儿键，也不覆盖/丢弃另一条真实书签）。
    /// - Returns: 实际改名的条数。
    @discardableResult
    func renameKeys(_ remapping: [String: String]) throws -> Int {
        guard !remapping.isEmpty else { return 0 }
        var bookmarks = try mutableBookmarks()
        var renamed = 0
        for (oldStableId, newStableId) in remapping where oldStableId != newStableId {
            guard let bookmarkData = bookmarks[oldStableId] else { continue }
            guard bookmarks[newStableId] == nil else {
                print("🔖 Bookmark key migration skipped (target exists): \(oldStableId) → \(newStableId)")
                continue
            }
            bookmarks.removeValue(forKey: oldStableId)
            bookmarks[newStableId] = bookmarkData
            renamed += 1
        }
        guard renamed > 0 else { return 0 }
        try save(bookmarks)
        return renamed
    }

    private func mutableBookmarks() throws -> [String: Data] {
        switch load() {
        case .loaded(let bookmarks):
            return bookmarks
        case .unreadable(let error):
            // 读不出来就不写：用空字典覆盖会把还能救的书签一起抹掉。
            throw error
        }
    }
}
