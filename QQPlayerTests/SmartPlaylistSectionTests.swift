//
//  SmartPlaylistSectionTests.swift
//  QQPlayerTests
//
//  自动歌单区纯数据组装（SmartPlaylistSections）契约：
//  - 第一层顺序 = SmartPlaylistKind.allCases（recentAdded / recentPlayed / topPlayed / decades）
//  - 没有内容的类别、没有曲目的年代桶都不出现
//  - 计数按调用方传入值原样带出；decades 的计数单位是「年代个数」而不是曲目数
//

import Foundation
import Testing

@testable import QQPlayer

struct SmartPlaylistSectionTests {
    private func titles(_ kind: SmartPlaylistKind) -> String { "T:\(kind.rawValue)" }

    @Test("topLevelItems：顺序固定为 allCases，只保留有内容的类别，计数单位正确")
    func topLevelOrderAndEmptyFilter() {
        let items = SmartPlaylistSections.topLevelItems(
            songCounts: [.topPlayed: 3, .recentAdded: 5, .recentPlayed: 0],
            decadeCount: 2,
            title: titles
        )

        #expect(items.map(\.kind) == [.recentAdded, .topPlayed, .decades])
        #expect(items.map(\.title) == ["T:recentAdded", "T:topPlayed", "T:decades"])
        #expect(items.map(\.count) == [5, 3, 2])
        #expect(items.map(\.countUnit) == [.songs, .songs, .decades])
    }

    @Test("topLevelItems：缺省计数按 0 处理，全空时返回空数组")
    func topLevelAllEmpty() {
        let items = SmartPlaylistSections.topLevelItems(songCounts: [:], decadeCount: 0) { _ in "x" }
        #expect(items.isEmpty)
    }

    @Test("topLevelItems：默认标题取 Localized（跟随语言）")
    func topLevelDefaultTitle() {
        let items = SmartPlaylistSections.topLevelItems(songCounts: [.recentAdded: 1], decadeCount: 0)
        #expect(items.count == 1)
        #expect(items[0].title == Localized.smartPlaylistTitle(.recentAdded))
    }

    @Test("decadeItems：按可播曲目数过滤 0 桶，保持数据层顺序与标签")
    func decadeItemsFilterEmptyBuckets() {
        let buckets = [
            DecadeBucketInfo(key: "1950s", label: "1950s", count: 9),
            DecadeBucketInfo(key: "1970s", label: "1970s", count: 8),
            DecadeBucketInfo(key: "unknown", label: "未知", count: 3),
        ]

        // 1950s 只有不可播格式（可播 0）→ 不出现；1970s 计数改用可播曲目数而不是库内总数
        let items = SmartPlaylistSections.decadeItems(
            from: buckets,
            compatibleCounts: ["1950s": 0, "1970s": 4, "unknown": 2]
        )

        #expect(items.map(\.key) == ["1970s", "unknown"])
        #expect(items.map(\.title) == ["1970s", "未知"])
        #expect(items.map(\.count) == [4, 2])
    }

    // MARK: - coverTracks（自动歌单条目封面取哪些歌）

    private func track(_ stableId: String) -> Track {
        Track(stableId: stableId, title: stableId, path: "/music/\(stableId).flac")
    }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.stableId) }

    @Test("coverTracks：三类曲目歌单各取前 4 首，顺序沿用数据层")
    func coverTracksForTrackKinds() {
        var snapshot = SmartPlaylistSnapshot()
        snapshot.kindTracks[.recentAdded] = ["a1", "a2", "a3", "a4", "a5"].map(track)
        snapshot.kindTracks[.recentPlayed] = ["b1", "b2", "b3", "b4", "b5"].map(track)
        snapshot.kindTracks[.topPlayed] = ["c1", "c2", "c3", "c4", "c5"].map(track)

        #expect(ids(SmartPlaylistSections.coverTracks(for: .recentAdded, snapshot: snapshot)) == ["a1", "a2", "a3", "a4"])
        #expect(ids(SmartPlaylistSections.coverTracks(for: .recentPlayed, snapshot: snapshot)) == ["b1", "b2", "b3", "b4"])
        #expect(ids(SmartPlaylistSections.coverTracks(for: .topPlayed, snapshot: snapshot)) == ["c1", "c2", "c3", "c4"])
    }

    @Test("coverTracks：曲目不足 4 首时全部返回，空歌单返回空")
    func coverTracksShortAndEmpty() {
        var snapshot = SmartPlaylistSnapshot()
        snapshot.kindTracks[.topPlayed] = ["c1", "c2"].map(track)

        #expect(ids(SmartPlaylistSections.coverTracks(for: .topPlayed, snapshot: snapshot)) == ["c1", "c2"])
        #expect(SmartPlaylistSections.coverTracks(for: .recentAdded, snapshot: snapshot).isEmpty)
        #expect(SmartPlaylistSections.coverTracks(for: .decades, snapshot: snapshot).isEmpty)
    }

    @Test("coverTracks：年代条目按年代顺序摊平有曲目的桶，空桶不参与")
    func coverTracksForDecades() {
        var snapshot = SmartPlaylistSnapshot()
        snapshot.decades = [
            .init(key: "1950s", title: "1950s", count: 0),
            .init(key: "1970s", title: "1970s", count: 2),
            .init(key: "1990s", title: "1990s", count: 3),
        ]
        snapshot.decadeTracks["1950s"] = []
        snapshot.decadeTracks["1970s"] = ["p1", "p2"].map(track)
        snapshot.decadeTracks["1990s"] = ["n1", "n2", "n3"].map(track)

        #expect(ids(SmartPlaylistSections.coverTracks(for: .decades, snapshot: snapshot)) == ["p1", "p2", "n1", "n2"])
        #expect(ids(SmartPlaylistSections.coverTracks(forDecadeKey: "1990s", snapshot: snapshot)) == ["n1", "n2", "n3"])
        #expect(SmartPlaylistSections.coverTracks(forDecadeKey: "1950s", snapshot: snapshot).isEmpty)
        #expect(SmartPlaylistSections.coverTracks(forDecadeKey: "unknown", snapshot: snapshot).isEmpty)
    }

    @Test("coverTracks：limit 收窄或为 0 时按约定返回")
    func coverTracksLimit() {
        var snapshot = SmartPlaylistSnapshot()
        snapshot.kindTracks[.recentAdded] = ["a1", "a2", "a3"].map(track)

        #expect(ids(SmartPlaylistSections.coverTracks(for: .recentAdded, snapshot: snapshot, limit: 2)) == ["a1", "a2"])
        #expect(SmartPlaylistSections.coverTracks(for: .recentAdded, snapshot: snapshot, limit: 0).isEmpty)
        #expect(SmartPlaylistSections.maxCoverTracks == 4)
    }
}
