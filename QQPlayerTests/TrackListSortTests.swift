//  TrackListSortTests.swift
//  QQPlayerTests
//
//  曲库列头排序三态决策防回归测试（web 版语义：升序 → 降序 → 默认顺序）。
//

import Testing

@testable import QQPlayer

struct TrackListSortTests {
    @Test("初始状态：无排序")
    func initialIsUnsorted() {
        let sort = TrackListSort()
        #expect(sort.key == nil)
        #expect(sort.direction == nil)
    }

    @Test("点击新列：切到该列升序")
    func tappingNewColumnStartsAscending() {
        let sort = TrackListSort()
        let next = sort.toggled(by: .title)
        #expect(next.key == .title)
        #expect(next.direction == .ascending)
    }

    @Test("同列第二次点击：降序")
    func secondTapSameColumnDescending() {
        let sort = TrackListSort(key: .artist, direction: .ascending)
        let next = sort.toggled(by: .artist)
        #expect(next.key == .artist)
        #expect(next.direction == .descending)
    }

    @Test("同列第三次点击：清除回默认（web 版三态语义）")
    func thirdTapClearsToDefault() {
        let sort = TrackListSort(key: .duration, direction: .descending)
        let cleared = sort.toggled(by: .duration)
        #expect(cleared.key == nil)
        #expect(cleared.direction == nil)
    }

    @Test("降序状态点击另一列：重置为该列升序")
    func switchingColumnResetsAscending() {
        let sort = TrackListSort(key: .title, direction: .descending)
        let next = sort.toggled(by: .duration)
        #expect(next.key == .duration)
        #expect(next.direction == .ascending)
    }
}
