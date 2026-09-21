//
//  IntentPlaybackServiceTests.swift
//  QQPlayerTests
//
//  覆盖缺口审计 P1-2（AppIntents 单测线）。本文件只锁当前工具链下**唯一可编译、
//  且不需要运行时单例**的缝合面：`IntentPlaybackService` 的 pending mix 状态机。
//
//  为什么 P1-2 建议的另外四个模块没写在这里（工具链事实，已实测）：
//   · `AudioIntentValueQuery` / `IntentEntityStore` / `SpotlightLibraryIndexer`
//     **整文件**包在 `#if canImport(MediaIntents)` 内，而 `MediaIntents` 在当前
//     工具链（Xcode 26.6；iPhoneOS26.5.sdk / iPhoneSimulator26.5.sdk）**不存在**
//     （探针：`xcrun -sdk iphonesimulator swiftc -typecheck -target
//     arm64-apple-ios26.0-simulator`，`import MediaIntents` → `no such module`）
//     → 类型不参与编译，测试无法引用它们（写成 `#if` 包住也只是永远不跑的死代码）。
//   · 即便将来 SDK 到位：`tokenize` / `searchResults`（排名在其中内联，审计报告里
//     写的 `rankedSongs` 函数并不存在）/ `unknownArtistName` 都是 `private`，
//     数据源写死 `DatabaseManager.shared`（`static let`，测试期不可替换）→ 仍无缝合面。
//   · `MixGenerator` 能编译（FoundationModels 在 iOS 26.5 SDK 里存在），但
//     `fallbackMix` / `candidateTracks` / `describe` 全 private，且 `generate()` 先过
//     `SystemLanguageModel.default.availability` → 不改生产结构就无法注入假生成器。
//
//  本文件锁的是 mix 卡片（`MixCardSnippetIntent` / `MixCardSnippetView`）的数据源契约：
//   · 没生成过 mix → `pendingMix == nil`（卡片抛 `mixUnavailable`，不渲染空卡片）
//   · `setPendingMix` 原样保存标题与曲目顺序，且保存态为未保存（卡片显示「Save」而非「Saved」）
//   · 第二次生成覆盖第一次（旧标题 / 旧曲目不残留）
//   · 没有 pending mix 时 `savePendingMix()` 返回 nil（`SaveMixIntent` 的 `_ = try` 不炸）
//
//  这些用例不触任何单例：`IntentPlaybackService` 的 database / coordinator / playerEngine
//  都是计算属性（首次访问才解析），pending mix 的读写与 `savePendingMix` 的 nil 分支
//  都在访问它们之前返回。
//
//  注意：`#expect` 宏体不接受 `try`——断言一律先把取值 try 到局部变量再断言。
//
//  本文件从 a0e5faf（分支 test/coverage-gaps-p1）适配到 main @ 50f8a9b：
//  `pendingMix` / `setPendingMix(title:tracks:)` / `savePendingMix()` 签名与行号
//  （171/173/179）一致，`PendingMix(title:tracks:savedPlaylistId:)` 与
//  `Track(stableId:title:path:)` 成员初始化器一致。
//

import Foundation
import Testing

@testable import QQPlayer

@MainActor
struct IntentPlaybackServiceTests {
    /// 只用到 stableId / title（pending mix 不读 path），其余字段走成员初始化器的可选默认值。
    private func makeTrack(stableId: String, title: String) -> Track {
        Track(stableId: stableId, title: title, path: "/library/\(stableId).flac")
    }

    @Test("没有生成过 mix 时 pendingMix 为 nil —— 卡片走 mixUnavailable 分支，而不是渲染空卡片")
    func pendingMixStartsNil() {
        #expect(IntentPlaybackService().pendingMix == nil)
    }

    @Test("setPendingMix 原样保存标题与曲目顺序，保存态为未保存（卡片显示 Save 按钮）")
    func setPendingMixStoresRequestedMix() {
        let service = IntentPlaybackService()
        let tracks = [
            makeTrack(stableId: "id-a", title: "A"),
            makeTrack(stableId: "id-b", title: "B"),
            makeTrack(stableId: "id-c", title: "C"),
        ]

        service.setPendingMix(title: "Chill Evening", tracks: tracks)

        #expect(service.pendingMix?.title == "Chill Evening")
        #expect(service.pendingMix?.tracks.map(\.stableId) == ["id-a", "id-b", "id-c"])
        #expect(service.pendingMix?.savedPlaylistId == nil)
    }

    @Test("第二次 setPendingMix 覆盖第一次 —— 旧标题与旧曲目不残留")
    func setPendingMixReplacesPreviousMix() {
        let service = IntentPlaybackService()
        service.setPendingMix(
            title: "First",
            tracks: [makeTrack(stableId: "id-first", title: "First")]
        )

        service.setPendingMix(
            title: "Second",
            tracks: [makeTrack(stableId: "id-second", title: "Second")]
        )

        #expect(service.pendingMix?.title == "Second")
        #expect(service.pendingMix?.tracks.map(\.stableId) == ["id-second"])
        #expect(service.pendingMix?.savedPlaylistId == nil)
    }

    @Test("没有 pending mix 时 savePendingMix 返回 nil —— SaveMixIntent 的 _ = try 不炸、也不建歌单")
    func savePendingMixWithoutPendingMixReturnsNil() throws {
        let service = IntentPlaybackService()

        let saved = try service.savePendingMix()

        #expect(saved == nil)
        #expect(service.pendingMix == nil)
    }
}
