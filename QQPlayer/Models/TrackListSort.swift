//
//  TrackListSort.swift
//  QQPlayer
//
//  曲库列头排序三态决策（对齐 web 版：升序 → 降序 → 默认顺序，第三次点击清除）。
//  纯逻辑共享（iOS/macOS），macOS 的 MacTrackListView 消费。
//

import Foundation

/// 曲库列头排序状态与三态切换决策。
struct TrackListSort: Equatable {
    enum Key: String, CaseIterable {
        case title
        case artist
        case duration
    }

    enum Direction: Equatable {
        case ascending
        case descending
    }

    var key: Key?
    var direction: Direction?

    init(key: Key? = nil, direction: Direction? = nil) {
        self.key = key
        self.direction = direction
    }

    /// 列头点击三态循环：同列 升序 → 降序 → 清除（回默认顺序）；
    /// 不同列 = 切到该列升序。
    func toggled(by tapped: Key) -> TrackListSort {
        guard key == tapped else {
            return TrackListSort(key: tapped, direction: .ascending)
        }
        switch direction {
        case .ascending:
            return TrackListSort(key: tapped, direction: .descending)
        case .descending, nil:
            return TrackListSort(key: nil, direction: nil)
        }
    }
}
