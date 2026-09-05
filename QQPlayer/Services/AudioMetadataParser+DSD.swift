//
//  AudioMetadataParser+DSD.swift
//  QQPlayer
//
//  DSD 解析域：DSF 头/ID3v2 标签解析、文本帧解码、little-endian 读取辅助
//  （parseDSDMetadata 已废弃但保留）。
//

import Foundation
import SFBAudioEngine

extension AudioMetadataParser {
    // Parse DSD metadata with proper ID3v2 tag extraction from DSF files
    static func parseDSDBasicMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading DSD metadata with ID3v2 extraction for: \(url.lastPathComponent)")

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false
        var sampleRate = 0
        var channels = 0
        let bitDepth = 1  // DSD is always 1-bit

        // Try to extract metadata from DSF file
        if url.pathExtension.lowercased() == "dsf" {
            do {
                let metadata = try await extractDSFMetadata(from: url)
                title = metadata.title
                artist = metadata.artist
                album = metadata.album
                albumArtist = metadata.albumArtist
                trackNumber = metadata.trackNumber
                discNumber = metadata.discNumber
                year = metadata.year
                hasEmbeddedArt = metadata.hasEmbeddedArt
                sampleRate = metadata.sampleRate
                channels = metadata.channels
                print("✅ Successfully extracted DSF metadata for: \(url.lastPathComponent)")
            } catch {
                print("⚠️ Failed to extract DSF metadata, falling back to filename parsing: \(error)")
            }
        }

