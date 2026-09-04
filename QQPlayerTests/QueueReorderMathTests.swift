//  QueueReorderMathTests.swift
//  QQPlayerTests
//
//  队列手动重排的索引修正防回归测试（macOS 队列面板 / B 组队列持久化）。
//  覆盖：List onMove 插入点换算、移动后 currentIndex 追踪当前曲、删除后
//  currentIndex 修正。索引算错会让面板拖排后"当前播放高亮跳到别的歌"或
//  "点下一首跳过/重复"——最容易被拖排功能打回头的回归点。

import Foundation
import Testing

@testable import QQPlayer

struct QueueReorderMathTests {
    // MARK: - insertIndex（onMove 落点换算）

    @Test("源在目标前：插入点 = destination - 1")
    func moveDownInsertPoint() {
        // 队列 [A B C D E]，把 A(0) 拖到 destination=3 → 实际插到 index 2：B C A D E
        #expect(QueueReorderMath.insertIndex(sourceIndex: 0, destination: 3) == 2)
    }

    @Test("源在目标后：插入点 = destination")
    func moveUpInsertPoint() {
        // 把 D(3) 拖到 destination=1 → 插到 1：A D B C E
        #expect(QueueReorderMath.insertIndex(sourceIndex: 3, destination: 1) == 1)
    }

    // MARK: - adjustedCurrentIndexAfterMove

    @Test("移动的就是当前曲：currentIndex = 插入点")
    func movingCurrentTrackFollows() {
        #expect(QueueReorderMath.adjustedCurrentIndexAfterMove(sourceIndex: 2, insertAt: 0, currentIndex: 2) == 0)
        #expect(QueueReorderMath.adjustedCurrentIndexAfterMove(sourceIndex: 0, insertAt: 4, currentIndex: 0) == 4)
    }

    @Test("当前曲在移动项后、被插到它之前：currentIndex +1")
    func currentTrackPushedBack() {
        // 队列 [A(cur) B C D]，把 D(3) 移到最前(insertAt 0)：D A B C → cur 0→1
        #expect(QueueReorderMath.adjustedCurrentIndexAfterMove(sourceIndex: 3, insertAt: 0, currentIndex: 0) == 1)
    }

    @Test("当前曲在移动项前、移动项插到它之后/处：currentIndex -1")
    func currentTrackPushedForward() {
        // 队列 [A(cur) B C D]，把 A? 不适用——当前在前。把 B(1) 移到末尾(insertAt 3)：A C D B → cur 0
        #expect(QueueReorderMath.adjustedCurrentIndexAfterMove(sourceIndex: 1, insertAt: 3, currentIndex: 0) == 0)
        // 当前曲在 index 1，把 index 0 移到 3：B C D A？不——0→2：源<cur(1) 且 insertAt(2)>=cur(1) → cur 0
        #expect(QueueReorderMath.adjustedCurrentIndexAfterMove(sourceIndex: 0, insertAt: 2, currentIndex: 1) == 0)
    }

    @Test("移动与当前曲不相交：currentIndex 不变")
    func disjointMoveKeepsCurrent() {
        // 队列 [A B(cur=1) C D E]，把 D(3) 移到末尾 insertAt 4：A B C E D → cur 1
        #expect(QueueReorderMath.adjustedCurrentIndexAfterMove(sourceIndex: 3, insertAt: 4, currentIndex: 1) == 1)
    }

    // MARK: - adjustedCurrentIndexAfterRemoval

    @Test("移除当前项之前的项：currentIndex 前移")
    func removalBeforeCurrentDecrements() {
        #expect(QueueReorderMath.adjustedCurrentIndexAfterRemoval(removedIndices: [0, 1], currentIndex: 3) == 1)
    }

    @Test("移除当前项之后的项：currentIndex 不变")
    func removalAfterCurrentKeeps() {
        #expect(QueueReorderMath.adjustedCurrentIndexAfterRemoval(removedIndices: [4, 5], currentIndex: 2) == 2)
    }

    @Test("前后混合移除：只算 current 之前的数量")
    func mixedRemoval() {
        #expect(QueueReorderMath.adjustedCurrentIndexAfterRemoval(removedIndices: [0, 3, 6], currentIndex: 4) == 3)
    }

    @Test("空移除列表：不变")
    func emptyRemovalKeeps() {
        #expect(QueueReorderMath.adjustedCurrentIndexAfterRemoval(removedIndices: [], currentIndex: 2) == 2)
    }
}
