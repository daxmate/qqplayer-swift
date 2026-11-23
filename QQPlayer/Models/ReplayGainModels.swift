//
//  ReplayGainModels.swift
//  QQPlayer
//
//  ReplayGain 设置数据模型：模式三态 + 预放大 + 防削波 + 后台补算开关。
//  持久化走 UserDefaults（键值见 StorageKey）；视图层只依赖 ReplayGainManager。
//

import Foundation

/// ReplayGain 模式三态（关闭 / 按曲目 / 按专辑）。
enum ReplayGainMode: String, CaseIterable, Codable, Sendable {
    case off
    case track
    case album

    /// 是否会产生增益（off = 不应用）。
    var isActive: Bool { self != .off }
}

/// ReplayGain 数据分析来源（落库标记，避免每次启动重算）。
enum ReplayGainAnalysisSource: String, Sendable {
    /// 来自文件标签（解析所得）。
    case tag
    /// 来自本地分析（SFBAudioEngine ReplayGainAnalyzer）。
    case analyzed
}

/// 后台分析状态（失败也落库，避免无限重试）。
enum ReplayGainAnalysisState: String, Sendable {
    case pending
    case done
    case failed
}

extension Track {
    /// 重新扫描曲库时的 ReplayGain 字段保留（按 stableId 合并旧行）：
    /// 逐字段「新解析值优先、缺失继承旧值」——标签补齐以标签为准，
    /// 标签缺失时保留后台分析结果（含来源 / 状态 / 时间戳，避免重复分析）。
    func mergingReplayGainFromExisting(_ existing: Track?) -> Track {
        guard let existing else { return self }
        var merged = self
        merged.replaygainTrackGain = replaygainTrackGain ?? existing.replaygainTrackGain
        merged.replaygainTrackPeak = replaygainTrackPeak ?? existing.replaygainTrackPeak
        merged.replaygainAlbumGain = replaygainAlbumGain ?? existing.replaygainAlbumGain
        merged.replaygainAlbumPeak = replaygainAlbumPeak ?? existing.replaygainAlbumPeak
        merged.replaygainSource = existing.replaygainSource
        merged.replaygainAnalysisState = existing.replaygainAnalysisState
        merged.replaygainAnalyzedAt = existing.replaygainAnalyzedAt
        merged.replaygainAlbumAnalysisAt = existing.replaygainAlbumAnalysisAt
        if replaygainTrackGain != nil {
            // 本次从标签解析到了数据 → 标记来源（覆盖旧的分析来源）
            merged.replaygainSource = ReplayGainAnalysisSource.tag.rawValue
            merged.replaygainAnalysisState = ReplayGainAnalysisState.done.rawValue
            merged.replaygainAnalyzedAt = merged.replaygainAnalyzedAt ?? Int(Date().timeIntervalSince1970)
        }
        return merged
    }
}

/// ReplayGain 用户设置。
struct ReplayGainSettings: Equatable, Sendable {
    /// 当前模式（三态唯一事实源）。
    var mode: ReplayGainMode = .track
    /// 预放大（dB），-12 … +6。
    var preampDB: Double = 0
    /// 防削波（峰值上限 -1 dBFS）。
    var preventClipping: Bool = true
    /// 无标签曲目自动后台补算。
    var analyzeMissingTracks: Bool = true

    /// 关闭前最后一次非 off 模式（开关重新打开时恢复）。
    var lastActiveMode: ReplayGainMode = .track

    static let `default` = ReplayGainSettings()

    /// 开关语义（UI 的 Toggle 绑到这里）：开 = 非 off 模式，关 = off。
    var isEnabled: Bool {
        get { mode != .off }
        set {
            if newValue {
                mode = lastActiveMode == .off ? .track : lastActiveMode
            } else {
                if mode != .off {
                    lastActiveMode = mode
                }
                mode = .off
            }
        }
    }

    enum StorageKey {
        static let mode = "qqplayer.replayGain.mode"
        static let preampDB = "qqplayer.replayGain.preampDB"
        static let preventClipping = "qqplayer.replayGain.preventClipping"
        static let analyzeMissingTracks = "qqplayer.replayGain.analyzeMissingTracks"
        static let lastActiveMode = "qqplayer.replayGain.lastActiveMode"
        /// 后台分析暂停状态（跨启动记住，用户暂停后不自动续跑）。
        static let analysisPaused = "qqplayer.replayGain.analysisPaused"
    }

    /// 从 UserDefaults 读取；键缺失 → 默认值（默认开启、按曲目）。
    static func load(from defaults: UserDefaults = .standard) -> ReplayGainSettings {
        var settings = ReplayGainSettings()
        if let raw = defaults.string(forKey: StorageKey.mode),
           let mode = ReplayGainMode(rawValue: raw) {
            settings.mode = mode
        }
        if defaults.object(forKey: StorageKey.preampDB) != nil {
            settings.preampDB = defaults.double(forKey: StorageKey.preampDB)
        }
        if defaults.object(forKey: StorageKey.preventClipping) != nil {
            settings.preventClipping = defaults.bool(forKey: StorageKey.preventClipping)
        }
        if defaults.object(forKey: StorageKey.analyzeMissingTracks) != nil {
            settings.analyzeMissingTracks = defaults.bool(forKey: StorageKey.analyzeMissingTracks)
        }
        if let raw = defaults.string(forKey: StorageKey.lastActiveMode),
           let mode = ReplayGainMode(rawValue: raw),
           mode != .off {
            settings.lastActiveMode = mode
        } else if settings.mode != .off {
            settings.lastActiveMode = settings.mode
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: StorageKey.mode)
        defaults.set(preampDB, forKey: StorageKey.preampDB)
        defaults.set(preventClipping, forKey: StorageKey.preventClipping)
        defaults.set(analyzeMissingTracks, forKey: StorageKey.analyzeMissingTracks)
        defaults.set(lastActiveMode.rawValue, forKey: StorageKey.lastActiveMode)
    }
}
