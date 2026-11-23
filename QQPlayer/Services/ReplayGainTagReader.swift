//
//  ReplayGainTagReader.swift
//  QQPlayer
//
//  ReplayGain 数据来源：
//   1. 文件标签读取（SFBAudioEngine 元数据，覆盖 MP3 TXXX / M4A / FLAC / Ogg 等）；
//   2. 本地分析（SFBAudioEngine ReplayGainAnalyzer，ITU BS.1770，参考电平 -18 LUFS）。
//
//  只读：绝不改写用户音频文件标签；分析结果写本地 DB。
//

import Foundation
import SFBAudioEngine

enum ReplayGainTagReader {
    /// 读取文件标签里的 ReplayGain（track/album gain + peak）。无数据 → nil。
    ///
    /// 走 SFBAudioEngine 元数据接口：AVFoundation 拿不到 MP3 TXXX、M4A 的
    /// `----:com.apple.iTunes:replaygain_track_gain` 这类自定义标签。
    static func readGains(from url: URL) -> ReplayGainMath.Gains? {
        guard let file = try? SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url) else {
            return nil
        }
        let metadata = file.metadata
        let gains = ReplayGainMath.Gains(
            trackGain: metadata.replayGainTrackGain,
            trackPeak: metadata.replayGainTrackPeak,
            albumGain: metadata.replayGainAlbumGain,
            albumPeak: metadata.replayGainAlbumPeak
        )
        return gains.hasAnyGain ? gains : nil
    }

    /// 分析单曲（阻塞；调用方必须放到后台任务，勿在主线程跑）。
    ///
    /// 返回 track gain/peak（album 字段留空）。
    static func analyzeTrack(url: URL) throws -> ReplayGainMath.Gains {
        let replayGain = try ReplayGainAnalyzer.analyzeTrack(url)
        return ReplayGainMath.Gains(
            trackGain: Double(replayGain.gain),
            trackPeak: Double(replayGain.peak)
        )
    }

    /// 分析整张专辑（阻塞；调用方必须放到后台任务）。
    ///
    /// 返回 album gain/peak（track 字段留空）。
    static func analyzeAlbum(urls: [URL]) throws -> ReplayGainMath.Gains {
        let albumReplayGain = try ReplayGainAnalyzer.analyzeAlbum(urls)
        return ReplayGainMath.Gains(
            albumGain: Double(albumReplayGain.replayGain.gain),
            albumPeak: Double(albumReplayGain.replayGain.peak)
        )
    }
}
