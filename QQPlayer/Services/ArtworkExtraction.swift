//
//  ArtworkExtraction.swift
//  QQPlayer
//
//  内嵌封面提取入口与分派 + MP3/FLAC/M4A 提取。
//  同族：ArtworkExtraction+DSD.swift（DSD/DSF 提取 + ID3v2 帧解析）、
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
                            AppLog.error(.general, "Failed to load artwork data: \(error)")
                        }
                    }

                    continuation.resume(returning: nil)
                } catch {
                    AppLog.error(.general, "Failed to load MP3 metadata: \(error)")
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
                    AppLog.error(.general, "Failed to extract FLAC artwork: \(error)")
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
                    AppLog.info(.general, "🎨 Extracted M4A artwork: \(url.lastPathComponent)")
                    return image
                }
            }

            AppLog.warn(.general, "⚠️ No artwork found in M4A file: \(url.lastPathComponent)")
            return nil
        } catch {
            AppLog.warn(.general, "⚠️ Failed to load M4A artwork: \(error.localizedDescription)")
            return nil
        }
    }
}
