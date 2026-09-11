//
//  SyncSelectionStoreTests.swift
//  QQPlayerTests
//
//  M6（T2）同步选择集持久化 `SyncSelectionStore` 测试：
//  - 三档 round-trip：`.all` / `.playlists([...])`（含收藏标识）/ `.relativePaths([...])`
//  - 写盘走 `normalized`（非法标识 / 非法路径丢弃）
//  - 缺失 / 损坏 JSON / 非法值 / 未知 kind / 未知版本 → 空选择（`.playlists([])`），绝不炸
//  - 注入独立 UserDefaults suite：不污染 `.standard`
//
//  夹具：每个用例一个唯一 suite（UUID），结束移除 persistentDomain。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncSelectionStoreTests {
    // MARK: - 夹具

    /// 独立 suite 的 UserDefaults（用完即清，不碰 standard）。
    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "qqplayer.tests.sync-selection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func writeRaw(_ json: String, to defaults: UserDefaults, key: String = SyncSelectionStore.defaultKey) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    // MARK: - round-trip

    @Test("三档 round-trip：all / playlists（含收藏）/ relativePaths")
    func roundTripAllKinds() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        // 缺失 → 空选择（不推不拉）
        #expect(store.load() == .playlists([]))

        let selections: [SyncCollectionSelection] = [
            .all,
            .playlists([SyncCollectionSelection.favoritesPlaylistID, "jazz"]),
            .relativePaths(["专辑/song.flac", "b/c.mp3"]),
            .playlists([]),
        ]
        for selection in selections {
            store.save(selection)
            #expect(store.load() == selection.normalized, "round-trip 应保持 \(selection)")
        }
    }

    @Test("写盘走 normalized：非法歌单标识被丢弃")
    func saveDropsInvalidPlaylistIDs() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        let raw = "jazz"
        let tooLong = String(repeating: "x", count: SyncCollectionSelection.maxPlaylistIDLength + 1)
        store.save(.playlists([" \(raw) ", "", "bad/id", "..", tooLong, "jazz", "classic"]))

        // 去空白 + 丢非法 + 去重 + 升序
        #expect(store.load() == .playlists(["classic", "jazz"]))
    }

    @Test("写盘走 normalized：非法相对路径被丢弃（空 → 空选择语义）")
    func saveDropsInvalidPaths() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        store.save(.relativePaths(["/absolute.flac", "../escape.flac", "./ok/song.flac"]))
        let loaded = store.load()
        #expect(loaded == .relativePaths(["ok/song.flac"]))
        #expect(!loaded.isEmptySelection)

        store.save(.relativePaths(["/absolute.flac", "../escape.flac"]))
        #expect(store.load().isEmptySelection, "全非法 → 规范化后为空 → 空选择语义")
    }

    // MARK: - 失败回退

    @Test("损坏 JSON → 空选择（不炸）")
    func corruptedJSONFallsBack() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        writeRaw("{ this is not json", to: defaults)
        #expect(store.load() == .playlists([]))
    }

    @Test("类型不符（字符串而非 JSON 对象）→ 空选择")
    func wrongShapeFallsBack() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        writeRaw("\"playlists\"", to: defaults)
        #expect(store.load() == .playlists([]))
    }

    @Test("未知 kind / 未知版本 → 空选择（不猜形态）")
    func unknownKindOrVersionFallsBack() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        writeRaw(#"{"version":1,"kind":"mystery","values":["jazz"]}"#, to: defaults)
        #expect(store.load() == .playlists([]))

        writeRaw(#"{"version":99,"kind":"all","values":[]}"#, to: defaults)
        #expect(store.load() == .playlists([]))

        writeRaw(#"{"version":1,"kind":"playlists","values":["bad/id","jazz"]}"#, to: defaults)
        #expect(store.load() == .playlists(["bad/id", "jazz"]), "读侧不再二次过滤（写侧已规范化）")
    }

    @Test("存档里的值非法但形态合法：读回按值返回，选择集自身语义（isEmptySelection）仍然成立")
    func loadedSelectionStillNormalizes() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)

        writeRaw(#"{"version":1,"kind":"relativePaths","values":["../x.flac"]}"#, to: defaults)
        let loaded = store.load()
        #expect(loaded.relativePaths?.isEmpty == true, "非法路径经选择集口径被过滤为空")
        #expect(loaded.isEmptySelection)
    }

    // MARK: - 隔离

    @Test("独立 suite：写入不落到 standard")
    func doesNotTouchStandardDefaults() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncSelectionStore(defaults: defaults)
        store.save(.relativePaths(["song.flac"]))

        #expect(UserDefaults.standard.data(forKey: SyncSelectionStore.defaultKey) == nil)
    }

    @Test("自定义 key：不影响默认键")
    func customKeyIsIsolated() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let custom = SyncSelectionStore(defaults: defaults, key: "sync.collectionSelection.custom")
        custom.save(.all)
        #expect(custom.load() == .all)
        #expect(SyncSelectionStore(defaults: defaults).load() == .playlists([]))
    }
}
