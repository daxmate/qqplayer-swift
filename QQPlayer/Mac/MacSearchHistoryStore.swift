//
//  MacSearchHistoryStore.swift
//  QQPlayer
//
//  在线搜索历史存储（网易云/歌曲海合并列表，2026-09 B2 批；QQPlayerMac only）。
//  用户拍板：合并一个历史列表 + 点历史项 = 填词 + 切源 + 立即搜索。
//  持久化 UserDefaults（key "onlineSearchHistory.v1"，JSON [SearchHistoryEntry]）：
//  - add 同 keyword 去重置顶（同词更新 source）、上限 10 条
//  - 清空/单条删除无需二次确认（低风险 UI 操作，web 语义）
//

import Foundation

/// 单条搜索历史（keyword 去重键；source 对齐 OnlineSource.rawValue）
struct SearchHistoryEntry: Codable, Identifiable, Equatable {
    let keyword: String
    /// 来源标识（netease | gequhai）
    let source: String

    var id: String { keyword }
}

/// 搜索历史存取（UserDefaults JSON；返回新数组便于 UI @State 直接赋值）
enum MacSearchHistoryStore {
    static let storageKey = "onlineSearchHistory.v1"
    static let maxCount = 10

    /// 读取历史（无数据/JSON 损坏 → 空列表，不抛）
    static func load() -> [SearchHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// 记录一次搜索：同 keyword 移顶并更新 source；超出上限裁掉最旧。返回新列表（已写回）。
    @discardableResult
    static func add(keyword: String, source: String) -> [SearchHistoryEntry] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }
        var entries = load().filter { $0.keyword != trimmed }
        entries.insert(SearchHistoryEntry(keyword: trimmed, source: source), at: 0)
        if entries.count > maxCount {
            entries = Array(entries.prefix(maxCount))
        }
        save(entries)
        return entries
    }

    /// 删除指定下标条目（越界忽略）。返回新列表（已写回）。
    @discardableResult
    static func remove(at index: Int) -> [SearchHistoryEntry] {
        var entries = load()
        guard entries.indices.contains(index) else { return entries }
        entries.remove(at: index)
        save(entries)
        return entries
    }

    /// 清空全部历史。返回空列表（已写回）。
    @discardableResult
    static func clear() -> [SearchHistoryEntry] {
        save([])
        return []
    }

    private static func save(_ entries: [SearchHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
