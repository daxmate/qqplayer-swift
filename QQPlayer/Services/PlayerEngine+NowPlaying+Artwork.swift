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
            let generation = artworkLoadGeneration

            // Always try ArtworkManager cache first — avoids re-parsing large files
            if let detail = await ArtworkManager.shared.getArtworkDetail(for: track) {
                await MainActor.run {
                    guard self.isArtworkResultCurrent(track: track, generation: generation),
                          let artwork = self.convertUIImageToMPMediaItemArtwork(detail.image) else { return }
                    self.storeArtwork(artwork, for: track, source: detail.source.rawValue)
                }
                return
            }

            guard isArtworkResultCurrent(track: track, generation: generation) else { return }

            // No cached artwork — only then fall back to file parsing
            guard track.hasEmbeddedArt else {
                // 本曲确实没有内嵌封面：标记已处理，别反复解析（发布侧用占位图兜底）
                await MainActor.run {
                    guard self.isArtworkResultCurrent(track: track, generation: generation) else { return }
                    self.cachedArtworkTrackId = track.stableId
                    AppLog.info(.general, "🎨 No embedded artwork for: \(track.title)")
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
                    guard self.isArtworkResultCurrent(track: track, generation: generation) else { return }
                    if let artwork {
                        self.storeArtwork(artwork, for: track, source: "extract")
                    } else {
                        // 标了有内嵌封面却解不出来：可能是锁屏文件保护 / 读盘失败，
                        // 不再永久钉成「无封面」——回前台补一次（retryArtworkIfNeeded）。
                        self.artworkRetryTrackId = track.stableId
                        AppLog.warn(.general, "⚠️ Artwork extraction failed (retry on foreground): \(track.title)")
                    }
                }

            } catch {
                AppLog.error(.general, "❌ Failed to load artwork for caching: \(error)")
                await MainActor.run {
                    guard self.isArtworkResultCurrent(track: track, generation: generation) else { return }
                    self.artworkRetryTrackId = track.stableId
                }
            }
        }

        // MARK: - 发布门控 / 补发（2026-11-19 CarPlay 封面空白）

        /// 迟到的结果是否还算数：曲目 + 切歌代际都对上才允许落缓存/补发。
        private func isArtworkResultCurrent(track: Track, generation: Int) -> Bool {
            PlaybackTrackGate.isStillCurrent(
                trackId: track.stableId,
                generation: generation,
                currentTrackId: currentTrack?.stableId,
                currentGeneration: artworkLoadGeneration
            )
        }

        /// 封面落缓存 + 记来源。载入中只落缓存，发布交给 loadTrack 末尾的首次发布
        /// （避免 duration 还是 0 的半成品信息先上屏）。
        private func storeArtwork(_ artwork: MPMediaItemArtwork, for track: Track, source: String) {
            cachedArtwork = artwork
            cachedArtworkTrackId = track.stableId
            lastResolvedArtwork = artwork
            artworkRetryTrackId = nil
            AppLog.info(.general, "🎨 Artwork ready (\(source)) for: \(track.title)")
            if !isLoadingTrack {
                updateNowPlayingInfoWithCachedArtwork()
            }
        }

        /// 起一次后台封面解析：同一曲只跑一个任务，完成后自行补发。
        func loadArtworkInBackground(for track: Track) {
            guard artworkLoadTaskTrackId != track.stableId else { return }
            artworkLoadTask?.cancel()
            artworkLoadTaskTrackId = track.stableId
            artworkLoadTask = Task { [weak self] in
                await self?.loadAndCacheArtwork(track: track)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.artworkLoadTaskTrackId == track.stableId {
                        self.artworkLoadTask = nil
                    }
                }
            }
        }

        /// 回前台补一次：只对「解析失败但可重试」的曲目做；再失败就等下一次回前台，
        /// 不会形成循环（解析本身失败次数也有限）。
        func retryArtworkIfNeeded() {
            guard let track = currentTrack,
                  artworkRetryTrackId == track.stableId,
                  cachedArtworkTrackId != track.stableId else { return }
            artworkRetryTrackId = nil
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadTaskTrackId = nil
            AppLog.info(.general, "🔁 Retrying artwork for: \(track.title)")
            loadArtworkInBackground(for: track)
        }

        /// 发布这一刻定稿封面：缓存 → 上一曲 → 占位，**永不返回 nil**。
        /// 只有「真图还没到」才拿上一曲的图临时兜底；本曲确无内嵌封面时直接占位图，
        /// 免得把上一首的封面永久钉在锁屏和车机上。
        func resolveArtworkForPublication(
            track: Track
        ) -> NowPlayingArtworkGate.Resolution<MPMediaItemArtwork> {
            let cached = cachedArtworkTrackId == track.stableId ? cachedArtwork : nil
            let previous = track.hasEmbeddedArt ? lastResolvedArtwork : nil
            let resolution = NowPlayingArtworkGate.decide(
                cached: cached,
                arrived: nil,
                previous: previous,
                placeholder: Self.placeholderArtwork,
                timedOut: track.hasEmbeddedArt
            )
            if resolution.source == .cached {
                lastResolvedArtwork = resolution.artwork
            }
            return resolution
        }

        /// MPMediaItemArtwork 在 iOS 上没有 boundsSize 属性；用 requestHandler 取回
        /// 捕获的图读尺寸（我们的 handler 恒返回整图，开销可忽略）。
        static func artworkSide(_ artwork: MPMediaItemArtwork) -> Int {
            let image = artwork.image(at: CGSize(width: 1, height: 1))
            return Int((image?.size.width ?? 0).rounded())
        }

        /// 无封面时的占位图（512×512 纯色 + 音符）。boundsSize 与图一致、
        /// requestHandler 恒返回捕获图（永不 nil），保证任何一次发布都带 artwork 键。
        static let placeholderArtwork: MPMediaItemArtwork = {
            let side: CGFloat = 512
            let size = CGSize(width: side, height: side)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.setFillColor(UIColor(white: 0.11, alpha: 1).cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: size))
                let glyphSide = side * 0.4
                let glyph = UIImage(systemName: "music.note")?.withTintColor(
                    UIColor(white: 0.55, alpha: 1),
                    renderingMode: .alwaysOriginal
                )
                glyph?.draw(
                    in: CGRect(
                        x: (side - glyphSide) / 2,
                        y: (side - glyphSide) / 2,
                        width: glyphSide,
                        height: glyphSide
                    )
                )
            }
            return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }()
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

                        // 方形化（沿用既有裁剪规则）+ 长边压到 ≤1024，再交给 MediaRemote。
                        // 顺便把图渲染成位图：自定义 request handler 可能在 MediaRemote 的
                        // 私有队列上被调用，那里跑 actor 继承的 Swift 闭包会 trap。
                        let artworkImage = self.normalizedArtworkImage(originalImage)
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

                    let processedImage = self.normalizedArtworkImage(artwork)

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

        /// 真封面到位后补发。走**唯一发布入口**（重建完整字典），不再做
        /// 「读旧字典 + 只改 artwork 键」的局部写——任何半份字典都会把
        /// title/duration 冲掉，而 CarPlay 只在元数据变化时读一次。
        private func updateNowPlayingInfoWithCachedArtwork() {
            guard let track = currentTrack,
                  let cachedArtwork,
                  cachedArtworkTrackId == track.stableId else { return }
            lastResolvedArtwork = cachedArtwork
            updateNowPlayingInfoEnhanced()
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
                        let processedImage = self.normalizedArtworkImage(image)
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
                            let processedImage = self.normalizedArtworkImage(image)
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
                            let processedImage = self.normalizedArtworkImage(image)
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

        /// 统一封面整形：方形化（沿用既有裁剪规则）后把长边压到 ≤1024。
        ///
        /// CarPlay/锁屏按 boundsSize 取图，原始 3000×3000 的图会在 MediaRemote 侧
        /// 解码放大，既慢又容易超时；boundsSize 必须与最终图一致，所以只在
        /// 真的大于上限时才缩放（小图不放大，避免糊）。
        private nonisolated func normalizedArtworkImage(
            _ image: UIImage,
            maxSide: CGFloat = 1024
        ) -> UIImage {
            let squared = cropToSquareIfNeeded(image: image)
            let longest = max(squared.size.width, squared.size.height)
            guard longest > maxSide, longest > 0 else { return squared }
            let scale = maxSide / longest
            return resizeImage(
                squared,
                to: CGSize(
                    width: (squared.size.width * scale).rounded(),
                    height: (squared.size.height * scale).rounded()
                )
            )
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
