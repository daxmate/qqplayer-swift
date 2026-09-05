//
//  AudioMetadataParser+FLAC.swift
//  QQPlayer
//
//  FLAC 解析域：FLAC 块结构解析（STREAMINFO/VORBIS_COMMENT/PICTURE）、
//  Vorbis Comments 解析、ReplayGain 解析。
//

import Foundation

extension AudioMetadataParser {
    static func parseFlacMetadataSync(from url: URL) async throws -> AudioMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var durationMs: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var channels: Int?
        var replaygainTrackGain: Double?
        var replaygainAlbumGain: Double?
        var replaygainTrackPeak: Double?
        var replaygainAlbumPeak: Double?
        var hasEmbeddedArt = false

        // Check if file is actually readable first
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("❌ FLAC file is not readable: \(url.lastPathComponent)")
            throw AudioParseError.fileNotReadable
        }

        // Get file size to check if reasonable
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = fileAttributes[.size] as? Int64 else {
            throw AudioParseError.fileNotReadable
        }

        print("📊 FLAC file size: \(fileSize) bytes for \(url.lastPathComponent)")

        // or too small (<1KB)
        guard fileSize > 1024 else {
            print("❌ FLAC file size is unreasonable: \(fileSize) bytes")
            throw AudioParseError.fileSizeError
        }

        print("📖 Reading FLAC data for: \(url.lastPathComponent)")

        // Use NSFileCoordinator to properly read iCloud files
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var error: NSError?
                let coordinator = NSFileCoordinator()
                var coordinatedData: Data?
                var coordinatedError: Error?

                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                    do {
                        // Create fresh URL to avoid stale metadata
                        let freshURL = URL(fileURLWithPath: readingURL.path)
                        print("🔄 Using NSFileCoordinator to read: \(freshURL.lastPathComponent)")

                        // Check if file actually exists at path
                        guard FileManager.default.fileExists(atPath: freshURL.path) else {
                            coordinatedError = AudioParseError.fileNotReadable
                            return
                        }

                        // Map instead of loading the whole file - metadata lives at
                        // the start, and 2000 x full FLAC reads spikes memory
                        coordinatedData = try Data(contentsOf: freshURL, options: .mappedIfSafe)
                        print("✅ FLAC data read successfully via NSFileCoordinator: \(coordinatedData?.count ?? 0) bytes")
                    } catch {
                        print("❌ Failed to read FLAC data via NSFileCoordinator: \(error)")
                        coordinatedError = error
                    }
                }

                if let error = error {
                    print("❌ NSFileCoordinator error: \(error)")
                    continuation.resume(throwing: error)
                } else if let coordinatedError = coordinatedError {
                    continuation.resume(throwing: coordinatedError)
                } else if let data = coordinatedData {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: AudioParseError.fileNotReadable)
                }
            }
        }

        if data.count < 42 {
            throw AudioParseError.invalidFile
        }

        var offset = 4

        while offset < data.count {
            // The 30s parse timeout cancels this task; bail out promptly
            // instead of running the whole file parse to completion (audit)
            try Task.checkCancellation()

            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F

            offset += 1

            guard offset + 3 <= data.count else { break }

            let blockSize = Int(data[offset]) << 16 | Int(data[offset + 1]) << 8 | Int(data[offset + 2])
            offset += 3

            if blockType == 0 {
                if offset + 18 <= data.count {
                    sampleRate = Int(data[offset + 10]) << 12 | Int(data[offset + 11]) << 4 | Int(data[offset + 12]) >> 4
                    channels = Int((data[offset + 12] >> 1) & 0x07) + 1
                    bitDepth = Int(((data[offset + 12] & 0x01) << 4) | (data[offset + 13] >> 4)) + 1

                    let totalSamples = UInt64(data[offset + 13] & 0x0F) << 32 |
                        UInt64(data[offset + 14]) << 24 |
                        UInt64(data[offset + 15]) << 16 |
                        UInt64(data[offset + 16]) << 8 |
                        UInt64(data[offset + 17])

                    if sampleRate! > 0 {
                        durationMs = Int((totalSamples * 1000) / UInt64(sampleRate!))
                    }
                }
            } else if blockType == 4 {
                let commentData = data.subdata(in: offset ..< min(offset + blockSize, data.count))
                let metadata = parseVorbisComments(commentData)

                title = metadata["TITLE"]
                artist = metadata["ARTIST"] ?? metadata["ARTISTE"]
                album = metadata["ALBUM"]
                albumArtist = metadata["ALBUMARTIST"]
                genre = Self.normalizedGenre(metadata["GENRE"])

                if let trackStr = metadata["TRACKNUMBER"] {
                    trackNumber = Int(trackStr)
                }
                if let discStr = metadata["DISCNUMBER"] {
                    discNumber = Int(discStr)
                }
                if let dateStr = metadata["DATE"] {
                    year = Int(dateStr)
                }

                if let gainStr = metadata["REPLAYGAIN_TRACK_GAIN"] {
                    replaygainTrackGain = parseReplayGain(gainStr)
                }
                if let gainStr = metadata["REPLAYGAIN_ALBUM_GAIN"] {
                    replaygainAlbumGain = parseReplayGain(gainStr)
                }
                if let peakStr = metadata["REPLAYGAIN_TRACK_PEAK"] {
                    replaygainTrackPeak = Double(peakStr)
                }
                if let peakStr = metadata["REPLAYGAIN_ALBUM_PEAK"] {
                    replaygainAlbumPeak = Double(peakStr)
                }
            } else if blockType == 6 {
                // PICTURE block - embedded artwork
                hasEmbeddedArt = true
            }

            offset += blockSize

            if isLast { break }
        }

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            replaygainTrackGain: replaygainTrackGain,
            replaygainAlbumGain: replaygainAlbumGain,
            replaygainTrackPeak: replaygainTrackPeak,
            replaygainAlbumPeak: replaygainAlbumPeak,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    private static func parseVorbisComments(_ data: Data) -> [String: String] {
        var comments: [String: String] = [:]
        var offset = 0

        guard offset + 4 <= data.count else { return comments }

        let vendorLength = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        offset += 4 + vendorLength

        guard offset + 4 <= data.count else { return comments }

        let commentCount = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        offset += 4

        for _ in 0 ..< commentCount {
            guard offset + 4 <= data.count else { break }

            let commentLength = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
            offset += 4

            guard offset + commentLength <= data.count else { break }

            if let commentString = String(data: data.subdata(in: offset ..< offset + commentLength), encoding: .utf8) {
                let parts = commentString.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).uppercased()
                    let value = String(parts[1])
                    // Vorbis allows repeating a field for multiple values -
                    // the standard way to tag multiple artists. Accumulate
                    // them so they aren't silently overwritten (issue #16);
                    // parseArtistNames splits on ";" downstream
                    let multiValueKeys: Set<String> = ["ARTIST", "ARTISTE", "ALBUMARTIST"]
                    if multiValueKeys.contains(key), let existing = comments[key], !existing.isEmpty {
                        comments[key] = existing + "; " + value
                    } else {
                        comments[key] = value
                    }
                }
            }

            offset += commentLength
        }

        return comments
    }

    private static func parseReplayGain(_ gainString: String) -> Double? {
        let cleaned = gainString.replacingOccurrences(of: " dB", with: "")
        return Double(cleaned)
    }

}
