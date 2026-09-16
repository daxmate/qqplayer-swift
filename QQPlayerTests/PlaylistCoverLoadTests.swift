//
//  PlaylistCoverLoadTests.swift
//  QQPlayerTests
//
//  INV-22 另一半（2026-09-16）：歌单自定义封面**读取失败必须计数并上屏**的守护。
//
//  盘上事实（容器/文件）用临时目录真造，不碰 App Group；登记处用单例 + `reset()` 隔离。
//

import Foundation
import Testing

@testable import QQPlayer

@MainActor
struct PlaylistCoverLoadTests {
    private func tempContainer(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-cover-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("封面解析：没配封面 = .none（正常路径，不是失败）")
    func emptyPathIsNotAFailure() {
        #expect(PlaylistCoverResolver.resolve(customCoverImagePath: nil, containerURL: nil) == .none)
        #expect(PlaylistCoverResolver.resolve(customCoverImagePath: "", containerURL: nil) == .none)
        #expect(PlaylistCoverResolver.resolve(customCoverImagePath: "   ", containerURL: nil) == .none)
    }

    @Test("封面解析：容器不可达 / 文件缺失 / 不是常规文件 → 三种原因码各不相同")
    func unavailableReasons() throws {
        let container = try tempContainer("reasons")

        #expect(
            PlaylistCoverResolver.resolve(customCoverImagePath: "cover.jpg", containerURL: nil)
                == .unavailable(reason: PlaylistCoverResolver.Reason.containerUnavailable)
        )
        #expect(
            PlaylistCoverResolver.resolve(customCoverImagePath: "cover.jpg", containerURL: container)
                == .unavailable(reason: PlaylistCoverResolver.Reason.fileMissing)
        )

        let directory = container.appendingPathComponent("dir.jpg", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(
            PlaylistCoverResolver.resolve(customCoverImagePath: "dir.jpg", containerURL: container)
                == .unavailable(reason: PlaylistCoverResolver.Reason.notRegularFile)
        )
    }

    @Test("封面解析：文件在 = .available（URL 落在容器内）")
    func availableFile() throws {
        let container = try tempContainer("available")
        let file = container.appendingPathComponent("cover.jpg")
        try Data("jpeg-bytes".utf8).write(to: file)

        let resolution = PlaylistCoverResolver.resolve(
            customCoverImagePath: "cover.jpg",
            containerURL: container
        )
        #expect(resolution == .available(file))

        // 前后空白照旧可解析（DB 里的路径偶尔带空白）
        #expect(
            PlaylistCoverResolver.resolve(customCoverImagePath: " cover.jpg ", containerURL: container)
                == .available(file)
        )
    }

    @Test("封面解析：登记键优先 DB id，回落 slug")
    func playlistKeyShape() {
        #expect(PlaylistCoverResolver.playlistKey(id: 7, slug: "pl") == "id:7")
        #expect(PlaylistCoverResolver.playlistKey(id: nil, slug: "pl") == "slug:pl")
    }

    @Test("封面失败登记：按歌单去重（重复申报不累加）、读到后清除、reset 归零")
    func failuresDeduplicateByPlaylist() {
        let store = PlaylistCoverLoadFailuresStore.shared
        store.reset()

        store.record(playlistKey: "id:1", path: "a.jpg", reason: PlaylistCoverResolver.Reason.fileMissing)
        store.record(playlistKey: "id:1", path: "a.jpg", reason: PlaylistCoverResolver.Reason.fileMissing)
        #expect(store.count == 1, "同一歌单反复渲染只算一个失败（数的是歌单数，不是失败次数）")

        store.record(playlistKey: "id:1", path: "a.jpg", reason: PlaylistCoverResolver.Reason.decodeFailed)
        #expect(store.count == 1, "同一歌单换原因 = 覆盖，不累加")
        #expect(store.failures.first?.reason == PlaylistCoverResolver.Reason.decodeFailed)

        store.record(playlistKey: "id:2", path: "b.jpg", reason: PlaylistCoverResolver.Reason.fileMissing)
        #expect(store.count == 2)
        #expect(store.failures.map(\.playlistKey) == ["id:1", "id:2"], "按歌单键升序（确定性）")

        store.clear(playlistKey: "id:1")
        #expect(store.count == 1)
        store.clear(playlistKey: "id:1")
        #expect(store.count == 1, "清除幂等")

        store.reset()
        #expect(store.failures.isEmpty, "reset 归零")
    }

    @Test("封面披露投影：只出计数 > 0 的行，缺口类 + 带说明 key")
    func coverDisclosureRows() {
        #expect(
            SyncEntityOutcomeDisclosure.coverRows(unavailable: 0).isEmpty,
            "全 0 = 空表（不做恒零噪音表）"
        )
        let rows = SyncEntityOutcomeDisclosure.coverRows(unavailable: 2)
        #expect(rows.count == 1)
        #expect(rows[0].labelKey == SyncEntityOutcomeDisclosure.coverUnavailableLabelKey)
        #expect(rows[0].hintKey == SyncEntityOutcomeDisclosure.coverUnavailableHintKey)
        #expect(rows[0].isGap)
        #expect(rows[0].count == 2)
    }
}
