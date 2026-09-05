//
//  AudioMetadataParser.swift
//  QQPlayer
//
//  音频元数据解析：入口与格式分发（FLAC→FLAC 域、MP3/WAV→MP3WAV 域、
//  Opus/Vorbis→基础解析域、DSD→DSD 域）+ AudioMetadata/AudioParseError。
//  拆分见 AudioMetadataParser+FLAC/MP3WAV/DSD/Basic.swift。
//

import Foundation

struct AudioMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let genre: String?
    let trackNumber: Int?
    let discNumber: Int?
    let year: Int?
    let durationMs: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let replaygainTrackGain: Double?
    let replaygainAlbumGain: Double?
    let replaygainTrackPeak: Double?
    let replaygainAlbumPeak: Double?
    let hasEmbeddedArt: Bool
}

class AudioMetadataParser {
    /// Genre 归一化：去掉首尾空白；空串/纯空白 → nil。web 版缺失 genre 时默认 ""，
    /// Swift 端统一用 nil 表达"无流派"（与其它可选字段语义一致），避免空串落库。
    static func normalizedGenre(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseMetadata(from url: URL) async throws -> AudioMetadata {
        return try await parseAudioMetadataSync(from: url)
    }

    private static func parseAudioMetadataSync(from url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        // Native formats
        case "flac", "mp3", "wav", "aac":
            return try await parseNativeFormat(url)

        case "m4a":
            // Detect if AAC or Opus
            if isOpusInM4A(url) {
                return try await parseBasicMetadata(url, format: "Opus") // Opus → Basic parsing
            } else {
                return try await parseAacMetadata(url)  // AAC → Native
            }

        // SFBAudioEngine formats (but use basic parsing for metadata to avoid hangs)
        case "opus", "ogg":
            return try await parseBasicMetadata(url, format: "Opus/Vorbis")

        case "dsf", "dff":
            return try await parseDSDBasicMetadata(url)

        default:
            throw AudioParseError.unsupportedFormat
        }
    }

    // MARK: - New Format Support Methods

    // Unified parser for native formats (routes to existing parsers)
    private static func parseNativeFormat(_ url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "flac":
            return try await parseFlacMetadataSync(from: url)
        case "mp3":
            return try await parseMp3MetadataSync(from: url)
        case "wav":
            return try await parseWavMetadataSync(from: url)
        case "aac":
            return try await parseAacMetadata(url)
        default:
            throw AudioParseError.unsupportedFormat
        }
    }

    // Check if M4A contains Opus codec
    private static func isOpusInM4A(_ url: URL) -> Bool {
        // Check MP4 atoms for Opus codec
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }

        // Look for 'Opus' atom in MP4 structure
        // MP4 structure: ftyp → moov → trak → mdia → minf → stbl → stsd → Opus
        let opusSignature = "Opus".data(using: .ascii)!
        return data.range(of: opusSignature, in: 0 ..< min(data.count, 10000)) != nil
    }

    // Parse AAC metadata using native AVFoundation
    private static func parseAacMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading AAC metadata for: \(url.lastPathComponent)")

        // Use similar logic to MP3 parsing since AAC can have similar metadata
        return try await parseMp3MetadataSync(from: url)
    }
}

enum AudioParseError: Error {
    case invalidFile
    case unsupportedFormat
    case fileNotReadable
    case fileSizeError
}
