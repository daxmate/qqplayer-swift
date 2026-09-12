//  PlaybackModels.swift
//  QQPlayer
//
//  Playback models used by PlayerEngine: playback order modes, the fast
//  playback-position observable, and playback errors.
//
import Combine
import Foundation

/// 播放顺序四态：顺序播放 → 随机播放 → 循环列表 → 单曲循环 → 顺序播放
enum PlaybackOrderMode: Int, CaseIterable {
    case sequential = 0
    case shuffle = 1
    case repeatAll = 2
    case repeatOne = 3
}

/// Holds the fast-changing playback position so that only views showing the
/// progress bar/time labels re-render at the 10Hz timer rate. Observing
/// PlayerEngine itself must not subscribe views to these updates.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var playbackTime: TimeInterval = 0
}

enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
    case audioEngineError
    case configurationError
}

/// 异步落地前的同曲校验（纯函数，可单测）。
///
/// 背景（2026-09-12 审计 P5）：updateWidgetData 在函数入口捕获 track，中间经历
/// await 取封面 + 两次后台写盘，期间没有同曲校验 → 快速连点/自动切歌时，先发起的旧曲
/// 任务后落盘（saveCurrentTrack 同步写盘 + reloadAllTimelines），小组件显示上一首
/// 并一直保留到下次更新。入队时校验一次目标曲仍是当前曲，才允许写。
enum PlaybackTrackGate {
    static func isStillCurrent(trackId: String, currentTrackId: String?) -> Bool {
        trackId == currentTrackId
    }
}

/// 载入失败 → 用户可见文案 key（纯函数，可单测）。
///
/// 背景（2026-09-12 审计 P8）：DSD（dsf/dff）在本项目里没有任何可用引擎——native
/// `AVAudioFile` 打不开（openNativeAudioFile 对 dsf/dff 直接拒），SFB 失败时原本那条
/// "native fallback" 构造上必失败（被删，见 PlayerEngine+PlaybackControl）。原来失败全链
/// 只有 print，`playTrack` 拿到 false 就 return → 用户只看到“点了不播”。
enum PlaybackFailureMessage {
    static func messageKey(pathExtension: String) -> String {
        let ext = pathExtension.lowercased()
        if ext == "dsf" || ext == "dff" {
            return "playback_error_dsd_unsupported"
        }
        return "playback_error_generic"
    }
}
