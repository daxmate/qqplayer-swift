//
//  CarPlayPlayerPageRenderCacheTests.swift
//  QQPlayerTests
//
//  播放页渲染缓存契约：缩略图同 key 只画一次、超容量淘汰最旧。
//  背景（2026-11-09）：页头 4 分钟重建 423 次，缩略图缓存就是用来把"同一桶重复重画"挡掉的，
//  容量上限与淘汰顺序在这里锁住，避免以后被改回"每 tick 重画"。
//

import Foundation
import Testing
import UIKit

@testable import QQPlayer

@MainActor
struct CarPlayPlayerPageThumbnailCacheTests {
    @Test("同 key 命中缓存：make 只调用一次")
    func reusesSameKey() {
        var cache = CarPlayPlayerPageThumbnailCache()
        var draws = 0

        let first = cache.image(for: "a|0:00/3:00|1") {
            draws += 1
            return UIImage()
        }
        let second = cache.image(for: "a|0:00/3:00|1") {
            draws += 1
            return UIImage()
        }

        #expect(draws == 1)
        #expect(first === second)
    }

    @Test("不同进度桶各自成图：进度变了必须重画")
    func separatesBuckets() {
        var cache = CarPlayPlayerPageThumbnailCache()
        var draws = 0

        _ = cache.image(for: "a|0:00/3:00|1") {
            draws += 1
            return UIImage()
        }
        _ = cache.image(for: "a|0:30/3:00|1") {
            draws += 1
            return UIImage()
        }

        #expect(draws == 2)
    }

    @Test("超过容量淘汰最旧：回到旧 key 会重画")
    func evictsOldestBeyondCapacity() {
        var cache = CarPlayPlayerPageThumbnailCache()
        var draws = 0

        for index in 0 ... 7 {
            _ = cache.image(for: "bucket-\(index)") {
                draws += 1
                return UIImage()
            }
        }
        #expect(draws == 8)

        // 第 9 个：容量 8 → 最早那桶被淘汰
        _ = cache.image(for: "bucket-8") {
            draws += 1
            return UIImage()
        }
        #expect(draws == 9)

        // bucket-0 已被淘汰 → 再次请求必须重画
        _ = cache.image(for: "bucket-0") {
            draws += 1
            return UIImage()
        }
        #expect(draws == 10)
    }

    @Test("清空后不再命中")
    func removeAllClears() {
        var cache = CarPlayPlayerPageThumbnailCache()
        var draws = 0

        _ = cache.image(for: "a") {
            draws += 1
            return UIImage()
        }
        cache.removeAll()
        _ = cache.image(for: "a") {
            draws += 1
            return UIImage()
        }

        #expect(draws == 2)
    }
}
