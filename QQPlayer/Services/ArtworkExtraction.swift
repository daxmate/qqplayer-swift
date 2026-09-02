//
//  ArtworkExtraction.swift
//  QQPlayer
//
//  从音频文件提取内嵌封面（MP3/FLAC/M4A/DSD/Opus 等）以及
//  ID3v2/Vorbis/FLAC picture 块解析。
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
    nonisolated func extractArtwork(from url: URL) async -> ArtworkImage? {
        let ext = url.pathExtension.lowercased()

        let embedded: ArtworkImage?
        if ext == "flac" {
            embedded = await extractFlacArtwork(from: url)
        } else if ext == "mp3" {
            embedded = await extractMp3Artwork(from: url)
        } else if ext == "m4a" || ext == "mp4" || ext == "aac" {
            embedded = await extractM4AArtwork(from: url)
        } else if ext == "dsf" || ext == "dff" {
            embedded = await extractDSDArtwork(from: url)
        } else if ext == "opus" || ext == "ogg" {
            embedded = await extractGenericArtwork(from: url)
        } else {
            embedded = nil
        }

        if let embedded {
            return embedded
        }
        // 内嵌封面缺失时兜底：同目录 cover.jpg / cover.png / folder.jpg（对齐 web 版行为）
        return Self.coverImage(inDirectoryOf: url)
    }

    /// 查找音频同目录的封面图（cover.jpg / cover.png / folder.jpg），无则 nil。
    nonisolated static func coverImage(inDirectoryOf audioURL: URL) -> ArtworkImage? {
        let directory = audioURL.deletingLastPathComponent()
        let candidates = ["cover.jpg", "cover.png", "folder.jpg", "front.jpg"]
        for name in candidates {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate),
               let image = ArtworkImage(data: data) {
                return image
            }
        }
        return nil
    }

    private nonisolated func extractMp3Artwork(from url: URL) async -> ArtworkImage? {
        return await withCheckedContinuation { continuation in
            Task {
                let asset = AVURLAsset(url: url)

                do {
                    let metadata = try await asset.load(.commonMetadata)

                    for item in metadata where item.commonKey == .commonKeyArtwork {
                        do {
                            if let data = try await item.load(.dataValue),
                               let image = ArtworkImage(data: data) {
                                continuation.resume(returning: image)
                                return
                            }
                        } catch {
                            print("Failed to load artwork data: \(error)")
                        }
                    }

                    continuation.resume(returning: nil)
                } catch {
                    print("Failed to load MP3 metadata: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated func extractFlacArtwork(from url: URL) async -> ArtworkImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)

                    if data.count < 42 {
                        continuation.resume(returning: nil)
                        return
                    }

                    var offset = 4

                    while offset < data.count {
                        let blockHeader = data[offset]
                        let isLast = (blockHeader & 0x80) != 0
                        let blockType = blockHeader & 0x7F

                        offset += 1

                        guard offset + 3 <= data.count else { break }

                        let blockSize = Int(data[offset]) << 16 | Int(data[offset + 1]) << 8 | Int(data[offset + 2])
                        offset += 3

                        if blockType == 6 { // PICTURE block
                            if let image = Self.parseFlacPictureBlock(data: data, offset: offset, size: blockSize) {
                                continuation.resume(returning: image)
                                return
                            }
                        }

                        offset += blockSize

                        if isLast { break }
                    }

                    continuation.resume(returning: nil)

                } catch {
                    print("Failed to extract FLAC artwork: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func parseFlacPictureBlock(data: Data, offset: Int, size: Int) -> ArtworkImage? {
        var pos = offset

        // Skip picture type (4 bytes)
        pos += 4

        guard pos + 4 <= data.count else { return nil }

        // Get MIME type length
        let mimeLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4 + mimeLength

        guard pos + 4 <= data.count else { return nil }

        // Get description length
        let descLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4 + descLength

        // Skip width, height, color depth, indexed colors (16 bytes total)
        pos += 16

        guard pos + 4 <= data.count else { return nil }

        // Get picture data length
        let pictureLength = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
        pos += 4

        guard pos + pictureLength <= data.count else { return nil }

        // Extract picture data
        let pictureData = data.subdata(in: pos ..< pos + pictureLength)
        return ArtworkImage(data: pictureData)
    }

    // MARK: - M4A/AAC Artwork Extraction

    private nonisolated func extractM4AArtwork(from url: URL) async -> ArtworkImage? {
        // 2026-08-30 警告清理：AVAsset.commonMetadata/dataValue 已弃用（iOS 16），
        // 迁移到 load(.commonMetadata)/load(.dataValue)；顺带去掉 withCheckedContinuation
        // 样板（原实现在 do 抛错时不 resume，continuation 永久挂起）。
        do {
            let asset = AVURLAsset(url: url)
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                if item.commonKey == .commonKeyArtwork,
                   let data = try await item.load(.dataValue),
                   let image = ArtworkImage(data: data) {
                    print("🎨 Extracted M4A artwork: \(url.lastPathComponent)")
                    return image
                }
            }

            print("⚠️ No artwork found in M4A file: \(url.lastPathComponent)")
            return nil
        } catch {
            print("⚠️ Failed to load M4A artwork: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - DSD Artwork Extraction

    private nonisolated func extractDSDArtwork(from url: URL) async -> ArtworkImage? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            // For DSF files, try ID3v2 APIC frame extraction first
            if url.pathExtension.lowercased() == "dsf" {
                if let artwork = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                    return artwork
                }
            }

            // Fallback to binary signature search for both DSF and DFF files
            print("⚠️ No ID3v2 artwork found, searching for binary signatures in: \(url.lastPathComponent)")

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
                        print("🎨 Extracted JPEG artwork from DSD file (binary search): \(url.lastPathComponent)")
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
                        print("🎨 Extracted PNG artwork from DSD file (binary search): \(url.lastPathComponent)")
                        return image
                    }
                }
            }

            print("⚠️ No artwork found in DSD file: \(url.lastPathComponent)")
            return nil
        } catch {
            print("❌ DSD artwork extraction failed: \(error)")
            return nil
        }
    }

    // Extract artwork from DSF file using ID3v2 APIC frames
    private nonisolated func extractDSFArtworkFromID3(data: Data, filename: String) -> ArtworkImage? {
        // Validate DSF signature: 'D', 'S', 'D', ' ' (includes 1 space)
        guard data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            print("⚠️ Invalid DSF signature in: \(filename)")
            return nil
        }

        // Read metadata pointer from DSF header (little-endian at offset 20)
        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)

        guard metadataPointer > 0 && metadataPointer < data.count else {
            print("⚠️ No metadata pointer in DSF file: \(filename)")
            return nil
        }

        let metadataOffset = Int(metadataPointer)

        // Check for ID3v2 signature at metadata pointer
        guard data.count >= metadataOffset + 10,
              data[metadataOffset] == 0x49, // 'I'
              data[metadataOffset + 1] == 0x44, // 'D'
              data[metadataOffset + 2] == 0x33 else { // '3'
            print("⚠️ No ID3v2 tag found at metadata pointer in: \(filename)")
            return nil
        }

        print("🏷️ Found ID3v2 tag in DSF file: \(filename)")

        let id3Data = data.subdata(in: metadataOffset ..< data.count)
        return extractArtworkFromID3v2(data: id3Data, filename: filename)
    }

    // Extract artwork from ID3v2 APIC frame
    private nonisolated func extractArtworkFromID3v2(data: Data, filename: String) -> ArtworkImage? {
        guard data.count >= 10 else { return nil }

        // Read ID3v2 header
        let majorVersion = data[3]
        let tagSize = Int((UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9]))

        print("🏷️ Searching for APIC frame in ID3v2.\(majorVersion) tag, size: \(tagSize) bytes")

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
                print("🎨 Found APIC frame in \(filename), size: \(frameSize) bytes")

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
                    print("⚠️ Invalid APIC frame structure in: \(filename)")
                    break
                }

                let imageData = frameData.subdata(in: frameOffset ..< frameData.count)

                if let image = ArtworkImage(data: imageData) {
                    print("✅ Successfully extracted artwork from ID3v2 APIC frame: \(filename)")
                    return image
                } else {
                    print("⚠️ Could not create ArtworkImage from APIC data in: \(filename)")
                }
            }

            offset += frameSize
        }

        print("⚠️ No APIC frame found in ID3v2 tag: \(filename)")
        return nil
    }

    // Safe byte reading helper for DSF format (little-endian)
    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else {
            print("⚠️ Invalid byte access in artwork: offset=\(offset), dataSize=\(data.count)")
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

    // MARK: - Generic Artwork Extraction (Opus, OGG, etc.)

    private nonisolated func extractGenericArtwork(from url: URL) async -> ArtworkImage? {
        // Use SFBAudioEngine's TagLib-backed metadata reader. The previous
        // hand-rolled byte scan corrupted any METADATA_BLOCK_PICTURE larger
        // than one Ogg page (~64KB): the base64 payload is interleaved with
        // Ogg page headers, which the scan couldn't strip (issue #75).
        do {
            let audioFile = try AudioFile(readingPropertiesAndMetadataFrom: url)
            let pictures = audioFile.metadata.attachedPictures
            let preferred = pictures.first(where: { $0.type == .frontCover }) ?? pictures.first
            if let preferred, let image = ArtworkImage(data: preferred.imageData) {
                print("✅ Extracted artwork via SFBAudioEngine metadata: \(url.lastPathComponent) (\(preferred.imageData.count) bytes)")
                return image
            }
        } catch {
            print("⚠️ SFBAudioEngine metadata read failed for \(url.lastPathComponent): \(error)")
        }

        // Fallback: legacy Vorbis comment scan (works for single-page pictures)
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let artwork = extractVorbisCommentArtwork(from: data, filename: url.lastPathComponent) {
                return artwork
            }

            print("⚠️ No artwork found in Vorbis comments: \(url.lastPathComponent)")
            return nil
        } catch {
            print("❌ Generic artwork extraction failed: \(error)")
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
            print("⚠️ No METADATA_BLOCK_PICTURE tag found in: \(filename)")
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
            print("🔍 Read Vorbis comment length field: \(valueLength) bytes")
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
            print("🔍 Using null-terminated length: \(valueLength) bytes")
        }

        guard valueLength > 0 && valueStart + valueLength <= data.count else {
            print("⚠️ Invalid METADATA_BLOCK_PICTURE length in: \(filename)")
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
            print("🔍 Detected binary METADATA_BLOCK_PICTURE format (starts with 0x00) in: \(filename)")
            pictureBlockData = valueData
        } else {
            // Try to decode as base64-encoded (standard format)
            // Filter data to only valid base64 characters (A-Z, a-z, 0-9, +, /, =)
            // This handles cases where null bytes or other characters are mixed in
            let validBase64Chars: Set<UInt8> = Set(
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8
            )

            var filteredData = Data(valueData.filter { validBase64Chars.contains($0) })
            print("🔍 Filtered base64 data: \(valueData.count) → \(filteredData.count) bytes")

            // Add padding to make length a multiple of 4 (required for base64)
            let remainder = filteredData.count % 4
            if remainder > 0 {
                let paddingNeeded = 4 - remainder
                let paddingBytes = Data(repeating: UInt8(ascii: "="), count: paddingNeeded)
                filteredData.append(paddingBytes)
                print("🔍 Added \(paddingNeeded) padding bytes, new length: \(filteredData.count)")
            }

            // Try to decode the filtered and padded data
            if let decoded = Data(base64Encoded: filteredData, options: .ignoreUnknownCharacters) {
                print("🔍 Successfully decoded base64 METADATA_BLOCK_PICTURE, size: \(decoded.count) bytes")
                pictureBlockData = decoded
            } else {
                print("⚠️ Failed to decode filtered base64, treating as binary in: \(filename)")
                // Last resort: treat as binary data
                pictureBlockData = valueData
            }
        }

        print("🎨 Found METADATA_BLOCK_PICTURE in \(filename), size: \(pictureBlockData.count) bytes")

        // Parse FLAC picture block structure
        return parseFLACPictureBlock(data: pictureBlockData, filename: filename)
    }

    // Parse FLAC picture block structure (RFC 9639)
    private nonisolated func parseFLACPictureBlock(data: Data, filename: String) -> ArtworkImage? {
        var offset = 0

        guard data.count >= 32 else {
            print("⚠️ METADATA_BLOCK_PICTURE too small: \(filename)")
            return nil
        }

        // Read picture type (32 bits, big-endian)
        let pictureType = readBigEndianUInt32(from: data, offset: offset)
        offset += 4
        print("🖼️ Picture type: \(pictureType)")

        // Read MIME type length (32 bits, big-endian)
        let mimeLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        guard offset + mimeLength <= data.count else {
            print("⚠️ Invalid MIME type length in: \(filename)")
            return nil
        }

        // Read MIME type string
        let mimeData = data.subdata(in: offset ..< offset + mimeLength)
        let mimeType = String(data: mimeData, encoding: .utf8) ?? ""
        offset += mimeLength
        print("🖼️ MIME type: \(mimeType)")

        // Read description length (32 bits, big-endian)
        guard offset + 4 <= data.count else {
            print("⚠️ Not enough data for description length field")
            return nil
        }
        let descLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4
        print("🖼️ Description length: \(descLength)")

        // Skip description
        guard offset + descLength <= data.count else {
            print("⚠️ Invalid description length")
            return nil
        }
        offset += descLength

        // Skip width, height, color depth, number of colors (4 × 32 bits = 16 bytes)
        guard offset + 16 <= data.count else {
            print("⚠️ Not enough data for image dimensions")
            return nil
        }
        offset += 16

        // Read picture data length (32 bits, big-endian)
        guard offset + 4 <= data.count else {
            print("⚠️ Not enough data for picture length field")
            return nil
        }
        let pictureLength = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        print("🖼️ Picture data length field: \(pictureLength) bytes")
        print("🖼️ Current offset: \(offset), Total data size: \(data.count), Remaining: \(data.count - offset)")

        // Extract picture data - use remaining data if length field is incorrect
        let actualPictureLength: Int
        if offset + pictureLength <= data.count {
            actualPictureLength = pictureLength
        } else {
            // Length field is wrong - just use all remaining data
            actualPictureLength = data.count - offset
            print("⚠️ Picture length field incorrect, using all remaining \(actualPictureLength) bytes")
        }

        // Extract picture data
        let pictureData = data.subdata(in: offset ..< offset + actualPictureLength)

        if let image = ArtworkImage(data: pictureData) {
            print("✅ Successfully extracted \(mimeType) artwork from Vorbis comments: \(filename)")
            return image
        } else {
            print("⚠️ Could not create ArtworkImage from picture data in: \(filename)")
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
