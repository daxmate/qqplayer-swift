//  PlayerEngine+NowPlaying.swift
//  QQPlayer
//
//  Now Playing / Control Center info, artwork loading, widget integration, and
//  remote commands for PlayerEngine.
//

#if os(iOS)
    import AVFoundation
    import Foundation
    import GRDB
    import MediaPlayer
    import SFBAudioEngine
    import UIKit
    import WidgetKit
    extension PlayerEngine {
        func ensureRemoteCommandsSetup() {
            guard !hasSetupRemoteCommands else { return }
            hasSetupRemoteCommands = true
            setupRemoteCommands()
        }

        private func setupRemoteCommands() {
            let cc = MPRemoteCommandCenter.shared()

            // Play command handler - will be called from Control Center
            cc.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    print("🎛️ Play command from Control Center")
                    self?.play()
                }
                return .success
            }

            // Pause command handler - will be called from Control Center
            cc.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    print("🎛️ Pause command from Control Center")
                    self?.pause(fromControlCenter: true)
                }
                return .success
            }

            cc.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.nextTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.previousTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }

                // Perform seek synchronously for CarPlay
                let positionTime = e.positionTime
                print("🎯 CarPlay seek request to: \(positionTime)s")

                Task { @MainActor in
                    await self.seek(to: positionTime)
                    print("✅ Seek completed to: \(positionTime)s")
                }

                return .success
            }

            // Toggle play/pause command (for headphone button and other accessories)
            cc.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    if self?.isPlaying == true {
                        self?.pause(fromControlCenter: true)
                    } else {
                        self?.play()
                    }
                }
                return .success
            }

            // Enable all commands initially
            cc.playCommand.isEnabled = true
            cc.pauseCommand.isEnabled = true
            cc.nextTrackCommand.isEnabled = true
            cc.previousTrackCommand.isEnabled = true
            cc.changePlaybackPositionCommand.isEnabled = true
            cc.togglePlayPauseCommand.isEnabled = true

            // Enable seeking in CarPlay
            cc.changePlaybackPositionCommand.isEnabled = true
            print("✅ CarPlay seek command enabled")
        }

        // MARK: - Widget Integration

        func updateWidgetData() {
            guard let track = currentTrack else {
                WidgetDataManager.shared.clearCurrentTrack()
                return
            }
            let trackId = track.stableId

            Task {
                // Get artwork
                let artwork = await ArtworkManager.shared.getArtwork(for: track)

                // pngData 编码 + 写盘下沉后台线程（主 actor 编码/同步 IO 卡 UI，
                // 2026-08-29 审计 #9）：值拷贝 UIImage 引用后离线处理。
                let artworkData: Data?
                if let artwork {
                    artworkData = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            continuation.resume(returning: artwork.pngData())
                        }
                    }
                } else {
                    artworkData = nil
                }

                // Get artist name
                let artistName: String
                if let artistId = track.artistId,
                   let artist = try? DatabaseManager.shared.read({ db in
                       try Artist.fetchOne(db, key: artistId)
                   }) {
                    artistName = artist.name
                } else {
                    artistName = Localized.unknownArtist
                }

                // Get theme color
                let settings = DeleteSettings.load()
                let colorHex = settings.backgroundColorChoice.color.toHex()

                // 同曲校验（2026-09-12 审计 P5）：上面两次 await（封面 / 后台编码）期间可能已切歌，
                // 旧曲写进去会一直留在小组件（saveCurrentTrack 同步写盘 + reloadAllTimelines）。
                guard PlaybackTrackGate.isStillCurrent(trackId: trackId, currentTrackId: currentTrack?.stableId) else {
                    print("↩️ widget 更新丢弃：\(track.title) 已不是当前曲目")
                    return
                }

                let widgetData = WidgetTrackData(
                    trackId: track.stableId,
                    title: track.title,
                    artist: artistName,
                    isPlaying: isPlaying,
                    backgroundColorHex: colorHex
                )

                // 写盘 + 小组件刷新下沉后台（saveCurrentTrack 内部有 UserDefaults.synchronize
                // 与文件写入，均为同步 IO，2026-08-29 审计 #9）
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        WidgetDataManager.shared.saveCurrentTrack(widgetData, artworkData: artworkData)
                        WidgetCenter.shared.reloadAllTimelines()
                        continuation.resume()
                    }
                }
            }
        }

        // Enhanced manual approach with better Control Center synchronization
        func updateNowPlayingInfoEnhanced() {
            guard let track = currentTrack else {
                // Clear Now Playing info if no track
                DispatchQueue.main.async {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                    print("🎛️ Cleared Control Center - no track loaded")
                }
                return
            }

            let currentTime = nowPlayingElapsedTime()

            // Create comprehensive Now Playing info
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: track.title,
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyPlaybackQueueCount: playbackQueue.count,
            ]

            // Add queue position
            if playbackQueue.indices.contains(currentIndex) {
                info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            }

            if let artistName = cachedArtistName(for: track) {
                info[MPMediaItemPropertyArtist] = artistName
            }

            // Add track number
            if let trackNo = track.trackNo {
                info[MPMediaItemPropertyAlbumTrackNumber] = trackNo
            }

            // Add cached artwork
            if let cachedArtwork = cachedArtwork, cachedArtworkTrackId == track.stableId {
                info[MPMediaItemPropertyArtwork] = cachedArtwork
                print("🎨 Added cached artwork to Now Playing info for: \(track.title)")
            } else {
                print("⚠️ No cached artwork available for: \(track.title) (cached: \(cachedArtwork != nil), trackId match: \(cachedArtworkTrackId == track.stableId))")
            }

            // Update with explicit synchronization
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Re-attach artwork at write time: the artwork loader may have
                // finished between building `info` above and this block running,
                // and writing the stale artwork-less dictionary would wipe the
                // artwork it already set (lock screen loses the cover).
                var info = info
                if info[MPMediaItemPropertyArtwork] == nil,
                   let cachedArtwork = self.cachedArtwork,
                   self.cachedArtworkTrackId == track.stableId {
                    info[MPMediaItemPropertyArtwork] = cachedArtwork
                }

                // Update Now Playing Info
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info

                // Trigger CarPlay Now Playing button update
                MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused

                // Notify CarPlay delegate of state change
                NotificationCenter.default.post(name: NSNotification.Name("PlayerStateChanged"), object: nil)

                print("🎛️ Enhanced Control Center update - playing: \(self.isPlaying)")
                print("🎛️ Title: \(track.title), Time: \(currentTime)")
            }

            if cachedArtworkTrackId != track.stableId,
               artworkLoadTaskTrackId != track.stableId {
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
        }

        // MARK: - Timer and Updates

        func startPlaybackTimer() {
            // Don't start the high-frequency UI timer in background — it causes
            // SwiftUI view redraws that spike CPU and trigger the iOS watchdog.
            // Background track-end detection is handled by backgroundCheckTimer instead.
            if isInBackground {
                print("🔄 Skipping playback timer start - app is in background")
                return
            }

            let appState = UIApplication.shared.applicationState
            if hasSetupSiriBackgroundSession && appState == .background {
                print("🔄 Skipping playback timer start - Siri background mode active")
                return
            }

            stopPlaybackTimer()

            // Four UI updates per second are smooth enough for elapsed-time labels
            // and avoid flooding SwiftUI's list/layout pipeline. Audio timing comes
            // from the render timeline, not from this timer.
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.updatePlaybackTime()
                }
            }
        }
        private func updatePlaybackTime() async {
            // Handle SFBAudioEngine timing
            if usingSFBEngine {
                playbackTime = sfbAudioManager.currentTime
                playbackTimeUpdatedAt = Date()

                // Check for completion
                if playbackTime >= duration && duration > 0 {
                    await handleTrackEnd()
                }
                if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                    lastControlCenterUpdate = playbackTime
                    updateNowPlayingElapsedTime()
                }
                // 跟唱 tick：SFB 无 timePitch 变速，但句末自动停/单句循环/AB 循环有效
                KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
                return
            }

            guard audioFile != nil,
                  audioEngine.attachedNodes.contains(playerNode),
                  audioEngine.isRunning,
                  playerNode.lastRenderTime != nil else {
                return
            }
            let calculatedTime = currentTimeForCurrentNativeFile()

            // Only update playback time if we're actually playing (prevents drift during pause/resume)
            if isPlaying {
                playbackTime = calculatedTime
                playbackTimeUpdatedAt = Date()
            }

            // Remove this duplicate detection - it's handled by checkIfTrackEnded()
            /* DELETE THIS BLOCK:
             if isPlaying && playbackTime >= duration - 0.1 && duration > 0 {
             isPlaying = false
             await handleTrackEnd()
             }
             */

            // Update Control Center more frequently for better synchronization - every 0.5 seconds instead of 2 seconds
            // This ensures smooth time display in Control Center regardless of sample rate changes
            if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                lastControlCenterUpdate = playbackTime
                updateNowPlayingElapsedTime()
            }
            // 跟唱 tick：句末自动停/单句循环/AB 循环决策
            KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
        }

        func stopPlaybackTimer() {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }

        /// Stop all high-frequency UI timers when entering background to prevent
        /// SwiftUI redraws from spiking CPU and triggering the iOS watchdog kill.
        func suspendUITimersForBackground() {
            isInBackground = true
            stopPlaybackTimer()
            print("⏸️ Suspended UI timers for background")
        }

        /// Restart UI timers when returning to foreground.
        func resumeUITimersForForeground() {
            isInBackground = false
            if isPlaying {
                startPlaybackTimer()
            }
            print("▶️ Resumed UI timers for foreground")
        }

        // MARK: - Now Playing Info

        func resetNowPlayingCachesForTrackChange() {
            cachedArtwork = nil
            cachedArtworkTrackId = nil
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadTaskTrackId = nil
            cachedNowPlayingArtistTrackId = nil
            cachedNowPlayingArtistName = nil
        }

        func nowPlayingElapsedTime() -> TimeInterval {
            if usingSFBEngine {
                return sfbAudioManager.currentTime
            }
            return currentTimeForCurrentNativeFile()
        }

        private func cachedArtistName(for track: Track) -> String? {
            if cachedNowPlayingArtistTrackId == track.stableId {
                return cachedNowPlayingArtistName
            }

            let artistName: String?
            do {
                artistName = try databaseManager.getArtistDisplayName(
                    forTrackStableId: track.stableId,
                    fallbackArtistId: track.artistId
                )
            } catch {
                print("Failed to fetch metadata: \(error)")
                artistName = nil
            }

            cachedNowPlayingArtistTrackId = track.stableId
            cachedNowPlayingArtistName = artistName
            return artistName
        }

        private func updateNowPlayingElapsedTime() {
            guard currentTrack != nil else { return }

            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nowPlayingElapsedTime()
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }

        private func loadAndCacheArtwork(track: Track) async {
            // Always try ArtworkManager cache first — avoids re-parsing large files
            if let uiImage = await ArtworkManager.shared.getArtwork(for: track) {
                await MainActor.run {
                    let artwork = self.convertUIImageToMPMediaItemArtwork(uiImage)
                    self.cachedArtwork = artwork
                    self.cachedArtworkTrackId = track.stableId
                    self.updateNowPlayingInfoWithCachedArtwork()
                    print("🎨 Cached artwork from ArtworkManager for: \(track.title)")
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
                let url = URL(fileURLWithPath: track.path)

                let artwork: MPMediaItemArtwork? = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let fileExtension = url.pathExtension.lowercased()
                        print("🎵 Loading artwork from file: \(url.lastPathComponent)")

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
                        print("🎨 Cached artwork from file for: \(track.title)")
                    } else {
                        // Mark as attempted so we don't retry
                        self.cachedArtworkTrackId = track.stableId
                        print("🎨 No artwork found for: \(track.title)")
                    }
                }

            } catch {
                print("❌ Failed to load artwork for caching: \(error)")
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
                        print("🎨 Found artwork in AVAsset metadata (size: \(Int(originalImage.size.width))x\(Int(originalImage.size.height)))")

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

                print("⚠️ No artwork found in AVAsset metadata")
                return nil
            } catch {
                print("⚠️ Failed to load artwork from AVAsset: \(error.localizedDescription)")
                return nil
            }
        }

        private nonisolated func loadArtworkFromFLACMetadata(url: URL) -> MPMediaItemArtwork? {
            do {
                // Read FLAC file directly to extract embedded artwork
                let data = try Data(contentsOf: url, options: .mappedIfSafe)

                // Look for FLAC PICTURE metadata block
                if let artwork = extractFLACPictureBlock(from: data) {
                    print("🎨 Found artwork in FLAC PICTURE block")

                    let processedImage = self.cropToSquareIfNeeded(image: artwork)

                    let mpArtwork = self.makeMediaItemArtwork(from: processedImage)

                    return mpArtwork
                }

                print("⚠️ No PICTURE block found in FLAC file")
                return nil

            } catch {
                print("❌ Direct FLAC metadata reading failed: \(error)")
                return nil
            }
        }

        private nonisolated func extractFLACPictureBlock(from data: Data) -> UIImage? {
            // FLAC file format: 4-byte signature "fLaC" followed by metadata blocks

            guard data.count > 4 else { return nil }

            // Check for FLAC signature
            let signature = data.subdata(in: 0 ..< 4)
            guard signature == Data([0x66, 0x4C, 0x61, 0x43]) else { // "fLaC"
                print("⚠️ Invalid FLAC signature")
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
                    print("🖼️ Found FLAC PICTURE block at offset \(offset), length: \(blockLength)")

                    guard offset + blockLength <= data.count else {
                        print("❌ PICTURE block extends beyond file")
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

        private nonisolated func loadArtworkFromSFBAudioEngine(url: URL) -> MPMediaItemArtwork? {
            do {
                // Try to use SFBAudioEngine to extract artwork
                let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)
                let metadata = audioFile.metadata

                // SFBAudioEngine AudioMetadata doesn't expose raw artwork data directly
                // The current SFBAudioEngine API doesn't provide easy access to embedded artwork
                // We'll need to use the direct file parsing method instead
                print("🔍 SFBAudioEngine metadata available but artwork extraction not directly supported")
                print("🔍 Metadata - Title: \(metadata.title ?? "nil"), Artist: \(metadata.artist ?? "nil")")

                return nil
            } catch {
                print("⚠️ SFBAudioEngine artwork extraction failed: \(error)")
                return nil
            }
        }

        private nonisolated func loadArtworkFromDSDFile(url: URL) -> MPMediaItemArtwork? {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let fileExtension = url.pathExtension.lowercased()

                // For DSF files, try ID3v2 APIC frame extraction first
                if fileExtension == "dsf" {
                    if let image = extractDSFArtworkFromID3(data: data, filename: url.lastPathComponent) {
                        print("🎨 Extracted artwork from DSF ID3v2 APIC frame")
                        let processedImage = self.cropToSquareIfNeeded(image: image)
                        return self.makeMediaItemArtwork(from: processedImage)
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
                    // Try to extract JPEG starting from found position
                    let startOffset = jpegRange.lowerBound

                    // Look for JPEG end marker (FF D9)
                    let jpegEndSignature = Data([0xFF, 0xD9])
                    if let endRange = data.range(of: jpegEndSignature, in: startOffset ..< min(data.count, startOffset + 1048576)) {
                        let endOffset = endRange.upperBound
                        let imageData = data.subdata(in: startOffset ..< endOffset)

                        if let image = UIImage(data: imageData) {
                            print("🎨 Extracted JPEG artwork from DSD file (binary search)")
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
                            print("🎨 Extracted PNG artwork from DSD file (binary search)")
                            let processedImage = self.cropToSquareIfNeeded(image: image)
                            return self.makeMediaItemArtwork(from: processedImage)
                        }
                    }
                }

                return nil
            } catch {
                print("⚠️ Direct DSD artwork extraction failed: \(error)")
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
                print("🖼️ Cropping wide artwork (aspect ratio: \(String(format: "%.2f", aspectRatio))) to square")

                // Calculate the square size (use height as the dimension)
                let squareSize = height

                // Calculate the crop rect (center the crop horizontally)
                let xOffset = (width - squareSize) / 2
                let cropRect = CGRect(x: xOffset, y: 0, width: squareSize, height: squareSize)

                // Perform the crop
                guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
                    print("⚠️ Failed to crop image, returning original")
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

        // Extract artwork from DSF file using ID3v2 APIC frames
        private nonisolated func extractDSFArtworkFromID3(data: Data, filename: String) -> UIImage? {
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
        private nonisolated func extractArtworkFromID3v2(data: Data, filename: String) -> UIImage? {
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

                    if let image = UIImage(data: imageData) {
                        print("✅ Successfully extracted artwork from ID3v2 APIC frame: \(filename)")
                        return image
                    } else {
                        print("⚠️ Could not create UIImage from APIC data in: \(filename)")
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
                print("⚠️ Invalid byte access in player: offset=\(offset), dataSize=\(data.count)")
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

#else
    import Foundation
    import MediaPlayer

    extension PlayerEngine {
        // macOS Now Playing / media keys: MPRemoteCommandCenter + MPNowPlayingInfoCenter
        // work on macOS (verified by the desktop shell, main.swift 834-918). The
        // macOS playback timer drives elapsed time; WidgetKit stays iOS-only.

        func updateWidgetData() {
            // WidgetKit is iOS-only in this app; nothing to refresh on macOS.
        }

        func ensureRemoteCommandsSetup() {
            guard !hasSetupRemoteCommands else { return }
            hasSetupRemoteCommands = true
            setupMacRemoteCommands()
        }

        private func setupMacRemoteCommands() {
            let cc = MPRemoteCommandCenter.shared()

            cc.playCommand.isEnabled = true
            cc.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    self?.play()
                }
                return .success
            }

            cc.pauseCommand.isEnabled = true
            cc.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    self?.pause(fromControlCenter: true)
                }
                return .success
            }

            cc.togglePlayPauseCommand.isEnabled = true
            cc.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    if self?.isPlaying == true {
                        self?.pause(fromControlCenter: true)
                    } else {
                        self?.play()
                    }
                }
                return .success
            }

            cc.nextTrackCommand.isEnabled = true
            cc.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.nextTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.previousTrackCommand.isEnabled = true
            cc.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.previousTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.changePlaybackPositionCommand.isEnabled = true
            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let positionTime = e.positionTime
                Task { @MainActor in
                    await self?.seek(to: positionTime)
                }
                return .success
            }
        }

        func updateNowPlayingInfoEnhanced() {
            guard let currentTrack else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                return
            }

            var info: [String: Any] = [
                MPMediaItemPropertyTitle: currentTrack.title,
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackTime,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            ]

            if let artistName = try? DatabaseManager.shared.getArtistDisplayName(
                forTrackStableId: currentTrack.stableId,
                fallbackArtistId: currentTrack.artistId
            ) {
                info[MPMediaItemPropertyArtist] = artistName
            }

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func updateNowPlayingElapsedTime() {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func startPlaybackTimer() {
            stopPlaybackTimer()
            // Four UI updates per second are smooth enough for elapsed-time labels.
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.updateMacPlaybackTime()
                }
            }
        }

        private func updateMacPlaybackTime() async {
            // SFBAudioEngine timing: progress + end-of-track detection.
            if usingSFBEngine {
                playbackTime = sfbAudioManager.currentTime
                playbackTimeUpdatedAt = Date()

                if duration > 0, playbackTime >= duration {
                    await handleTrackEnd()
                    return
                }
                if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                    lastControlCenterUpdate = playbackTime
                    updateNowPlayingElapsedTime()
                }
                KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
                return
            }

            guard audioFile != nil,
                  audioEngine.attachedNodes.contains(playerNode),
                  audioEngine.isRunning,
                  playerNode.lastRenderTime != nil else {
                return
            }

            let calculatedTime = currentTimeForCurrentNativeFile()
            if isPlaying {
                playbackTime = calculatedTime
                playbackTimeUpdatedAt = Date()
            }

            if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                lastControlCenterUpdate = playbackTime
                updateNowPlayingElapsedTime()
            }
            // 跟唱 tick：句末自动停/单句循环/AB 循环决策（对齐 iOS updatePlaybackTime native 分支）
            KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
        }

        func stopPlaybackTimer() {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }

        func nowPlayingElapsedTime() -> TimeInterval {
            if usingSFBEngine {
                return sfbAudioManager.currentTime
            }
            return playbackTime
        }
    }
#endif