        // Fallback to filename parsing if metadata extraction failed
        if title == nil {
            let filename = url.deletingPathExtension().lastPathComponent
            title = filename

            // Try to parse "Artist - Title" format
            let components = filename.components(separatedBy: " - ")
            if components.count >= 2 {
                artist = components[0].trimmingCharacters(in: .whitespaces)
                title = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }

        // Check for embedded artwork if not already determined
        if !hasEmbeddedArt {
            hasEmbeddedArt = await checkForEmbeddedArtwork(url: url)
        }

        print("🎵 DSD metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "Unknown")")
        print("   Artist: \(artist ?? "Unknown")")
        print("   Album: \(album ?? "Unknown")")
        print("   Track: \(trackNumber?.description ?? "Unknown")")
        print("   Sample Rate: \(sampleRate > 0 ? "\(sampleRate) Hz" : "Unknown")")
        print("   Channels: \(channels > 0 ? "\(channels)" : "Unknown")")
        print("   Has Artwork: \(hasEmbeddedArt)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: nil,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
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

    // Extract metadata from DSF file using DSF format specification and ID3v2 tags
    private static func extractDSFMetadata(from url: URL) async throws -> (title: String?, artist: String?, album: String?, albumArtist: String?, trackNumber: Int?, discNumber: Int?, year: Int?, hasEmbeddedArt: Bool, sampleRate: Int, channels: Int) {
        // Add memory safety check - avoid large file loading during startup if low memory
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if fileSize > 50_000_000 { // Skip files larger than 50MB to prevent memory pressure
            print("⚠️ Skipping large DSF file during startup: \(url.lastPathComponent) (\(fileSize) bytes)")
            return (nil, nil, nil, nil, nil, nil, nil, false, 0, 0)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            throw AudioParseError.unsupportedFormat
        }

        // Read DSF header (little-endian) with safe byte-by-byte reading
        let chunkSize = readLittleEndianUInt64(from: data, offset: 4)
        let totalFileSize = readLittleEndianUInt64(from: data, offset: 12)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        print("📊 DSF Header Analysis for \(url.lastPathComponent):")
        print("   Chunk Size: \(chunkSize)")
        print("   Total File Size: \(totalFileSize)")
        print("   Metadata Pointer: \(metadataPointer)")

        // Parse format chunk to get sample rate and channels
        var sampleRate = 0
        var channels = 0

        // Look for fmt chunk after DSD chunk (at offset 28)
        if data.count >= 52 &&
            data[28] == 0x66 && data[29] == 0x6D && data[30] == 0x74 && data[31] == 0x20 { // "fmt "

            let fmtChunkSize = readLittleEndianUInt64(from: data, offset: 32)

            if fmtChunkSize >= 52 {
                let formatVersion = readLittleEndianUInt32(from: data, offset: 40)
                let formatId = readLittleEndianUInt32(from: data, offset: 44)
                let channelType = readLittleEndianUInt32(from: data, offset: 48)
                let channelNum = readLittleEndianUInt32(from: data, offset: 52)
                let sampleFrequency = readLittleEndianUInt32(from: data, offset: 56)

                sampleRate = Int(sampleFrequency)
                channels = Int(channelNum)

                print("   Format Version: \(formatVersion)")
                print("   Format ID: \(formatId)")
                print("   Channel Type: \(channelType)")
                print("   Channels: \(channels)")
                print("   Sample Rate: \(sampleRate) Hz")
            }
        }

        // Parse ID3v2 metadata if metadata pointer is valid
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false

        if metadataPointer > 0 && metadataPointer < data.count {
            let metadataOffset = Int(metadataPointer)

            // Check for ID3v2 signature at metadata pointer
            if data.count >= metadataOffset + 10 &&
                data[metadataOffset] == 0x49 && data[metadataOffset + 1] == 0x44 && data[metadataOffset + 2] == 0x33 { // "ID3"

                print("🏷️ Found ID3v2 tag at offset \(metadataOffset)")

                let id3Data = data.subdata(in: metadataOffset ..< data.count)
                let parsedTags = parseID3v2Tags(from: id3Data)

                title = parsedTags.title
                artist = parsedTags.artist
                album = parsedTags.album
                albumArtist = parsedTags.albumArtist
                trackNumber = parsedTags.trackNumber
                discNumber = parsedTags.discNumber
                year = parsedTags.year
                hasEmbeddedArt = parsedTags.hasArtwork
            }
        }

        return (
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            hasEmbeddedArt: hasEmbeddedArt,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    // Parse ID3v2 tags from binary data
    private static func parseID3v2Tags(from data: Data) -> (title: String?, artist: String?, album: String?, albumArtist: String?, trackNumber: Int?, discNumber: Int?, year: Int?, hasArtwork: Bool) {
        guard data.count >= 10 else { return (nil, nil, nil, nil, nil, nil, nil, false) }

        // Read ID3v2 header
        let majorVersion = data[3]
        let revision = data[4]
        let flags = data[5]

        // Read size (synchsafe integer)
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ ID3v2.\(majorVersion).\(revision) tag, size: \(tagSize) bytes, flags: 0x\(String(flags, radix: 16))")

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasArtwork = false

        // Parse frames (starting from offset 10)
        var offset = 10
        let endOffset = min(data.count, 10 + tagSize)

        while offset < endOffset - 10 {
            // Read frame header (10 bytes for v2.3/v2.4)
            let frameId = String(data: data.subdata(in: offset ..< offset + 4), encoding: .ascii) ?? ""

            let frameSize: Int
            if majorVersion >= 4 {
                // ID3v2.4 uses synchsafe integers for frame size
                frameSize = Int((UInt32(data[offset + 4]) << 21) | (UInt32(data[offset + 5]) << 14) | (UInt32(data[offset + 6]) << 7) | UInt32(data[offset + 7]))
            } else {
                // ID3v2.3 uses regular 32-bit big-endian integer
                frameSize = Int((UInt32(data[offset + 4]) << 24) | (UInt32(data[offset + 5]) << 16) | (UInt32(data[offset + 6]) << 8) | UInt32(data[offset + 7]))
            }

            _ = (UInt16(data[offset + 8]) << 8) | UInt16(data[offset + 9])

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            let frameData = data.subdata(in: offset ..< offset + frameSize)

            // Parse frame based on ID
            switch frameId {
            case "TIT2": // Title
                title = parseTextFrame(frameData)
            case "TPE1": // Artist
                artist = parseTextFrame(frameData)
            case "TALB": // Album
                album = parseTextFrame(frameData)
            case "TPE2": // Album Artist
                albumArtist = parseTextFrame(frameData)
            case "TRCK": // Track number
                if let trackString = parseTextFrame(frameData) {
                    trackNumber = Int(trackString.components(separatedBy: "/").first ?? "")
                }
            case "TPOS": // Disc number
                if let discString = parseTextFrame(frameData) {
                    discNumber = Int(discString.components(separatedBy: "/").first ?? "")
                }
            case "TYER", "TDRC": // Year (TYER in v2.3, TDRC in v2.4)
                if let yearString = parseTextFrame(frameData) {
                    year = Int(String(yearString.prefix(4)))
                }
            case "APIC": // Attached picture
                hasArtwork = true
                print("🎨 Found embedded artwork in ID3v2 tag")
            default:
                break
            }

            offset += frameSize
        }

        print("🎵 Parsed ID3v2 metadata:")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        print("   Track: \(trackNumber?.description ?? "nil")")
        print("   Year: \(year?.description ?? "nil")")
        print("   Has Artwork: \(hasArtwork)")

        return (title, artist, album, albumArtist, trackNumber, discNumber, year, hasArtwork)
    }

    // Parse text frame data handling different encodings
    private static func parseTextFrame(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        let encoding = data[0]
        let textData = data.subdata(in: 1 ..< data.count)

        switch encoding {
        case 0: // ISO-8859-1
            return String(data: textData, encoding: .isoLatin1)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 1: // UTF-16 with BOM
            return String(data: textData, encoding: .utf16)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 2: // UTF-16BE without BOM
            return String(data: textData, encoding: .utf16BigEndian)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        case 3: // UTF-8
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        default:
            // Fallback to UTF-8
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        }
    }

    // Safe byte reading helpers for DSF format (little-endian)
    private static func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt64(data[offset])
        let byte1 = UInt64(data[offset + 1]) << 8
        let byte2 = UInt64(data[offset + 2]) << 16
        let byte3 = UInt64(data[offset + 3]) << 24
        let byte4 = UInt64(data[offset + 4]) << 32
        let byte5 = UInt64(data[offset + 5]) << 40
        let byte6 = UInt64(data[offset + 6]) << 48
        let byte7 = UInt64(data[offset + 7]) << 56

        return byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
    }

    private static func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            print("⚠️ Invalid byte access: offset=\(offset), dataSize=\(data.count)")
            return 0
        }

        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24

        return byte0 | byte1 | byte2 | byte3
    }

    // Parse DSD metadata with SFBAudioEngine (DEPRECATED - causes hangs)
    private static func parseDSDMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading DSD metadata for: \(url.lastPathComponent)")

        do {
            // Create DSD decoder
            let decoder = try SFBAudioEngine.AudioDecoder(url: url)

            // Extract properties
            let sourceFormat = decoder.sourceFormat
            _ = decoder.processingFormat

            let sampleRate = Int(sourceFormat.sampleRate)
            let channels = Int(sourceFormat.channelCount)
            // Duration calculation for DSD - using properties if available
            let durationSeconds = 0.0  // Duration not directly available from AudioDecoder

            // DSD is 1-bit, but we report the effective resolution
            let bitDepth = 1

            print("🎵 DSD metadata for \(url.lastPathComponent):")
            print("   Sample Rate: \(sampleRate) Hz (DSD)")
            print("   Channels: \(channels)")
            print("   Duration: \(durationSeconds) seconds")
            print("   Format: DSD (1-bit)")

            // For DSD files, metadata is limited, so use filename parsing
            let filename = url.deletingPathExtension().lastPathComponent
            let title = filename

            return AudioMetadata(
                title: title,
                artist: nil,
                album: nil,
                albumArtist: nil,
                genre: nil,
                trackNumber: nil,
                discNumber: nil,
                year: nil,
                durationMs: Int(durationSeconds * 1000),
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                channels: channels,
                replaygainTrackGain: nil,
                replaygainAlbumGain: nil,
                replaygainTrackPeak: nil,
                replaygainAlbumPeak: nil,
                hasEmbeddedArt: false
            )

        } catch {
            print("❌ DSD parsing failed: \(error)")
            throw AudioParseError.invalidFile
        }
    }
}
