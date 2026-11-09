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
