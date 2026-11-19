//
//  CarPlay+PlayerPageCache.swift
//  QQPlayer
//
//  播放页渲染缓存（纯内存，不碰模板 API）。
//
//  背景（2026-11-09 真机日志）：同一首歌 4 分钟内播放页被重建 423 次，每条都触发
//  「页头动作按钮上限」警告；封面缺失警告 92 条。根因是每 2s 的进度桶都会重画页头缩略图、
//  每个 tick 都新建 4 个 CPButton —— CarPlay 模板每次 set 都要走一次 IPC + 重新布局。
//  这里只做两件事：缩略图按 (artworkKey, 进度桶) 复用、控制键按状态复用，容量都很小。
//

// target: ios-only

import CarPlay
import UIKit

/// 页头缩略图缓存：按 key 复用已画好的图，容量有限（切歌时整份清掉）。
@MainActor
struct CarPlayPlayerPageThumbnailCache {
    /// 保留条目上限：进度桶单调前进，只需要留住最近几张（回拖进度时也不至于重画太多）。
    private let capacity = 8
    private var keys: [String] = []
    private var images: [String: UIImage] = [:]

    /// 命中返回缓存图；未命中才调用 make（make 里是 CoreGraphics 绘制，成本最高的一步）。
    mutating func image(for key: String, make: () -> UIImage) -> UIImage {
        if let cached = images[key] {
            return cached
        }
        let image = make()
        images[key] = image
        keys.append(key)
        while keys.count > capacity, let oldest = keys.first {
            keys.removeFirst()
            images[oldest] = nil
        }
        return image
    }

    /// 切歌 / 断开时清空（旧曲目的图既不该复用，也没必要占内存）。
    mutating func removeAll() {
        keys.removeAll()
        images.removeAll()
    }
}

/// 页头控制键缓存：CPButton 实例可复用，只在播放态 / 播放顺序变化时重建。
@MainActor
struct CarPlayPlayerPageButtonCache {
    private var signature: String?
    private var buttons: [CPButton] = []

    /// 状态没变就复用上一次的按钮数组（含它们的 target/closure，不重新绑定）。
    mutating func buttons(signature: String, make: () -> [CPButton]) -> [CPButton] {
        if self.signature == signature, !buttons.isEmpty {
            return buttons
        }
        self.signature = signature
        buttons = make()
        return buttons
    }

    mutating func removeAll() {
        signature = nil
        buttons.removeAll()
    }
}

/// 页头封面加载：首取 + 有界重试（0 / 300ms / 1s），仍未拿到再强制刷新一次。
///
/// 为什么不"每 tick 重取"：tick 是 0.5s 一次的 UI 循环，重取会反复解包大文件。
/// 为什么必须重试：CarPlay 常从后台/锁屏态进入，首取可能撞上文件保护或解包还没完成，
/// 一次性放弃 = 整首歌页头空白（artworkKey 已置位，之后不再重画）。
@MainActor
enum CarPlayPlayerPageArtworkLoader {
    enum Outcome {
        case loaded(UIImage)
        case missing
        /// 曲目已切走 / 任务被取消：结果不许再上屏
        case abandoned
    }

    static let retryDelays: [Duration] = [.zero, .milliseconds(300), .seconds(1)]

    static func load(
        for track: Track,
        isStillCurrent: @MainActor () -> Bool
    ) async -> Outcome {
        var image: UIImage?
        for delay in retryDelays {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, isStillCurrent() else { return .abandoned }
            image = await ArtworkManager.shared.getArtwork(for: track)
            guard !Task.isCancelled else { return .abandoned }
            // 没有内嵌封面 = 确定没有，重试无意义
            if image != nil || !track.hasEmbeddedArt {
                break
            }
        }
        guard !Task.isCancelled, isStillCurrent() else { return .abandoned }
        if image == nil, track.hasEmbeddedArt {
            image = await ArtworkManager.shared.forceRefreshArtwork(for: track)
        }
        guard !Task.isCancelled, isStillCurrent() else { return .abandoned }
        return image.map(Outcome.loaded) ?? .missing
    }
}
