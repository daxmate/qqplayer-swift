//
//  ScrapeSource.swift
//  QQPlayer
//
//  刮削源唯一注册表（E2 「刮削源收口 + 流式显示 + iTunes 备用源」批 2026-10）。
//
//  背景：此前刮削源字符串列表散落在 ≥5 处（ScrapeLogic.mergedCandidates /
//  ScrapeBatchService.scrapeSources / MacTagEditorView+Scrape.orderedSources /
//  MacScrapeSettingsView.sourceDisplayName / SettingsModels 默认值），新增一个源
//  要五处手工对齐，漏一处即静默（PROJECT_RULES「同一语义只有一个入口」）。
//  本枚举是唯一事实源：源标识、本地化键、图标、默认顺序、已存值解析全从这里派生。
//
//  此后**不得**再出现手写 "netease" / "musicbrainz" / "itunes" 字面量列表；
//  ScrapeCandidate.source 仍存 String（既有持久化/展示契约），取值一律经
//  ScrapeSource 枚举成员（如 .netease.rawValue）派生。
//

import Foundation

/// 刮削源（唯一注册表；rawValue 即 ScrapeCandidate.source 取值）
enum ScrapeSource: String, CaseIterable, Sendable, Hashable {
    /// 网易云（cloudsearch）
    case netease
    /// iTunes / Apple Music Search API
    case itunes
    /// MusicBrainz recording 搜索
    case musicbrainz

    /// 本地化键（source_netease / source_itunes / source_musicbrainz）
    var localizationKey: String { "source_\(rawValue)" }

    /// SF Symbol 名（候选分组标题旁的图标）
    var iconName: String {
        switch self {
        case .netease: return "cloud"
        case .itunes: return "music.note"
        case .musicbrainz: return "brain.head.profile"
        }
    }

    /// 默认源优先级（netease → itunes → musicbrainz）
    static let defaultOrder: [ScrapeSource] = [.netease, .itunes, .musicbrainz]

    /// 持久化源字符串列表 → 已知源列表（过滤未知），并补齐缺失的源
    /// （按 defaultOrder 追加到末尾）。
    ///
    /// 兼容旧值：老设置里只有 [netease, musicbrainz] 时，会补上 itunes，
    /// 保证新源对既有安装也可用（合并/展示都拿得到）。
    static func resolvedOrder(from stored: [String]) -> [ScrapeSource] {
        var result = stored.compactMap(ScrapeSource.init(rawValue:))
        for source in defaultOrder where !result.contains(source) {
            result.append(source)
        }
        return result
    }
}
