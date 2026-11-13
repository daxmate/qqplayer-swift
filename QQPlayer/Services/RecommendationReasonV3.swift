//
//  RecommendationReasonV3.swift
//  QQPlayer
//
//  推荐 v3：理由文案（模板，无 LLM）。
//
//  三个通道各一句模板，全部走本地化体系（五语种齐全）：
//    A 你常听 {artist}，这是 TA 的热门曲
//    B 与 {seedArtist} 风格相近的 {artist}
//    C {genre} · {decade} · {language}，你常听的类型
//

import Foundation

enum RecommendationReasonV3 {
    /// 通道模板理由（返回单条；调用方与既有理由合并 / 替换）。
    static func reason(for candidate: RecommendationV3Candidate) -> String? {
        let context = candidate.context
        switch context.channel {
        case .seed:
            let artist = displayArtist(context.seedArtist) ?? displayArtist(candidate.song.artist)
            guard let artist else { return nil }
            return String(format: "recommendation_v3_reason_seed".localized, artist)
        case .similar:
            guard let seed = displayArtist(context.seedArtist) else { return nil }
            let artist = displayArtist(candidate.song.artist) ?? seed
            return String(format: "recommendation_v3_reason_similar".localized, seed, artist)
        case .explore:
            guard let genre = displayArtist(context.genre) else { return nil }
            let decade = decadeLabel(context.year ?? candidate.song.year)
            let language = (context.language ?? .unknown).localizedLabel
            return String(format: "recommendation_v3_reason_explore".localized, genre, decade, language)
        case .request:
            return "recommendation_reason_requested_artist".localized
        }
    }

    /// 年代文案（nil = 未知年代，返回本地化占位）。
    static func decadeLabel(_ year: Int?) -> String {
        guard let decade = RecommendationProfileV3Builder.decadeStart(year) else {
            return "recommendation_decade_unknown".localized
        }
        return String(format: "recommendation_v3_decade".localized, decade)
    }

    private static func displayArtist(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension RecommendationLanguage {
    var localizedLabel: String { localizationKey.localized }
}
