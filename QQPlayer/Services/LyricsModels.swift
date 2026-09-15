//
//  LyricsModels.swift
//  QQPlayer
//
//  歌词数据模型（LyricsLine / Lyrics / 来源枚举）。
//

import Foundation

struct LyricsLine: Equatable, Codable {
    let timestamp: TimeInterval?
    let text: String
    /// 中文翻译（网易云 tlyric 按时间戳合并，桌面版 text = [原文, 罗马音, 翻译] 的 iOS 等价物）
    var translation: String?
    /// 罗马音（网易云 romalrc 按时间戳合并，桌面版 text[1] 的 iOS 等价物）；
    /// 仅日语等有罗马音数据的曲目非空 —— 无数据即 nil，UI 不占位。
    /// 可选字段：旧的手动歌词 / 歌词缓存 JSON 无此键（decodeIfPresent 得 nil），向后兼容。
    var roman: String?
}

struct Lyrics: Codable {
    let plainLyrics: String
    let syncedLyrics: [LyricsLine]
    let isInstrumental: Bool
    let source: LyricsSource

    enum LyricsSource: String, Codable {
        case embedded
        case netease
        case lrclib
        case none
    }
}
