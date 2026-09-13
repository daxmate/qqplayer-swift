//
//  AudioMetadataParser+Basic.swift
//  QQPlayer
//
//  基础解析域：内嵌封面检测、文件名基础解析（避免 SFB 解析挂起）。
//

import Foundation

extension AudioMetadataParser {
    // Simple artwork detection for supported formats
    static func checkForEmbeddedArtwork(url: URL) async -> Bool {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let ext = url.pathExtension.lowercased()

            // Common image format signatures
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            if ext == "opus" || ext == "ogg" {
                // OGG/Opus files use Vorbis Comments with base64-encoded METADATA_BLOCK_PICTURE
                // Search for "METADATA_BLOCK_PICTURE=" tag
                let pictureTag = Data("METADATA_BLOCK_PICTURE=".utf8)
                if data.range(of: pictureTag) != nil {
                    return true
                }
                return false
            } else if ext == "dsf" {
                // DSF files: artwork is typically stored after the format chunk
                // DSF signature: "DSD " (44 53 44 20)
                let dsfSignature = Data([0x44, 0x53, 0x44, 0x20])
                if data.starts(with: dsfSignature) {
                    // Search for image signatures in the file (DSF can contain embedded artwork)
                    let searchRange = 0 ..< min(data.count, 1048576) // Search first 1MB
                    return data.range(of: jpegSignature, in: searchRange) != nil ||
                        data.range(of: pngSignature, in: searchRange) != nil
                }
            } else if ext == "dff" {
                // DSDIFF files: look for ID3v2 tags or artwork chunks
                // DSDIFF signature: "FRM8" + "DSD "
                if data.count >= 12 {
                    let frm8Signature = Data([0x46, 0x52, 0x4D, 0x38]) // "FRM8"
                    let dsdSignature = Data([0x44, 0x53, 0x44, 0x20])   // "DSD "

                    if data.starts(with: frm8Signature) &&
                        data.subdata(in: 8 ..< 12) == dsdSignature {
                        // Search for image signatures in DSDIFF file
                        let searchRange = 0 ..< min(data.count, 1048576) // Search first 1MB
                        return data.range(of: jpegSignature, in: searchRange) != nil ||
                            data.range(of: pngSignature, in: searchRange) != nil
                    }
                }
            }

            return false
        } catch {
            print("⚠️ Artwork detection failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    // Parse basic metadata from filename (for SFBAudioEngine formats to avoid hangs)
    static func parseBasicMetadata(_ url: URL, format: String) async throws -> AudioMetadata {
        print("📖 Reading basic metadata for \(format): \(url.lastPathComponent)")

        // Use filename parsing for all SFBAudioEngine formats
        let filename = url.deletingPathExtension().lastPathComponent
        var title = filename
        var artist: String?

        // Try to parse "Artist - Title" format
        let components = filename.components(separatedBy: " - ")
        if components.count >= 2 {
            artist = components[0].trimmingCharacters(in: .whitespaces)
            title = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }

        // Basic properties - don't assume sample rate as it's crucial for timing
        let ext = url.pathExtension.lowercased()
        let sampleRate = 0      // Unknown - will be determined by audio engine during playback
        let channels = 0        // Unknown - will be determined during playback
        var bitDepth: Int?

        switch ext {
        case "opus", "ogg", "m4a":
            bitDepth = nil      // Lossy format
        default:
            break
        }

        // Check for embedded artwork in supported formats
        var hasEmbeddedArt = false
        if ext == "opus" || ext == "ogg" {
            // These formats can have embedded artwork, check with basic methods
            hasEmbeddedArt = await checkForEmbeddedArtwork(url: url)
        }

        print("🎵 Basic metadata for \(url.lastPathComponent):")
        print("   Title: \(title)")
        print("   Artist: \(artist ?? "Unknown")")
        print("   Format: \(format)")
        print("   Sample Rate: Unknown (will be detected during playback)")
        print("   Has Artwork: \(hasEmbeddedArt)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: nil,
            albumArtist: artist,
            genre: nil,
            trackNumber: nil,
            discNumber: nil,
            year: nil,
            durationMs: 0,  // Duration will be calculated during playback
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

}
