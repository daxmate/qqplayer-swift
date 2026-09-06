//
//  ArtworkManager.swift
//  QQPlayer
//
//  Manages album artwork extraction and caching
//
//  核心：封面加载/决策（数据源选择、内存缓存读取）。
//  拆分见 ArtworkCache.swift（plist/磁盘缓存）与 ArtworkExtraction.swift（内嵌封面提取）。
//

import Foundation
#if os(iOS)
    import UIKit
    typealias ArtworkImage = UIImage
#else
    import AppKit
    typealias ArtworkImage = NSImage
#endif

@MainActor
class ArtworkManager: ObservableObject {
    static let shared = ArtworkManager()

    // Memory cache for quick access
    let memoryCache = NSCache<NSString, ArtworkImage>()
    // Small row/grid-sized artwork, keyed by "\(stableId)-\(pixelSize)"
    let thumbnailCache = NSCache<NSString, ArtworkImage>()
    var cachedTrackIds: Set<String> = []
    private var notificationObservers: [NSObjectProtocol] = []

    // Persistent disk cache directory
    let diskCacheURL: URL

    // Mapping file URL (maps track.stableId -> artwork hash)
    let mappingFileURL: URL

    // In-memory mapping cache
    var artworkMapping: [String: String] = [:]

    private let maxMemoryCacheItems = 250
    private let maxMemoryCacheCost = 40 * 1024 * 1024

    private init() {
        // Create artwork cache directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        diskCacheURL = documentsURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        mappingFileURL = documentsURL.appendingPathComponent("ArtworkMapping.plist")

        memoryCache.countLimit = maxMemoryCacheItems
        memoryCache.totalCostLimit = maxMemoryCacheCost
        thumbnailCache.countLimit = 600
        thumbnailCache.totalCostLimit = 30 * 1024 * 1024

        // Create directory if needed
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Load mapping
        loadMapping()

        let notificationCenter = NotificationCenter.default
        #if os(iOS)
            notificationObservers.append(
                notificationCenter.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.clearCache()
                        self?.flushMappingIfDirty()
                    }
                }
            )
            notificationObservers.append(
                notificationCenter.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.clearCache()
                        self?.flushMappingIfDirty()
                    }
                }
            )
        #endif

        print("📁 ArtworkManager initialized - Disk cache: \(diskCacheURL.path)")
    }

    // Mapping persistence is debounced: updateMapping runs on the main actor
    // for every newly-cached artwork, and rewriting the whole plist per call
    // was a synchronous main-thread IO storm on the first scroll (audit). A
    // dirty flag plus one coalescing task writes at most every 500ms.
    var mappingDirty = false
    var mappingSaveTask: Task<Void, Never>?

    func clearCache() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        cachedTrackIds.removeAll()
        print("🗑️ ArtworkManager memory cache cleared")
    }

    func forceRefreshArtwork(for track: Track) async -> ArtworkImage? {
        // Remove from memory cache and mapping to force re-extraction
        memoryCache.removeObject(forKey: track.stableId as NSString)
        // Thumbnail keys are size-suffixed and NSCache can't enumerate, so drop them all
        thumbnailCache.removeAllObjects()
        cachedTrackIds.remove(track.stableId)

        // Note: We don't delete the actual artwork file as other tracks might use it
        // Just remove the mapping for this track
        artworkMapping.removeValue(forKey: track.stableId)
        saveMapping()

        print("🔄 Force refreshing artwork for: \(track.title)")
        let refreshed = await getArtwork(for: track)
        // 已显示的缩略图/卡片用 .task(id: stableId) 缓存，stableId 不变不会自动重载；
        // 发通知让正在展示该曲目封面的视图重拉（2026-09-06 刮削保存封面后不刷新修复）
        NotificationCenter.default.post(
            name: NSNotification.Name("QQPlayerArtworkRefreshed"),
            object: track.stableId
        )
        return refreshed
    }

    func getArtwork(for track: Track) async -> ArtworkImage? {
        // 1. Check memory cache first (fastest)
        if let cachedImage = memoryCache.object(forKey: track.stableId as NSString) {
            return cachedImage
        }

        // 2. Check disk cache (fast)
        if let diskImage = await loadFromDiskCache(stableId: track.stableId) {
            // Store in memory cache for next time
            cacheImage(diskImage, for: track.stableId)
            return diskImage
        }

        // 3. Extract from audio file and cache (slow - should be rare after indexing)
        if let extracted = await extractArtwork(from: URL(fileURLWithPath: track.path)) {
            let image = await Self.downsampledOffMain(extracted, maxPixelSize: Self.maxFullArtworkPixelSize)
            // Store in both caches
            cacheImage(image, for: track.stableId)
            await saveToDiskCache(image: image, stableId: track.stableId)
            return image
        }

        return nil
    }

    /// Small artwork for list rows and grid cells. Decoding and holding these
    /// instead of full-size art keeps scrolling smooth and memory low.
    func getThumbnail(for track: Track, maxPixelSize: CGFloat = 160) async -> ArtworkImage? {
        let key = "\(track.stableId)-\(Int(maxPixelSize))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        // Fast path: downsample straight from the disk cache file
        if let artworkHash = artworkMapping[track.stableId],
           let thumbnail = await loadThumbnailFromDisk(artworkHash: artworkHash, maxPixelSize: maxPixelSize) {
            thumbnailCache.setObject(thumbnail, forKey: key)
            return thumbnail
        }

        // Slow path: full pipeline (extracts and fills the disk cache), then shrink
        guard let fullImage = await getArtwork(for: track) else { return nil }
        let thumbnail = await Self.downsampledOffMain(fullImage, maxPixelSize: maxPixelSize)
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    func updateVisibleArtworkWindow(visibleTrackIds: [String], prefetchTrackIds: [String] = []) {
        let keepTrackIds = Set(visibleTrackIds + prefetchTrackIds)
        guard !keepTrackIds.isEmpty else {
            clearCache()
            return
        }

        let staleTrackIds = cachedTrackIds.subtracting(keepTrackIds)
        for staleTrackId in staleTrackIds {
            memoryCache.removeObject(forKey: staleTrackId as NSString)
            cachedTrackIds.remove(staleTrackId)
        }
    }

    private func cacheImage(_ image: ArtworkImage, for stableId: String) {
        #if os(iOS)
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * 4)
        #else
            let cost = Int(image.size.width * image.size.height * 4)
        #endif
        memoryCache.setObject(image, forKey: stableId as NSString, cost: max(cost, 1))
        cachedTrackIds.insert(stableId)
    }
}
