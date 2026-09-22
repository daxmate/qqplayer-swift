//  PlayerEngine+NowPlaying+Artwork.swift
//  QQPlayer
//
//  Cover-art loading for PlayerEngine (iOS): ArtworkManager cache probe plus the
//  AVAsset / FLAC PICTURE / DSD file parsers and the image-shaping helpers.
//
//  2026-09-21 从 PlayerEngine+NowPlaying.swift 原样搬出（纯搬家，无逻辑变更）。
#if os(iOS)
    import AVFoundation
    import Foundation
    import MediaPlayer
    import UIKit
    extension PlayerEngine {
        /// 分片：跨文件可见（原 private）
        func loadAndCacheArtwork(track: Track) async {
            // Always try ArtworkManager cache first — avoids re-parsing large files
            if let uiImage = await ArtworkManager.shared.getArtwork(for: track) {
                await MainActor.run {
                    let artwork = self.convertUIImageToMPMediaItemArtwork(uiImage)
                    self.cachedArtwork = artwork
                    self.cachedArtworkTrackId = track.stableId
                    self.updateNowPlayingInfoWithCachedArtwork()
                    AppLog.info(.general, "🎨 Cached artwork from ArtworkManager for: \(track.title)")
                }
                return
            }

            // No cached artwork — only then fall back to file parsing
            guard track.hasEmbeddedArt else {
                // Mark this track so we don't keep retrying
                await MainActor.run {
                    self.cachedArtworkTrackId = track.stableId
                }
                return
            }

            do {
                let url = LibraryRoot.absoluteURL(forStoredPath: track.path)

                let artwork: MPMediaItemArtwork? = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let fileExtension = url.pathExtension.lowercased()
                        AppLog.info(.general, "🎵 Loading artwork from file: \(url.lastPathComponent)")

                        if fileExtension == "dsf" || fileExtension == "dff" {
                            if let art = self.loadArtworkFromSFBAudioEngine(url: url) ?? self.loadArtworkFromDSDFile(url: url) {
                                continuation.resume(returning: art)
                            } else {
                                continuation.resume(returning: nil)
                            }
                        } else if fileExtension == "flac" {
                            Task {
                                // 2026-08-30 警告清理：loadArtworkFromAVAsset 已 async 化，
                                // continuation 不能在 Task 外同步 resume
                                let avArt = await self.loadArtworkFromAVAsset(url: url)
                                let art = avArt ?? self.loadArtworkFromFLACMetadata(url: url)
                                continuation.resume(returning: art)
                            }
                        } else {
                            Task {
                                let art = await self.loadArtworkFromAVAsset(url: url)
                                continuation.resume(returning: art)
                            }
                        }
                    }
                }

                await MainActor.run {
                    if let artwork = artwork {
                        self.cachedArtwork = artwork
                        self.cachedArtworkTrackId = track.stableId
                        self.updateNowPlayingInfoWithCachedArtwork()
                        AppLog.info(.general, "🎨 Cached artwork from file for: \(track.title)")
                    } else {
                        // Mark as attempted so we don't retry
                        self.cachedArtworkTrackId = track.stableId
                        AppLog.info(.general, "🎨 No artwork found for: \(track.title)")
                    }
                }

            } catch {
                AppLog.error(.general, "❌ Failed to load artwork for caching: \(error)")
                // Mark as attempted so we don't keep retrying and crashing on large files
                await MainActor.run {
                    self.cachedArtworkTrackId = track.stableId
                }
            }
        }

        private nonisolated func loadArtworkFromAVAsset(url: URL) async -> MPMediaItemArtwork? {
            // 2026-08-30 警告清理：commonMetadata/dataValue 已弃用（iOS 16），迁移到异步 load API
            do {
                let asset = AVURLAsset(url: url)
                let commonMetadata = try await asset.load(.commonMetadata)

                for metadataItem in commonMetadata {
                    if metadataItem.commonKey == .commonKeyArtwork,
                       let data = try await metadataItem.load(.dataValue),
                       let originalImage = UIImage(data: data) {
                        AppLog.info(.general, "🎨 Found artwork in AVAsset metadata (size: \(Int(originalImage.size.width))x\(Int(originalImage.size.height)))")

                        // Crop to square if width is significantly larger than height
                        let processedImage = self.cropToSquareIfNeeded(image: originalImage)

                        // Render before handing the image to MediaRemote. A custom
                        // request handler may be invoked on MediaRemote's private
                        // queue, where an actor-inherited Swift closure traps.
                        let targetSize = CGSize(width: 1024, height: 1024)
                        let artworkImage = self.resizeImage(processedImage, to: targetSize)
                        let artwork = self.makeMediaItemArtwork(from: artworkImage)

                        return artwork
                    }
                }

                AppLog.warn(.general, "⚠️ No artwork found in AVAsset metadata")
                return nil
            } catch {
                AppLog.warn(.general, "⚠️ Failed to load artwork from AVAsset: \(error.localizedDescription)")
                return nil
            }
        }

        private nonisolated func loadArtworkFromFLACMetadata(url: URL) -> MPMediaItemArtwork? {
            do {
                // Read FLAC file directly to extract embedded artwork
                let data = try Data(contentsOf: url, options: .mappedIfSafe)

                // Look for FLAC PICTURE metadata block
                if let artwork = extractFLACPictureBlock(from: data) {
                    AppLog.info(.general, "🎨 Found artwork in FLAC PICTURE block")

                    let processedImage = self.cropToSquareIfNeeded(image: artwork)

                    let mpArtwork = self.makeMediaItemArtwork(from: processedImage)

                    return mpArtwork
                }

                AppLog.warn(.general, "⚠️ No PICTURE block found in FLAC file")
                return nil

            } catch {
                AppLog.error(.general, "❌ Direct FLAC metadata reading failed: \(error)")
                return nil
            }
        }

        private nonisolated func extractFLACPictureBlock(from data: Data) -> UIImage? {
            // FLAC file format: 4-byte signature "fLaC" followed by metadata blocks

            guard data.count > 4 else { return nil }

            // Check for FLAC signature
            let signature = data.subdata(in: 0 ..< 4)
            guard signature == Data([0x66, 0x4C, 0x61, 0x43]) else { // "fLaC"
                AppLog.warn(.general, "⚠️ Invalid FLAC signature")
                return nil
            }

            var offset = 4

            // Parse metadata blocks
            while offset < data.count - 4 {
                // Read metadata block header (4 bytes)
                let blockHeader = data.subdata(in: offset ..< (offset + 4))

                let isLastBlock = (blockHeader[0] & 0x80) != 0
                let blockType = blockHeader[0] & 0x7F

                // Block length (24-bit big-endian)
                let blockLength = Int(blockHeader[1]) << 16 | Int(blockHeader[2]) << 8 | Int(blockHeader[3])

                offset += 4

                // Check if this is a PICTURE block (type 6)
                if blockType == 6 {
                    AppLog.info(.general, "🖼️ Found FLAC PICTURE block at offset \(offset), length: \(blockLength)")

                    guard offset + blockLength <= data.count else {
                        AppLog.error(.general, "❌ PICTURE block extends beyond file")
                        break
                    }

                    let pictureBlockData = data.subdata(in: offset ..< (offset + blockLength))

                    if let image = parseFLACPictureBlock(data: pictureBlockData) {
                        return image
                    }
                }

                // Move to next block
                offset += blockLength

                if isLastBlock {
                    break
                }
            }

            return nil
        }

        private nonisolated func parseFLACPictureBlock(data: Data) -> UIImage? {
            guard data.count >= 32 else { return nil }

            var offset = 0

            // Picture type (4 bytes) - skip
            offset += 4

            // MIME type length (4 bytes, big-endian)
            let mimeTypeLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            guard offset + mimeTypeLength <= data.count else { return nil }

            // MIME type string - skip
            offset += mimeTypeLength

            // Description length (4 bytes, big-endian)
            guard offset + 4 <= data.count else { return nil }
            let descriptionLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            // Description string - skip
            offset += descriptionLength

            // Width (4 bytes) - skip
            offset += 4
            // Height (4 bytes) - skip
            offset += 4
            // Color depth (4 bytes) - skip
            offset += 4
            // Number of colors (4 bytes) - skip
            offset += 4

            // Picture data length (4 bytes, big-endian)
            guard offset + 4 <= data.count else { return nil }
            let pictureDataLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            // Picture data
            guard offset + pictureDataLength <= data.count else { return nil }
            let pictureData = data.subdata(in: offset ..< (offset + pictureDataLength))

            // Create UIImage from picture data
            return UIImage(data: pictureData)
        }

        private func updateNowPlayingInfoWithCachedArtwork() {
            guard let track = currentTrack,
                  let cachedArtwork = cachedArtwork,
                  cachedArtworkTrackId == track.stableId else { return }

            // Get current now playing info and add artwork
            var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }

        private nonisolated func convertUIImageToMPMediaItemArtwork(_ image: UIImage) -> MPMediaItemArtwork? {
            return makeMediaItemArtwork(from: image)
        }

        /// Uses MediaPlayer's image-backed initializer so MediaRemote never calls
        /// back into an app-owned Swift closure from its private artwork queue.
        private nonisolated func makeMediaItemArtwork(from image: UIImage) -> MPMediaItemArtwork {
            // 2026-08-30 警告清理：MPMediaItemArtwork(image:) 已弃用（iOS 10）。改用
            // boundsSize:requestHandler:。handler 仅返回捕获的 image（纯函数，不触碰
            // actor 隔离状态），MediaRemote 在私有队列调用它也是安全的。
            return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        private nonisolated func loadArtworkFromDSDFile(url: URL) -> MPMediaItemArtwork? {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let fileExtension = url.pathExtension.lowercased()

                // For DSF files, try ID3v2 APIC frame extraction first
                if fileExtension == "dsf" {
                    if let image = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                        AppLog.info(.general, "🎨 Extracted artwork from DSF ID3v2 APIC frame")
                        let processedImage = self.cropToSquareIfNeeded(image: image)
                        return self.makeMediaItemArtwork(from: processedImage)
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
                    // Try to extract JPEG starting from found position
                    let startOffset = jpegRange.lowerBound

                    // Look for JPEG end marker (FF D9)
                    let jpegEndSignature = Data([0xFF, 0xD9])
                    if let endRange = data.range(of: jpegEndSignature, in: startOffset ..< min(data.count, startOffset + 1048576)) {
                        let endOffset = endRange.upperBound
                        let imageData = data.subdata(in: startOffset ..< endOffset)

                        if let image = UIImage(data: imageData) {
                            AppLog.info(.general, "🎨 Extracted JPEG artwork from DSD file (binary search)")
                            let processedImage = self.cropToSquareIfNeeded(image: image)
                            return self.makeMediaItemArtwork(from: processedImage)
                        }
                    }
                }

                // Look for PNG images
                if let pngRange = data.range(of: pngSignature, in: searchRange) {
                    // Try to extract PNG starting from found position
                    let startOffset = pngRange.lowerBound

                    // PNG files end with IEND chunk (49 45 4E 44)
                    let pngEndSignature = Data([0x49, 0x45, 0x4E, 0x44])
                    if let endRange = data.range(of: pngEndSignature, in: startOffset ..< min(data.count, startOffset + 1048576)) {
                        let endOffset = endRange.upperBound + 4 // Include CRC after IEND
                        let imageData = data.subdata(in: startOffset ..< min(endOffset, data.count))

                        if let image = UIImage(data: imageData) {
                            AppLog.info(.general, "🎨 Extracted PNG artwork from DSD file (binary search)")
                            let processedImage = self.cropToSquareIfNeeded(image: image)
                            return self.makeMediaItemArtwork(from: processedImage)
                        }
                    }
                }

                return nil
            } catch {
                AppLog.warn(.general, "⚠️ Direct DSD artwork extraction failed: \(error)")
                return nil
            }
        }

        private nonisolated func cropToSquareIfNeeded(image: UIImage) -> UIImage {
            let width = image.size.width
            let height = image.size.height

            // If the image is already square or taller than wide, return as-is
            if width <= height {
                return image
            }

            // If width is more than 20% larger than height, crop to square
            let aspectRatio = width / height
            if aspectRatio > 1.2 {
                AppLog.info(.general, "🖼️ Cropping wide artwork (aspect ratio: \(String(format: "%.2f", aspectRatio))) to square")

                // Calculate the square size (use height as the dimension)
                let squareSize = height

                // Calculate the crop rect (center the crop horizontally)
                let xOffset = (width - squareSize) / 2
                let cropRect = CGRect(x: xOffset, y: 0, width: squareSize, height: squareSize)

                // Perform the crop
                guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
                    AppLog.warn(.general, "⚠️ Failed to crop image, returning original")
                    return image
                }

                return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
            }

            // Return original if aspect ratio is acceptable
            return image
        }

        private nonisolated func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }

    }
#endif
