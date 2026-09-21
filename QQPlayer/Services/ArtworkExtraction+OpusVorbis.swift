//
//  ArtworkExtraction+OpusVorbis.swift
//  QQPlayer
//
//  Opus / OGG 内嵌封面提取 + Vorbis comment 与 FLAC picture 块解析（自 ArtworkExtraction.swift 拆出）。
//  同族：ArtworkExtraction.swift（入口分派 + MP3/FLAC/M4A 提取）、
//        ArtworkExtraction+DSD.swift（DSD/DSF 提取 + ID3v2 解析）。
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
    // MARK: - Generic Artwork Extraction (Opus, OGG, etc.)

    /// 分片：跨文件可见（原 private）
    nonisolated func extractGenericArtwork(from url: URL) async -> ArtworkImage? {
        // Use SFBAudioEngine's TagLib-backed metadata reader. The previous
        // hand-rolled byte scan corrupted any METADATA_BLOCK_PICTURE larger
        // than one Ogg page (~64KB): the base64 payload is interleaved with
        // Ogg page headers, which the scan couldn't strip (issue #75).
        do {
            let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
            let pictures = audioFile.metadata.attachedPictures
            let preferred = pictures.first(where: { $0.type == .frontCover }) ?? pictures.first
            if let preferred, let image = ArtworkImage(data: preferred.imageData) {
                AppLog.info(.general, "✅ Extracted artwork via SFBAudioEngine metadata: \(url.lastPathComponent) (\(preferred.imageData.count) bytes)")
                return image
            }
        } catch {
            AppLog.warn(.general, "⚠️ SFBAudioEngine metadata read failed for \(url.lastPathComponent): \(error)")
        }

        // Fallback: legacy Vorbis comment scan (works for single-page pictures)
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let artwork = extractVorbisCommentArtwork(from: data, filename: url.lastPathComponent) {
                return artwork
            }

            AppLog.warn(.general, "⚠️ No artwork found in Vorbis comments: \(url.lastPathComponent)")
            return nil
        } catch {
            AppLog.error(.general, "❌ Generic artwork extraction failed: \(error)")
            return nil
        }
    }

    // Extract artwork from Vorbis Comments (OGG/Opus)
    private nonisolated func extractVorbisCommentArtwork(from data: Data, filename: String) -> ArtworkImage? {
        // In Vorbis comments, each field has format: [4 bytes length][field name]=[field value]
        // We need to read the length to get the complete value, not just stop at null byte

        // Search for "METADATA_BLOCK_PICTURE=" tag
        let pictureTagData = Data("METADATA_BLOCK_PICTURE=".utf8)

        guard let tagRange = data.range(of: pictureTagData) else {
            AppLog.warn(.general, "⚠️ No METADATA_BLOCK_PICTURE tag found in: \(filename)")
            return nil
        }

        // The value starts right after the "=" sign
        let valueStart = tagRange.upperBound

        // In Vorbis comments, the length is stored BEFORE the tag name
        // Go back to read the length field (4 bytes little-endian before tag name starts)
        let lengthOffset = tagRange.lowerBound - 4

        var valueLength: Int
        if lengthOffset >= 0 && lengthOffset + 4 <= data.count {
            // Read 4-byte little-endian length
            valueLength = Int(readLittleEndianUInt32(from: data, offset: lengthOffset))
            // Subtract the tag name length ("METADATA_BLOCK_PICTURE=".count)
            valueLength -= pictureTagData.count
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Read Vorbis comment length field: \(valueLength) bytes") }
        } else {
            // Fallback: find null byte terminator
            var valueEnd = valueStart
            while valueEnd < data.count {
                let byte = data[valueEnd]
                if byte == 0x00 {
                    break
                }
                valueEnd += 1
            }
            valueLength = valueEnd - valueStart
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Using null-terminated length: \(valueLength) bytes") }
        }

        guard valueLength > 0 && valueStart + valueLength <= data.count else {
            AppLog.warn(.general, "⚠️ Invalid METADATA_BLOCK_PICTURE length in: \(filename)")
            return nil
        }

        // Extract the value data with correct length
        let valueData = data.subdata(in: valueStart ..< valueStart + valueLength)

        // Check if this is binary data (starts with 0x00 0x00 0x00) or base64 text
        // Binary format starts with picture type as 4 bytes (usually 0x00000003 for front cover)
        // Base64 will start with ASCII letters like 'A' (0x41)
        let isBinary = valueData.count >= 4 &&
            valueData[0] == 0x00 &&
            valueData[1] == 0x00 &&
            valueData[2] == 0x00

        let pictureBlockData: Data

        if isBinary {
            // Data is already in binary format (some tools store it this way)
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Detected binary METADATA_BLOCK_PICTURE format (starts with 0x00) in: \(filename)") }
            pictureBlockData = valueData
        } else {
            // Try to decode as base64-encoded (standard format)
            // Filter data to only valid base64 characters (A-Z, a-z, 0-9, +, /, =)
            // This handles cases where null bytes or other characters are mixed in
            let validBase64Chars: Set<UInt8> = Set(
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8
            )

            var filteredData = Data(valueData.filter { validBase64Chars.contains($0) })
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Filtered base64 data: \(valueData.count) → \(filteredData.count) bytes") }

            // Add padding to make length a multiple of 4 (required for base64)
            let remainder = filteredData.count % 4
            if remainder > 0 {
                let paddingNeeded = 4 - remainder
                let paddingBytes = Data(repeating: UInt8(ascii: "="), count: paddingNeeded)
                filteredData.append(paddingBytes)
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Added \(paddingNeeded) padding bytes, new length: \(filteredData.count)") }
            }

            // Try to decode the filtered and padded data
            if let decoded = Data(base64Encoded: filteredData, options: .ignoreUnknownCharacters) {
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Successfully decoded base64 METADATA_BLOCK_PICTURE, size: \(decoded.count) bytes") }
                pictureBlockData = decoded
            } else {
                AppLog.warn(.general, "⚠️ Failed to decode filtered base64, treating as binary in: \(filename)")
                // Last resort: treat as binary data
                pictureBlockData = valueData
            }
        }

        AppLog.info(.general, "🎨 Found METADATA_BLOCK_PICTURE in \(filename), size: \(pictureBlockData.count) bytes")

        // Parse FLAC picture block structure
        return parseFLACPictureBlock(data: pictureBlockData, filename: filename)
    }

    // Parse FLAC picture block structure (RFC 9639)
    private nonisolated func parseFLACPictureBlock(data: Data, filename: String) -> ArtworkImage? {
        var offset = 0

        guard data.count >= 32 else {
            AppLog.warn(.general, "⚠️ METADATA_BLOCK_PICTURE too small: \(filename)")
            return nil
        }

        // Read picture type (32 bits, big-endian)
        let pictureType = readBigEndianUInt32(from: data, offset: offset)
        offset += 4
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🖼️ Picture type: \(pictureType)") }

        // Read MIME type length (32 bits, big-endian)
        let mimeLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        guard offset + mimeLength <= data.count else {
            AppLog.warn(.general, "⚠️ Invalid MIME type length in: \(filename)")
            return nil
        }

        // Read MIME type string
        let mimeData = data.subdata(in: offset ..< offset + mimeLength)
        let mimeType = String(data: mimeData, encoding: .utf8) ?? ""
        offset += mimeLength
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🖼️ MIME type: \(mimeType)") }

        // Read description length (32 bits, big-endian)
        guard offset + 4 <= data.count else {
            AppLog.warn(.general, "⚠️ Not enough data for description length field")
            return nil
        }
        let descLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🖼️ Description length: \(descLength)") }

        // Skip description
        guard offset + descLength <= data.count else {
            AppLog.warn(.general, "⚠️ Invalid description length")
            return nil
        }
        offset += descLength

        // Skip width, height, color depth, number of colors (4 × 32 bits = 16 bytes)
        guard offset + 16 <= data.count else {
            AppLog.warn(.general, "⚠️ Not enough data for image dimensions")
            return nil
        }
        offset += 16

        // Read picture data length (32 bits, big-endian)
        guard offset + 4 <= data.count else {
            AppLog.warn(.general, "⚠️ Not enough data for picture length field")
            return nil
        }
        let pictureLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🖼️ Picture data length field: \(pictureLength) bytes") }
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🖼️ Current offset: \(offset), Total data size: \(data.count), Remaining: \(data.count - offset)") }

        // Extract picture data - use remaining data if length field is incorrect
        let actualPictureLength: Int
        if offset + pictureLength <= data.count {
            actualPictureLength = pictureLength
        } else {
            // Length field is wrong - just use all remaining data
            actualPictureLength = data.count - offset
            AppLog.warn(.general, "⚠️ Picture length field incorrect, using all remaining \(actualPictureLength) bytes")
        }

        // Extract picture data
        let pictureData = data.subdata(in: offset ..< offset + actualPictureLength)

        if let image = ArtworkImage(data: pictureData) {
            AppLog.info(.general, "✅ Successfully extracted \(mimeType) artwork from Vorbis comments: \(filename)")
            return image
        } else {
            AppLog.warn(.general, "⚠️ Could not create ArtworkImage from picture data in: \(filename)")
            return nil
        }
    }

    // Read 32-bit big-endian unsigned integer
    private nonisolated func readBigEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            return 0
        }

        let byte0 = UInt32(data[offset]) << 24
        let byte1 = UInt32(data[offset + 1]) << 16
        let byte2 = UInt32(data[offset + 2]) << 8
        let byte3 = UInt32(data[offset + 3])

        return byte0 | byte1 | byte2 | byte3
    }

    // Read 32-bit little-endian unsigned integer (for Vorbis comments)
    private nonisolated func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else {
            return 0
        }

        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24

        return byte0 | byte1 | byte2 | byte3
    }
}
