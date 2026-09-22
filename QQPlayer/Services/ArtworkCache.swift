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
    /// 读一处映射表（nil = 文件不存在 / 读失败 / 解析失败）。
    nonisolated static func readMapping(at url: URL?) -> [String: String]? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String]
        } catch {
            AppLog.warn(.general, "⚠️ Failed to load artwork mapping: \(url.path) \(error)")
            return nil
        }
    }

    /// 「文件存在但没读出来」= 映射内容**未知**（区别于「文件不存在」= 目前为空）。
    /// 清理路径必须能区分这两者：未知时一律不删（见 `shouldPruneArtworkCache`）。**纯函数**。
    nonisolated static func mappingFileExistsUnreadable(_ url: URL?, parsed: [String: String]?) -> Bool {
        guard let url, parsed == nil else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 两处映射合并（**纯函数**，单一事实源）：键冲突**新位置优先**。
    /// 旧位置（`Documents/ArtworkMapping.plist`）只读并入 —— 它改名前的残留只要还在，
    /// 就必须继续贡献条目，否则一旦新位置文件被清掉，旧位置就成了永远读不到的"死文件"。
    nonisolated static func mergedMapping(
        current: [String: String]?,
        legacy: [String: String]?
    ) -> [String: String] {
        var merged = legacy ?? [:]
        merged.merge(current ?? [:]) { _, new in new }
        return merged
    }

    func loadMapping() {
        // 顺序不变量：旧位置只读兼容必须在**任何清理动作之前**生效。
        // 本函数只在 `init` 里调一次，而所有清理（post-index maintenance / 磁盘缓存清理）
        // 都晚于 `init` ⇒ 合并结果先于清理进入内存映射（清理判据 `artworkMapping` 因此可信）。
        let current = Self.readMapping(at: mappingFileURL)
        let legacy = Self.readMapping(at: legacyMappingFileURL)

        // 任一位置「存在但读不出来」⇒ 映射内容未知，清理必须据此 fail-safe（未知 ≠ 空）。
        mappingUnreadable = Self.mappingFileExistsUnreadable(mappingFileURL, parsed: current)
            || Self.mappingFileExistsUnreadable(legacyMappingFileURL, parsed: legacy)

        guard current != nil || legacy != nil else { return }
        artworkMapping = Self.mergedMapping(current: current, legacy: legacy)
        AppLog.info(.general, "📊 Loaded artwork mapping: \(artworkMapping.count) entries")

        // 旧位置贡献了新位置没有的条目 ⇒ 立刻把**合并结果**落到新位置（写入仍只经本类的
        // `saveMapping`）。否则映射表可能只存在于旧位置，而旧位置恰是清理/迁移的作用域。
        if legacy != nil, (current ?? [:]) != artworkMapping {
            saveMapping()
        }
    }

    func saveMapping() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: artworkMapping, format: .xml, options: 0)
            try data.write(to: mappingFileURL, options: .atomic)
        } catch {
            AppLog.warn(.general, "⚠️ Failed to save artwork mapping: \(error)")
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
            // 只删**缓存文件**（`<64 位 hex>.jpg`）：映射表与缓存同目录（`Documents/Artwork/`），
            // 它不是缓存，绝不能被当成缓存删掉（映射表随后由 `saveMapping` 按空表重写）。
            let removable = Set(
                Self.deletableArtworkCacheFileNames(files.map(\.lastPathComponent), usedHashes: [])
            )
            for file in files where removable.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
            memoryCache.removeAllObjects()
            thumbnailCache.removeAllObjects()
            cachedTrackIds.removeAll()
            artworkMapping.removeAll()
            saveMapping()
            AppLog.info(.general, "🗑️ Cleared \(removable.count) artwork files from disk cache")
        } catch {
            AppLog.error(.general, "❌ Failed to clear disk cache: \(error)")
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
            AppLog.error(.general, "❌ Failed to compress artwork to JPEG")
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
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "♻️ Reused existing artwork: \(hashString).jpg for track \(stableId)") }
            return
        }

        // Save new artwork file
        do {
            try imageData.write(to: diskFile, options: .atomic)
            await updateMapping(stableId: stableId, artworkHash: hashString)
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "💾 Saved artwork to disk cache: \(hashString).jpg (\(imageData.count / 1024) KB)") }
        } catch {
            AppLog.error(.general, "❌ Failed to save artwork to disk: \(error)")
        }
    }

    private func updateMapping(stableId: String, artworkHash: String) async {
        artworkMapping[stableId] = artworkHash
        saveMappingDebounced()
    }

    /// 是否允许执行「删缓存文件 / 删映射条目」的清理。**纯函数**（单一判据，可单测）。
    ///
    /// 🔴 fail-safe 边界：映射**为空 / 未加载 / 读失败**时，内存里的映射无法区分
    /// 「这些缓存文件是孤儿」与「映射表丢了」——此时按「未被引用」删文件 = 把用户**全部**
    /// 封面缓存当孤儿删光。所以未知/为空一律返回 false（宁可不删，等映射可信后再清）。
    nonisolated static func shouldPruneArtworkCache(
        mapping: [String: String],
        mappingUnreadable: Bool
    ) -> Bool {
        guard !mapping.isEmpty else { return false }
        guard !mappingUnreadable else { return false }
        return true
    }

    /// `<64 位小写 hex>.jpg` —— 落盘缓存文件的唯一命名口径（`saveToDiskCache` 的 SHA256 hex）。
    /// 判据只看名字：**映射表、临时文件、目录里任何元数据都不符合**，因此永不被当缓存删。
    nonisolated static func isArtworkCacheFileName(_ name: String) -> Bool {
        let nsName = name as NSString
        guard nsName.pathExtension == "jpg" else { return false }
        let stem = nsName.deletingPathExtension
        guard stem.count == 64 else { return false }
        return stem.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// 目录里哪些文件**可以**作为「未被引用的缓存」删除。**纯函数**。
    /// 只认缓存命名（`isArtworkCacheFileName`）且哈希未被映射引用者。
    nonisolated static func deletableArtworkCacheFileNames(
        _ names: [String],
        usedHashes: Set<String>
    ) -> [String] {
        names.filter { name in
            guard isArtworkCacheFileName(name) else { return false }
            return !usedHashes.contains((name as NSString).deletingPathExtension)
        }
    }

    /// Clean up artwork files for tracks that no longer exist
    func cleanupOrphanedArtwork(validStableIds: Set<String>) async {
        // 🔴 删减前的 fail-safe 守卫（2026-09-22 回归）：映射为空/未加载/读失败时
        // `usedHashes` 会退化成空集 ⇒ 下面两个循环会「删光缓存文件 + 删光映射条目」。
        // 这种状态说明映射不可信（可能只是映射表丢了），不是「所有封面都成了孤儿」。
        guard Self.shouldPruneArtworkCache(mapping: artworkMapping, mappingUnreadable: mappingUnreadable) else {
            AppLog.warn(.general, "⚠️ SAFETY: 封面映射为空/未加载（entries=\(artworkMapping.count)）——跳过缓存清理，不删文件、不删条目")
            return
        }

        // First, clean up mapping entries for deleted tracks
        var removedMappings = 0
        for stableId in artworkMapping.keys where !validStableIds.contains(stableId) {
            artworkMapping.removeValue(forKey: stableId)
            removedMappings += 1
        }

        if removedMappings > 0 {
            saveMapping()
            AppLog.info(.general, "🗑️ Removed \(removedMappings) orphaned mapping entries")
        }

        // Build set of artwork hashes still in use
        let usedHashes = Set(artworkMapping.values)

        // Clean up artwork files that are no longer referenced.
        // 只删缓存命名（`<64 hex>.jpg`）且哈希未被引用者：映射表与缓存**同目录**
        // （`Documents/Artwork/ArtworkMapping.plist`），按「文件名不在 usedHashes 里」的
        // 旧口径会把它当孤儿删掉 —— 2026-09-22 映射表整个消失就是这么发生的。
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            var removedCount = 0

            let deletable = Set(
                Self.deletableArtworkCacheFileNames(files.map(\.lastPathComponent), usedHashes: usedHashes)
            )
            for fileURL in files where deletable.contains(fileURL.lastPathComponent) {
                try FileManager.default.removeItem(at: fileURL)
                removedCount += 1
            }

            if removedCount > 0 {
                AppLog.info(.general, "🗑️ Cleaned up \(removedCount) unused artwork files")
            }
        } catch {
            AppLog.error(.general, "❌ Failed to cleanup orphaned artwork: \(error)")
        }
    }
}
