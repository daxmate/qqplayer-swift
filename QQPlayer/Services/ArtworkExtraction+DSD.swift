//
//  ArtworkExtraction+DSD.swift
//  QQPlayer
//
//  DSD / DSF 内嵌封面提取 + ID3v2 帧解析（自 ArtworkExtraction.swift 拆出）。
//  同族：ArtworkExtraction.swift（入口分派 + MP3/FLAC/M4A 提取）、
//        ArtworkExtraction+OpusVorbis.swift（Opus/OGG 提取 + Vorbis comment / FLAC picture 解析）。
//

import AVFoundation
import Foundation
import SFBAudioEngine
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

extension ArtworkManager {
    // MARK: - DSD Artwork Extraction

    /// 分片：跨文件可见（原 private）
    nonisolated func extractDSDArtwork(from url: URL) async -> ArtworkImage? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            // For DSF files, try ID3v2 APIC frame extraction first
            if url.pathExtension.lowercased() == "dsf" {
                if let artwork = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                    return artwork
                }
            }

            // Fallback to binary signature search for both DSF and DFF files
            AppLog.warn(.general, "⚠️ No ID3v2 artwork found, searching for binary signatures in: \(url.lastPathComponent)")

            // Image signatures to look for
            let jpegSignature = Data([0xFF, 0xD8, 0xFF])
            let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

            // Search for embedded images in DSD files
            let searchRange = 0 ..< min(data.count, 2097152) // Search first 2MB

            // Look for JPEG images
            if let jpegRange = data.range(of: jpegSignature, in: searchRange) {
                let startOffset = jpegRange.lowerBound

                // Look for JPEG end marker (FF D9)
                let jpegEndSignature = Data([0xFF, 0xD9])
                if let endRange = data.range(of: jpegEndSignature, in: startOffset ..< min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound
                    let imageData = data.subdata(in: startOffset ..< endOffset)

                    if let image = ArtworkImage(data: imageData) {
                        AppLog.info(.general, "🎨 Extracted JPEG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            // Look for PNG images
            if let pngRange = data.range(of: pngSignature, in: searchRange) {
                let startOffset = pngRange.lowerBound

                // PNG files end with IEND chunk (49 45 4E 44)
                let pngEndSignature = Data([0x49, 0x45, 0x4E, 0x44])
                if let endRange = data.range(of: pngEndSignature, in: startOffset ..< min(data.count, startOffset + 1048576)) {
                    let endOffset = endRange.upperBound + 4 // Include CRC after IEND
                    let imageData = data.subdata(in: startOffset ..< min(endOffset, data.count))

                    if let image = ArtworkImage(data: imageData) {
                        AppLog.info(.general, "🎨 Extracted PNG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            AppLog.warn(.general, "⚠️ No artwork found in DSD file: \(url.lastPathComponent)")
            return nil
        } catch {
            AppLog.error(.general, "❌ DSD artwork extraction failed: \(error)")
            return nil
        }
    }

    // Extract artwork from DSF file using ID3v2 APIC frames
    private nonisolated func extractDSFArtworkFromID3(data: Data, filename: String) -> ArtworkImage? {
        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            AppLog.warn(.general, "⚠️ Invalid DSF signature in: \(filename)")
            return nil
        }

        // Read metadata pointer from DSF header (little-endian at offset 20)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        guard metadataPointer > 0 && metadataPointer < data.count else {
            AppLog.warn(.general, "⚠️ No metadata pointer in DSF file: \(filename)")
            return nil
        }

        let metadataOffset = Int(metadataPointer)

        // Check for ID3v2 signature at metadata pointer
        guard data.count >= metadataOffset + 10,
              data[metadataOffset] == 0x49, // 'I'
              data[metadataOffset + 1] == 0x44, // 'D'
              data[metadataOffset + 2] == 0x33 else { // '3'
            AppLog.warn(.general, "⚠️ No ID3v2 tag found at metadata pointer in: \(filename)")
            return nil
        }

        AppLog.info(.general, "🏷️ Found ID3v2 tag in DSF file: \(filename)")

        let id3Data = data.subdata(in: metadataOffset ..< data.count)
        return extractArtworkFromID3v2(data: id3Data, filename: filename)
    }

    // Extract artwork from ID3v2 APIC frame
    private nonisolated func extractArtworkFromID3v2(data: Data, filename: String) -> ArtworkImage? {
        guard data.count >= 10 else { return nil }

        // Read ID3v2 header
        let majorVersion = data[3]
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🏷️ Searching for APIC frame in ID3v2.\(majorVersion) tag, size: \(tagSize) bytes") }

        // Parse frames to find APIC (attached picture)
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

            // Move to frame data
            offset += 10

            guard frameSize > 0 && offset + frameSize <= endOffset else {
                break
            }

            if frameId == "APIC" {
                AppLog.info(.general, "🎨 Found APIC frame in \(filename), size: \(frameSize) bytes")

                let frameData = data.subdata(in: offset ..< offset + frameSize)

                // Parse APIC frame structure:
                // [Encoding] [MIME type] [Picture type] [Description] [Picture data]
                var frameOffset = 1 // Skip encoding byte

                // Skip MIME type (null-terminated string)
                while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                    frameOffset += 1
                }
                frameOffset += 1 // Skip null terminator

                // Skip picture type (1 byte)
                frameOffset += 1

                // Skip description (null-terminated string, encoding-dependent)
                let encoding = frameData[0]
                if encoding == 1 || encoding == 2 { // UTF-16
                    // Look for double null bytes
                    while frameOffset < frameData.count - 1 && !(frameData[frameOffset] == 0 && frameData[frameOffset + 1] == 0) {
                        frameOffset += 1
                    }
                    frameOffset += 2 // Skip double null
                } else {
                    // Single byte encoding
                    while frameOffset < frameData.count && frameData[frameOffset] != 0 {
                        frameOffset += 1
                    }
                    frameOffset += 1 // Skip null terminator
                }

                // Extract image data
                guard frameOffset < frameData.count else {
                    AppLog.warn(.general, "⚠️ Invalid APIC frame structure in: \(filename)")
                    break
                }

                let imageData = frameData.subdata(in: frameOffset ..< frameData.count)

                if let image = ArtworkImage(data: imageData) {
                    AppLog.info(.general, "✅ Successfully extracted artwork from ID3v2 APIC frame: \(filename)")
                    return image
                } else {
                    AppLog.warn(.general, "⚠️ Could not create ArtworkImage from APIC data in: \(filename)")
                }
            }

            offset += frameSize
        }

        AppLog.warn(.general, "⚠️ No APIC frame found in ID3v2 tag: \(filename)")
        return nil
    }

    // Safe byte reading helper for DSF format (little-endian)
    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            AppLog.warn(.general, "⚠️ Invalid byte access in artwork: offset=\(offset), dataSize=\(data.count)")
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
}
