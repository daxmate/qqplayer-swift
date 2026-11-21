//
//  PlayerGlassBackgroundTests.swift
//  QQPlayerTests
//
//  播放页「封面毛玻璃背景」的纯逻辑测试（不依赖 UI / 模拟器截图）：
//    1. ArtworkBlurCache 的 LRU 语义（命中同实例 / 超上限淘汰最旧 / 不同键不混淆 / 上限 6）
//    2. 开关默认值解析（未写过 = 开；写 false 后 = 关）
//    3. 回落判定（开关关 / 无封面 / 降低透明度 三条件各自回落）
//

@testable import QQPlayer
import Testing
import UIKit

struct ArtworkBlurCacheTests {
    private func makeImage(_ seed: CGFloat) -> UIImage {
        let size = CGSize(width: 4, height: 4)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: seed, green: 0.5, blue: 0.5, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("容量上限 = 6")
    func capacityIsSix() {
        #expect(ArtworkBlurCache.capacity == 6)
    }

    @Test("命中返回同一实例")
    func hitReturnsSameInstance() {
        let cache = ArtworkBlurCache()
        let image = makeImage(0.2)
        cache.store(image, forKey: "a")

        let hit = cache.cachedImage(for: "a")
        #expect(hit === image)
    }

    @Test("不同键不混淆")
    func distinctKeysDoNotMix() {
        let cache = ArtworkBlurCache()
        let first = makeImage(0.1)
        let second = makeImage(0.9)
        cache.store(first, forKey: "a")
        cache.store(second, forKey: "b")

        #expect(cache.cachedImage(for: "a") === first)
        #expect(cache.cachedImage(for: "b") === second)
        #expect(cache.cachedImage(for: "c") == nil)
    }

    @Test("LRU 超上限淘汰最旧（被读过的键不算最旧）")
    func lruEvictsOldestUnusedKey() {
        let cache = ArtworkBlurCache()
        for index in 1 ... ArtworkBlurCache.capacity {
            cache.store(makeImage(CGFloat(index) / 10), forKey: "k\(index)")
        }
        #expect(cache.count == ArtworkBlurCache.capacity)

        // 触碰 k1：最旧变成 k2
        _ = cache.cachedImage(for: "k1")
        cache.store(makeImage(0.7), forKey: "k7")

        #expect(cache.cachedImage(for: "k2") == nil, "最久未使用的键应被淘汰")
        #expect(cache.cachedImage(for: "k1") != nil, "刚读过的键必须保留")
        #expect(cache.cachedImage(for: "k7") != nil)
        #expect(cache.count == ArtworkBlurCache.capacity)
    }

    @Test("重复写同一键不占两个位置")
    func rewriteSameKeyKeepsCapacity() {
        let cache = ArtworkBlurCache()
        let first = makeImage(0.3)
        let second = makeImage(0.4)
        cache.store(first, forKey: "a")
        cache.store(second, forKey: "a")

        #expect(cache.count == 1)
        #expect(cache.cachedImage(for: "a") === second)
    }
}

struct PlayerGlassSettingTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "PlayerGlassSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("未写过时默认开")
    func defaultIsEnabled() {
        let defaults = makeDefaults()
        PlayerGlassBackground.registerDefaults(defaults)

        #expect(defaults.bool(forKey: PlayerGlassBackground.storageKey) == true)
        #expect(PlayerGlassBackground.isEnabled(defaults) == true)
    }

    @Test("写 false 后读到关")
    func explicitFalseWins() {
        let defaults = makeDefaults()
        PlayerGlassBackground.registerDefaults(defaults)
        defaults.set(false, forKey: PlayerGlassBackground.storageKey)

        #expect(PlayerGlassBackground.isEnabled(defaults) == false)
    }

    @Test("回落判定：三条件各自回落，全通过才生效")
    func activeOnlyWhenAllConditionsHold() {
        #expect(PlayerGlassBackground.isActive(isEnabled: true, hasArtwork: true, reduceTransparency: false))
        #expect(!PlayerGlassBackground.isActive(isEnabled: false, hasArtwork: true, reduceTransparency: false))
        #expect(!PlayerGlassBackground.isActive(isEnabled: true, hasArtwork: false, reduceTransparency: false))
        #expect(!PlayerGlassBackground.isActive(isEnabled: true, hasArtwork: true, reduceTransparency: true))
        #expect(!PlayerGlassBackground.isActive(isEnabled: false, hasArtwork: false, reduceTransparency: true))
    }
}
