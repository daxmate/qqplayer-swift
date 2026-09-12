//
//  PlaybackRouter.swift
//  QQPlayer
//
//  格式识别（UI 展示用）。路由决策实际由 SFBAudioEngineManager.canHandle 决定。
//
//  已删除（2026-09-12 审计死代码 ⚰️-3）：PlaybackError / PlaybackStrategy /
//  determineStrategy(for:) —— 全仓 grep 仅命中定义处，零调用方。
//

import AVFoundation
import Foundation

/// Playback strategy pattern for different audio formats
class PlaybackRouter {
    /// Check if M4A file contains Opus codec
    static func isOpusInM4A(_ url: URL) -> Bool {
        // Check MP4 atoms for Opus codec
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }

        // Look for 'Opus' atom in MP4 structure
        // MP4 structure: ftyp → moov → trak → mdia → minf → stbl → stsd → Opus
        let opusSignature = "Opus".data(using: .ascii)!
        return data.range(of: opusSignature, in: 0 ..< min(data.count, 10000)) != nil
    }

    /// Get format information for UI display
    static func getFormatInfo(for url: URL) -> (format: String, badge: String?) {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            return ("FLAC", nil)
        case "mp3":
            return ("MP3", nil)
        case "wav":
            return ("WAV", nil)
        case "aac":
            return ("AAC", nil)
        case "m4a":
            if isOpusInM4A(url) {
                return ("Opus", "OPUS")
            } else {
                return ("AAC", nil)
            }
        case "opus":
            return ("Opus", "OPUS")
        case "ogg":
            // Could be Opus or Vorbis - would need deeper inspection
            return ("OGG", "OGG")
        case "dsf":
            return ("DSD", "DSD")
        case "dff":
            return ("DSDIFF", "DSD")
        default:
            return ("Unknown", nil)
        }
    }
}
