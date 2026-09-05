//
//  AudioMetadataParser+MP3WAV.swift
//  QQPlayer
//
//  MP3/WAV 解析域（AVFoundation）：ID3/通用元数据加载、TRCK/TPOS/TYER/TDRC
//  帧提取、track/disc 编号解析、AVAudioFile 采样率/时长/位深。
//

import AVFoundation
import Foundation

extension AudioMetadataParser {
    private static func parseSlashSeparatedNumber(_ value: String) -> Int? {
        let firstPart = value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value
        return Int(firstPart)
    }

    // MP4 trkn/disk atoms usually store values as big-endian UInt16 pairs.
    private static func parseMP4TrackOrDiscData(_ data: Data) -> Int? {
        let bytes = [UInt8](data)

        if bytes.count >= 4 {
            let valueAtOffset2 = (Int(bytes[2]) << 8) | Int(bytes[3])
            if valueAtOffset2 > 0 {
                return valueAtOffset2
            }
        }

        if bytes.count >= 2 {
            let valueAtOffset0 = (Int(bytes[0]) << 8) | Int(bytes[1])
            if valueAtOffset0 > 0 {
                return valueAtOffset0
            }
        }

        return nil
    }

    /// Genre 判定 + 取值（AVFoundation 域）：ID3 TCON（identifier "id3/TCON"）
    /// 或 iTunes/MP4 ©gen（"itsk/%A9gen"，keySpace .iTunes 的 key 常以数值 4CC
    /// 返回，不能按 key 字符串匹配——8-29 经验：显式按 identifier 拉）。
    /// 非 genre 项直接返回 nil，不触发异步加载。
    private static func genreString(from item: AVMetadataItem) async -> String? {
        let identifier = item.identifier?.rawValue.lowercased()
        let isGenreItem = identifier == "id3/tcon" ||
            identifier == "itsk/%a9gen" ||
            identifier == "itsk/©gen"
        guard isGenreItem else { return nil }
        return Self.normalizedGenre(try? await item.load(.stringValue))
    }

    private static func extractTrackOrDiscNumber(from metadata: AVMetadataItem) async -> Int? {
        if let stringValue = try? await metadata.load(.stringValue),
           let parsed = parseSlashSeparatedNumber(stringValue) {
            return parsed
        }

        if let numberValue = try? await metadata.load(.numberValue) {
            let value = numberValue.intValue
            if value > 0 {
                return value
            }
        }

        if let dataValue = try? await metadata.load(.dataValue),
           let parsed = parseMP4TrackOrDiscData(dataValue) {
            return parsed
        }

        return nil
    }

    static func parseMp3MetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading MP3 metadata for: \(url.lastPathComponent)")

        // Use NSFileCoordinator for iCloud files (same as FLAC)
        let asset: AVURLAsset = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var error: NSError?
                let coordinator = NSFileCoordinator()

                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                    // Create fresh URL to avoid stale metadata
                    let freshURL = URL(fileURLWithPath: readingURL.path)
                    print("🔄 Using NSFileCoordinator for MP3: \(freshURL.lastPathComponent)")

                    // Check if file actually exists at path
                    guard FileManager.default.fileExists(atPath: freshURL.path) else {
                        continuation.resume(throwing: AudioParseError.fileNotReadable)
                        return
                    }

