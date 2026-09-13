//
//  ArtworkCache.swift
//  QQPlayer
//
//  Artwork 持久化与磁盘缓存：plist mapping（脏标记去抖合并写）、
//  磁盘缓存读写/清理、缩图降采样工具。
//

import CryptoKit
import Foundation
import ImageIO
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

extension ArtworkManager {
    func loadMapping() {
        guard FileManager.default.fileExists(atPath: mappingFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: mappingFileURL)
            if let mapping = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
                artworkMapping = mapping
                print("📊 Loaded artwork mapping: \(artworkMapping.count) entries")
            }
        } catch {
            print("⚠️ Failed to load artwork mapping: \(error)")
        }
    }

    func saveMapping() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: artworkMapping, format: .xml, options: 0)
            try data.write(to: mappingFileURL, options: .atomic)
        } catch {
            print("⚠️ Failed to save artwork mapping: \(error)")
        }
    }

    private func saveMappingDebounced() {
        mappingDirty = true
        guard mappingSaveTask == nil else { return }
        mappingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.mappingSaveTask = nil
            guard self.mappingDirty else { return }
            self.mappingDirty = false
            self.saveMapping()
        }
    }

    /// Flushes a pending debounced write immediately (app backgrounding or
    /// memory warning, so a just-written mapping is never lost).
    func flushMappingIfDirty() {
        guard mappingDirty else { return }
        mappingSaveTask?.cancel()
        mappingSaveTask = nil
        mappingDirty = false
        saveMapping()
    }

    func clearDiskCache() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            memoryCache.removeAllObjects()
            thumbnailCache.removeAllObjects()
            cachedTrackIds.removeAll()
            artworkMapping.removeAll()
            saveMapping()
            print("🗑️ Cleared \(files.count) artwork files from disk cache")
        } catch {
            print("❌ Failed to clear disk cache: \(error)")
        }
    }

    nonisolated func loadThumbnailFromDisk(artworkHash: String, maxPixelSize: CGFloat) async -> ArtworkImage? {
        let diskFile = diskCacheURL.appendingPathComponent("\(artworkHash).jpg")
        return Self.downsampledImage(at: diskFile, maxPixelSize: maxPixelSize)
    }

    // MARK: - Downsampling

    /// Ceiling for artwork kept in memory or written to the disk cache; big
    /// enough for the full-screen player, ~10-30x smaller than raw embedded art
    nonisolated static let maxFullArtworkPixelSize: CGFloat = 1024

    nonisolated static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> ArtworkImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        #if os(iOS)
            return UIImage(cgImage: cgImage)
        #else
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    nonisolated static func downsampled(_ image: ArtworkImage, maxPixelSize: CGFloat) -> ArtworkImage {
        #if os(iOS)
            let pixelWidth = image.size.width * image.scale
            let pixelHeight = image.size.height * image.scale
            let largestSide = max(pixelWidth, pixelHeight)
            guard largestSide > maxPixelSize else { return image }

            let ratio = maxPixelSize / largestSide
            let targetSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        #else
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return image
            }
            let largestSide = max(cgImage.width, cgImage.height)
            guard CGFloat(largestSide) > maxPixelSize else { return image }

            let ratio = maxPixelSize / CGFloat(largestSide)
            let width = max(1, Int((CGFloat(cgImage.width) * ratio).rounded()))
            let height = max(1, Int((CGFloat(cgImage.height) * ratio).rounded()))
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return image }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return image }
            return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
        #endif
    }

    /// JPEG 编码（iOS = UIImage.jpegData；macOS = NSBitmapImageRep，落盘缓存共用）
    nonisolated static func jpegData(_ image: ArtworkImage, compressionQuality: CGFloat) -> Data? {
        #if os(iOS)
            return image.jpegData(compressionQuality: compressionQuality)
        #else
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            return NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #endif
    }

    /// Runs the resize on the global executor so large images never block the main thread
    nonisolated static func downsampledOffMain(_ image: ArtworkImage, maxPixelSize: CGFloat) async -> ArtworkImage {
        downsampled(image, maxPixelSize: maxPixelSize)
    }

    // MARK: - Disk Cache Management

    nonisolated func loadFromDiskCache(stableId: String) async -> ArtworkImage? {
        // Get artwork hash from mapping
        guard let artworkHash = await getArtworkHash(for: stableId) else {
            return nil
        }

        let diskFile = diskCacheURL.appendingPathComponent("\(artworkHash).jpg")

        guard FileManager.default.fileExists(atPath: diskFile.path) else {
            return nil
        }

        // Decode at a capped size — legacy cache files may still be full resolution
        return Self.downsampledImage(at: diskFile, maxPixelSize: Self.maxFullArtworkPixelSize)
    }

    private func getArtworkHash(for stableId: String) async -> String? {
        return artworkMapping[stableId]
    }

    nonisolated func saveToDiskCache(image: ArtworkImage, stableId: String) async {
        // 落盘缓存两端同构（macOS 复用同一条路径；此前 macOS 是 no-op，封面每次冷启动
        // 都要重新解包内嵌封面，审计 🔵-2）。
        // Cap stored size; anything larger only costs decode time and memory
        let cappedImage = Self.downsampled(image, maxPixelSize: Self.maxFullArtworkPixelSize)
        // Compress to JPEG at 85% quality for faster loading and smaller size
        guard let imageData = Self.jpegData(cappedImage, compressionQuality: 0.85) else {
            print("❌ Failed to compress artwork to JPEG")
            return
        }

        // Compute hash of artwork data to deduplicate
        let artworkHash = SHA256.hash(data: imageData)
        let hashString = artworkHash.compactMap { String(format: "%02x", $0) }.joined()

        let diskFile = diskCacheURL.appendingPathComponent("\(hashString).jpg")

        // Check if artwork already exists
        if FileManager.default.fileExists(atPath: diskFile.path) {
            // Artwork already cached, just update mapping
            await updateMapping(stableId: stableId, artworkHash: hashString)
            print("♻️ Reused existing artwork: \(hashString).jpg for track \(stableId)")
            return
        }

        // Save new artwork file
        do {
            try imageData.write(to: diskFile, options: .atomic)
            await updateMapping(stableId: stableId, artworkHash: hashString)
            print("💾 Saved artwork to disk cache: \(hashString).jpg (\(imageData.count / 1024) KB)")
        } catch {
            print("❌ Failed to save artwork to disk: \(error)")
        }
    }

    private func updateMapping(stableId: String, artworkHash: String) async {
        artworkMapping[stableId] = artworkHash
        saveMappingDebounced()
    }

    /// Clean up artwork files for tracks that no longer exist
    func cleanupOrphanedArtwork(validStableIds: Set<String>) async {
        // First, clean up mapping entries for deleted tracks
        var removedMappings = 0
        for stableId in artworkMapping.keys where !validStableIds.contains(stableId) {
            artworkMapping.removeValue(forKey: stableId)
            removedMappings += 1
        }

        if removedMappings > 0 {
            saveMapping()
            print("🗑️ Removed \(removedMappings) orphaned mapping entries")
        }

        // Build set of artwork hashes still in use
        let usedHashes = Set(artworkMapping.values)

        // Clean up artwork files that are no longer referenced
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            var removedCount = 0

            for fileURL in files {
                let artworkHash = fileURL.deletingPathExtension().lastPathComponent
                if !usedHashes.contains(artworkHash) {
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                print("🗑️ Cleaned up \(removedCount) unused artwork files")
            }
        } catch {
            print("❌ Failed to cleanup orphaned artwork: \(error)")
        }
    }
}
