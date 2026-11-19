//
//  LocateCurrentTrackPlanTests.swift
//  QQPlayerTests
//
//  「mini 播放条长按 → 定位当前播放」的纯决策（2026-11-19）：
//    · 没有在播曲目 → 不处理（不导航、不 toast、不崩）；
//    · 目标行只在「所有歌曲」列表里存在时才滚动（不在列表 → 只入栈不滚动）。
//
//  规则实现唯一入口：`QQPlayer/Views/Library/LibraryView.swift` 的 `LocateCurrentTrackPlan`。
//

import Foundation
import Testing

@testable import QQPlayer

struct LocateCurrentTrackPlanTests {
    @Test("没有在播曲目（nil / 空串）→ 长按无效")
    func ignoresMissingCurrentTrack() {
        #expect(!LocateCurrentTrackPlan.shouldHandle(currentTrackStableId: nil))
        #expect(!LocateCurrentTrackPlan.shouldHandle(currentTrackStableId: ""))
    }

    @Test("有在播曲目 → 处理定位请求")
    func handlesExistingCurrentTrack() {
        #expect(LocateCurrentTrackPlan.shouldHandle(currentTrackStableId: "stable-1"))
    }

    @Test("目标行下标按列表当前顺序返回")
    func targetRowIndexFollowsListOrder() {
        let ids = ["a", "b", "c"]

        #expect(LocateCurrentTrackPlan.targetRowIndex(stableId: "a", in: ids) == 0)
        #expect(LocateCurrentTrackPlan.targetRowIndex(stableId: "c", in: ids) == 2)
    }

    @Test("目标行不在列表（队列来自其他列表 / 已被过滤）→ nil，只入栈不滚动")
    func missingTargetRowReturnsNil() {
        let ids = ["a", "b"]

        #expect(LocateCurrentTrackPlan.targetRowIndex(stableId: "z", in: ids) == nil)
        #expect(LocateCurrentTrackPlan.targetRowIndex(stableId: "z", in: []) == nil)
    }
}
