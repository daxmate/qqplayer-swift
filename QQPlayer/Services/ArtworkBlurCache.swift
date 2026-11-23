//
//  ArtworkBlurCache.swift
//  QQPlayer
//
//  播放页「封面毛玻璃」背景的预渲染 + LRU 缓存（iOS + macOS 共用）。
//
//  为什么不用 SwiftUI 的 `.blur(radius:)`：大半径实时模糊每帧都要在 GPU 上重算，
//  和播放进度刷新 / 切歌 / 跟手手势叠在一起会掉帧。这里改为一次性渲染
//  「缩图 → CIGaussianBlur + CIColorControls → 位图」，按曲目标识缓存，
//  切歌只做两张图的交叉淡入（见 `ArtworkBlurBackground`）。
//
//  线程模型：命中查询同步（主线程要立刻拿到图）；渲染在后台 task 里做，结果回主线程写入。
//  缓存身份：键 = 曲目标识，条目同时记「源封面身份」；身份不符的条目不算命中（切歌竞态）。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// 跨线程传递封面位图的载体（平台图像类型本身不保证 Sendable）。
struct SendableArtwork: @unchecked Sendable {
    let image: ArtworkImage
}

/// 封面毛玻璃渲染 + LRU 缓存（上限 6 张）。
final class ArtworkBlurCache: @unchecked Sendable {
    static let shared = ArtworkBlurCache()

    /// 缓存上限（6 张 320px 缩图，内存可忽略）
    static let capacity = 6
    /// 渲染输入宽度（等比缩放，模糊半径按这个尺寸取）
    static let renderWidth: CGFloat = 320
    /// CIGaussianBlur 半径（对 320px 宽的缩小图）
    static let blurRadius: CGFloat = 28
    /// 饱和度（Apple Music 式背景偏浓郁）
    static let saturation: CGFloat = 1.9
    /// 亮度微调（压暗一点，保证白色文字对比度）
    static let brightness: CGFloat = -0.06

    private let lock = NSLock()

    /// 一条缓存记录：模糊图 + 生成它的**源封面身份**。
    /// 为什么要记身份：切歌瞬间调用方先换键、后换封面（`PlayerView` / `MacWindowGlass`
    /// 的 `cacheKey` 来自当前曲目，`artwork` 要等异步取图才更新），
    /// 于是「旧封面 + 新键」会被渲染并写进新键 —— 若不校验身份，新封面到达后
    /// 这里仍会把旧封面的模糊图当命中返回，背景就永远停在上一首（2026-11-23 真机 bug）。
    private struct Entry {
        let image: ArtworkImage
        let sourceID: ObjectIdentifier?
    }

    private var storage: [String: Entry] = [:]
    /// 最近使用顺序：末尾 = 最新。命中与写入都移到末尾。
    private var order: [String] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - 同步读（主线程）

    /// 命中返回同一实例（便于视图状态比较），未命中返回 nil，不触发渲染。
    func cachedImage(for key: String) -> ArtworkImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        touchLocked(key)
        return entry.image
    }

    /// 带封面身份的命中判定：键相同但**源封面不是同一张** → 视为未命中。
    /// 这样「旧封面 + 新键」留下的污染条目不会被新封面复用。
    func cachedImage(for key: String, source: ArtworkImage) -> ArtworkImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key], entry.sourceID == ObjectIdentifier(source) else { return nil }
        touchLocked(key)
        return entry.image
    }

    /// 缓存张数（测试用）
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// 当前键顺序（最旧 → 最新，测试用）
    var orderedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    /// 写入（命中已有键时覆盖并移到最新）；不带源封面身份的旧入口（仅测试 / 兼容用）
    func store(_ image: ArtworkImage, forKey key: String) {
        store(image, forKey: key, sourceID: nil)
    }

    /// 写入并记录源封面身份（渲染路径用）
    func store(_ image: ArtworkImage, forKey key: String, sourceID: ObjectIdentifier?) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = Entry(image: image, sourceID: sourceID)
        touchLocked(key)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }

    // MARK: - 渲染（缓存未命中时）

    /// 取毛玻璃图：命中直接返回，未命中后台渲染后写入缓存。
    @MainActor
    func image(for key: String, source: ArtworkImage) async -> ArtworkImage? {
        if let cached = cachedImage(for: key, source: source) {
            return cached
        }
        let sourceID = ObjectIdentifier(source)
        let box = SendableArtwork(image: source)
        let rendered = await Task.detached(priority: .userInitiated) { [self] in
            Self.render(source: box.image, context: ciContext).map(SendableArtwork.init)
        }.value
        guard let rendered else { return nil }
        store(rendered.image, forKey: key, sourceID: sourceID)
        return rendered.image
    }

    /// 纯渲染（无缓存副作用）：缩到 320px 宽 → 高斯模糊 → 调饱和度/亮度。
    static func render(source: ArtworkImage, context: CIContext) -> ArtworkImage? {
        guard let cgSource = cgImage(from: source),
              let scaled = resized(cgSource, targetWidth: renderWidth) else { return nil }

        let extent = CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height)
        // clampedToExtent：让模糊采样在图像边缘外继续延伸，否则四边会出现透明暗边
        let input = CIImage(cgImage: scaled).clampedToExtent()

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input
        blur.radius = Float(blurRadius)
        guard let blurred = blur.outputImage else { return nil }

        let controls = CIFilter.colorControls()
        controls.inputImage = blurred
        controls.saturation = Float(saturation)
        controls.brightness = Float(brightness)
        controls.contrast = 1
        guard let adjusted = controls.outputImage?.cropped(to: extent) else { return nil }

        guard let output = context.createCGImage(adjusted, from: extent) else { return nil }
        return platformImage(from: output)
    }

    // MARK: - 私有

    private func touchLocked(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func resized(_ image: CGImage, targetWidth: CGFloat) -> CGImage? {
        let width = max(Int(targetWidth.rounded()), 1)
        let height = max(
            Int((CGFloat(image.height) * targetWidth / CGFloat(max(image.width, 1))).rounded()),
            1
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    #if os(iOS)
        private static func cgImage(from image: UIImage) -> CGImage? {
            image.cgImage
        }

        private static func platformImage(from cgImage: CGImage) -> UIImage {
            UIImage(cgImage: cgImage)
        }
    #else
        private static func cgImage(from image: NSImage) -> CGImage? {
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        private static func platformImage(from cgImage: CGImage) -> NSImage {
            NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    #endif
}
