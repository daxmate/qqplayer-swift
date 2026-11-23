//
//  ReplayGainManager.swift
//  QQPlayer
//
//  ReplayGain 运行时协调者：持用户设置 + 当前曲目增益，把最终增益交给 EQManager
//  （EQManager 负责下发 native EQ / SFBAudioEngine EQ 两条后端）。
//
//  增益应用点：EQManager.effectiveGlobalGainDB = 用户预放大 + ReplayGain 偏移，
//  拆开叠加、互不覆盖；EQ 关闭（全 band bypass）时 ReplayGain 仍生效。
//

import Foundation
import Observation

@MainActor
@Observable
final class ReplayGainManager {
    static let shared = ReplayGainManager()

    /// 用户设置（改动即持久化 + 重算当前曲目增益）。
    private(set) var settings: ReplayGainSettings

    /// 当前曲目最终应用的 ReplayGain 增益（dB）。
    private(set) var currentTrackGainDB: Double = 0

    /// 当前曲目是否已有可用 ReplayGain 数据（标签或分析结果）。
    private(set) var currentTrackHasGainData = false

    @ObservationIgnored private var currentTrack: Track?

    private init() {
        settings = ReplayGainSettings.load()
    }

    /// 启动时调用：应用已存设置并恢复后台补算（不触碰音频图/播放链）。
    ///
    /// 单元测试环境跳过：xcodebuild test 下没有真实曲库，后台补算会做无意义读盘，
    /// 且会干扰共享 PlayerEngine 单例的测试（与 setupSiriIntegration 同一判定口径）。
    func activate() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        ReplayGainAnalysisQueue.shared.activate()
    }

    // MARK: - 设置写入

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { update { $0.isEnabled = newValue } }
    }

    var mode: ReplayGainMode {
        get { settings.mode }
        set { update { $0.mode = newValue } }
    }

    var preampDB: Double {
        get { settings.preampDB }
        set { update { $0.preampDB = ReplayGainMath.clampPreamp(newValue) } }
    }

    var preventClipping: Bool {
        get { settings.preventClipping }
        set { update { $0.preventClipping = newValue } }
    }

    var analyzeMissingTracks: Bool {
        get { settings.analyzeMissingTracks }
        set { update { $0.analyzeMissingTracks = newValue } }
    }

    private func update(_ mutate: (inout ReplayGainSettings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }
        settings = next
        next.save()
        recomputeCurrentTrackGain()
        if next.analyzeMissingTracks {
            ReplayGainAnalysisQueue.shared.resumeIfNeeded()
        } else {
            ReplayGainAnalysisQueue.shared.pause()
        }
    }

    // MARK: - 曲目切换

    /// 播放器切歌唯一入口（PlayerEngine.currentTrack didSet 调用）。
    ///
    /// 时序：切歌 / gapless promote 的同一 runloop 内设定增益，早于音频输出的
    /// 下一批渲染；gapless 边界无法预排两种增益（同一 EQ 节点），实测偏差 < 50ms。
    func trackDidChange(_ track: Track?) {
        currentTrack = track
        recomputeCurrentTrackGain()
    }

    /// 用当前曲目的最新数据（可能刚被后台补算补上）重算增益。
    func refreshCurrentTrackIfNeeded(stableId: String) {
        guard currentTrack?.stableId == stableId else { return }
        if let fresh = try? DatabaseManager.shared.getTrack(byStableId: stableId) {
            currentTrack = fresh
        }
        recomputeCurrentTrackGain()
    }

    private func recomputeCurrentTrackGain() {
        guard let track = currentTrack else {
            currentTrackHasGainData = false
            applyGain(0)
            return
        }
        let gains = Self.gains(for: track)
        currentTrackHasGainData = gains.hasAnyGain
        let gain = ReplayGainMath.resolveGain(
            gains,
            mode: settings.mode,
            preampDB: settings.preampDB,
            preventClipping: settings.preventClipping
        )
        applyGain(gain)

        if !gains.hasAnyGain && settings.analyzeMissingTracks {
            ReplayGainAnalysisQueue.shared.enqueue(track: track)
        }
    }

    private func applyGain(_ gain: Double) {
        guard abs(gain - currentTrackGainDB) > 0.001 else { return }
        currentTrackGainDB = gain
        EQManager.shared.replayGainOffset = gain
    }

    // MARK: - 计算

    /// 从 Track 取 ReplayGain 原始数据。
    static func gains(for track: Track) -> ReplayGainMath.Gains {
        ReplayGainMath.Gains(
            trackGain: track.replaygainTrackGain,
            trackPeak: track.replaygainTrackPeak,
            albumGain: track.replaygainAlbumGain,
            albumPeak: track.replaygainAlbumPeak
        )
    }

    /// 给 UI 展示：当前曲目若切到某模式的预览增益。
    func gain(for track: Track, mode: ReplayGainMode? = nil) -> Double {
        ReplayGainMath.resolveGain(
            Self.gains(for: track),
            mode: mode ?? settings.mode,
            preampDB: settings.preampDB,
            preventClipping: settings.preventClipping
        )
    }
}