                    let asset = AVURLAsset(url: freshURL)
                    print("✅ MP3 AVURLAsset created successfully via NSFileCoordinator")
                    continuation.resume(returning: asset)
                }

                if let error = error {
                    print("❌ NSFileCoordinator error for MP3: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var hasEmbeddedArt = false

        // Parse ID3 metadata using async API
        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)

            // Parse common metadata
            for item in commonMetadata {
                try Task.checkCancellation()
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                    print("🎤 Found artist in common metadata: \(artist ?? "nil")")
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }

                if trackNumber == nil, item.commonKey?.rawValue == "trackNumber" {
                    trackNumber = await extractTrackOrDiscNumber(from: item)
                }

                if discNumber == nil, item.commonKey?.rawValue == "discNumber" {
                    discNumber = await extractTrackOrDiscNumber(from: item)
                }
            }

            // Check for additional ID3 tags
            for metadata in allMetadata {
                try Task.checkCancellation()
                // Genre first: AVAsset maps ID3 TCON to commonKey "type" (not a
                // real common key) and iTunes ©gen has no commonKey at all, so
                // neither reliably reaches the keyed branches below - match by
                // identifier up front (8-29 lesson: pull explicitly, don't rely
                // on commonKey).
                if genre == nil, let genreValue = await Self.genreString(from: metadata) {
                    genre = genreValue
                    print("🎸 Found genre from \(metadata.identifier?.rawValue ?? "tag"): \(genreValue)")
                }
                if let key = metadata.commonKey?.rawValue {
                    switch key {
                    case "albumArtist":
                        albumArtist = try? await metadata.load(.stringValue)
                    case "artist":
                        // Additional check for artist in common key
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in additional common key: \(artist ?? "nil")")
                        }
                    case "trackNumber":
                        if trackNumber == nil {
                            trackNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    case "discNumber":
                        if discNumber == nil {
                            discNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    default:
                        break
                    }
                } else if let identifier = metadata.identifier {
                    print("🔍 Checking ID3 tag: \(identifier.rawValue)")
                    switch identifier.rawValue {
                    case "id3/TRCK":
                        if trackNumber == nil {
                            trackNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    case "id3/TPOS":
                        if discNumber == nil {
                            discNumber = await extractTrackOrDiscNumber(from: metadata)
                        }
                    case "id3/TPE2":
                        albumArtist = try? await metadata.load(.stringValue)
                        print("🎤 Found album artist in TPE2: \(albumArtist ?? "nil")")
                    case "id3/TPE1":
                        // Fallback for main artist if not found in common metadata
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in TPE1: \(artist ?? "nil")")
                        }
                    // Add more ID3 artist tag variations
                    case "id3/TIT2":
                        // Title fallback
                        if title == nil {
                            title = try? await metadata.load(.stringValue)
                        }
                    case "id3/TALB":
                        // Album fallback
                        if album == nil {
                            album = try? await metadata.load(.stringValue)
                        }
                    case "id3/TYER", "id3/TDRC":
                        // Year frame (TYER in ID3v2.3, TDRC in ID3v2.4).
                        // AVAsset does NOT map these to commonKeyCreationDate,
                        // so without this branch every MP3 year is lost and the
                        // decade playlist buckets everything into "unknown".
                        if year == nil {
                            if let yearString = try? await metadata.load(.stringValue) {
                                year = Int(String(yearString.prefix(4)))
                                print("🎤 Found year from \(identifier.rawValue): \(yearString) → \(year ?? -1)")
                            }
                        }
                    default:
                        let identifierValue = identifier.rawValue.lowercased()

                        // Handle MP4/iTunes metadata identifiers (e.g. trkn/disk)
                        if trackNumber == nil &&
                            (identifierValue.contains("trkn") || identifierValue.contains("tracknumber")) {
                            trackNumber = await extractTrackOrDiscNumber(from: metadata)
                        }

                        if discNumber == nil &&
                            (identifierValue.contains("disk") || identifierValue.contains("discnumber")) {
                            discNumber = await extractTrackOrDiscNumber(from: metadata)
                        }

                        // iTunes/MP4 ©ALB/©day 无 commonKey（genreString 同款缺口 8-29 已拉
                        // genre；album/year 同样只能按 identifier 拉——否则 SFB 写的 m4a
                        // 标签读回 album/year 全丢）
                        if album == nil &&
                            (identifierValue.contains("%a9alb") || identifierValue.contains("©alb")) {
                            album = try? await metadata.load(.stringValue)
                            print("🎵 Found album from MP4 ©ALB: \(album ?? "nil")")
                        }
                        if year == nil &&
                            (identifierValue.contains("%a9day") || identifierValue.contains("©day")) {
                            if let yearString = try? await metadata.load(.stringValue) {
                                year = Int(String(yearString.prefix(4)))
                                print("🎤 Found year from MP4 ©day: \(yearString) → \(year ?? -1)")
                            }
                        }

                        // Debug: log unhandled tags that might contain artist info
                        if identifier.rawValue.contains("ART") || identifier.rawValue.contains("TPE") {
                            let value = try? await metadata.load(.stringValue)
                            print("🔍 Unhandled artist-related tag \(identifier.rawValue): \(value ?? "nil")")
                        }
                    }
                }
            }
        } catch is CancellationError {
            // Propagate cancellation instead of swallowing it in the generic
            // metadata-failure handler below (audit: cancelled parses must
            // stop, not keep going)
            throw CancellationError()
        } catch {
            print("Failed to load asset metadata: \(error)")
        }

        // Get actual audio format info
        var sampleRate: Int?
        var channels: Int?
        var durationMs: Int?

        // Use AVAudioFile to get precise format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat

            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)

            // Calculate precise duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)

        } catch {
            // Fallback to AVAsset for duration if AVAudioFile fails
            do {
                let duration = try await asset.load(.duration)
                if duration.isValid && !duration.isIndefinite {
                    durationMs = Int(CMTimeGetSeconds(duration) * 1000)
                }
            } catch {
                print("Failed to load duration: \(error)")
            }

            // Use reasonable defaults for format if we can't determine
            sampleRate = sampleRate ?? 44100
            channels = channels ?? 2
        }

        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")

            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }

        print("🎵 Final MP3 metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        print("   Genre: \(genre ?? "nil")")

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
            bitDepth: nil, // MP3 is lossy, bit depth doesn't apply
            channels: channels,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    static func parseWavMetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading WAV metadata for: \(url.lastPathComponent)")

        // For WAV files, use AVAudioFile to get format info and try AVAsset for metadata
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?
        var durationMs: Int?
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        let albumArtist: String? = nil
        let trackNumber: Int? = nil
        let discNumber: Int? = nil
        var year: Int?
        var hasEmbeddedArt = false

        // Get audio format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat

            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)

            // Calculate duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)

            // Try to get bit depth from format settings
            if let settings = audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int {
                bitDepth = settings
            }
        } catch {
            print("⚠️ Failed to read WAV audio format: \(error)")
        }

        // Try to get metadata from AVAsset (some WAV files may have ID3 tags or other metadata)
        do {
            let asset = AVURLAsset(url: url)
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }
            }

            // Genre has no commonKey (same as TYER/TDRC) - scan all metadata
            // for the ID3 TCON frame / iTunes ©gen atom explicitly.
            if genre == nil {
                let allMetadata = try await asset.load(.metadata)
                for item in allMetadata {
                    guard genre == nil else { break }
                    if let genreValue = await Self.genreString(from: item) {
                        genre = genreValue
                    }
                }
            }
        } catch {
            print("⚠️ Failed to read WAV metadata: \(error)")
        }

        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")

            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }

        // Default values for WAV
        sampleRate = sampleRate ?? 44100
        channels = channels ?? 2
        bitDepth = bitDepth ?? 16

        print("🎵 Final WAV metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Sample Rate: \(sampleRate ?? 0) Hz")
        print("   Channels: \(channels ?? 0)")
        print("   Bit Depth: \(bitDepth ?? 0)")

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
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

}
