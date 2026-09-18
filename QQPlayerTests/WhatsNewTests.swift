//
//  WhatsNewTests.swift
//  QQPlayerTests
//
//  新功能弹窗（WhatsNew）纯逻辑测试：
//  - 首次启动（无 lastSeen 记录）不弹（避免与 Tutorial 撞车）
//  - 看过后同版本不弹
//  - 模拟升级到新版本（注入不同版本号）→ 弹
//  - markSeen 持久化（跨 store 实例仍可见）
//  使用独立 UserDefaults suite，不污染全局 standard defaults。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("WhatsNew 新功能弹窗", .serialized)
struct WhatsNewTests {
    private let suiteName = "WhatsNewTests"

    private func makeStore() -> WhatsNewStore {
        WhatsNewStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test("已读版本 != 当前版本（无记录 / 旧版本记录）→ 弹")
    func lastSeenNotCurrentShows() {
        let store = makeStore()
        store.resetForTesting()

        // 无已读记录：从旧版升到本版、从未看过通告 → 应弹
        // （全新安装不弹由挂载层保证：Tutorial 显示期间不检查，完成时 markSeen）
        #expect(store.lastSeenVersion() == nil)
        #expect(store.shouldShowCurrent() == true)

        // 老用户升级：已读的是旧版本号（生产真实升级路径）→ 仍弹
        store.markSeen("0.9.0 (50)")
        #expect(store.shouldShowCurrent(version: "9.9.9 (999)") == true)
    }

    @Test("看过后同版本不再弹")
    func seenSameVersionDoesNotShow() {
        let store = makeStore()
        store.resetForTesting()

        store.markSeen(WhatsNewContent.currentVersion)
        #expect(store.shouldShowCurrent() == false)
        #expect(store.shouldShowCurrent(version: WhatsNewContent.currentVersion) == false)
    }

    @Test("markSeen 持久化（跨 store 实例）")
    func markSeenPersists() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removeObject(forKey: "whatsnew.lastSeenVersion")

        // 已读当前版本 → 不再弹（用当前版本号，避免硬编码随发版失效）
        let current = WhatsNewContent.currentVersion
        WhatsNewStore(defaults: defaults).markSeen(current)

        let freshStore = WhatsNewStore(defaults: defaults)
        #expect(freshStore.lastSeenVersion() == current)
        #expect(freshStore.shouldShowCurrent() == false)
    }
}
