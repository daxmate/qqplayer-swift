//
//  LyricsCenterMathTests.swift
//  QQPlayerTests
//
//  歌词高亮行垂直居中的几何口径（纯函数，不依赖 UI / 模拟器）：
//  首行 clamp 到 0、末行 clamp 到 maxOffset、内容不足一屏返回 0、常规居中值。
//

@testable import QQPlayer
import Testing

struct LyricsCenterMathTests {
    @Test("首行：上限不足时 clamp 到 0")
    func firstLineClampsToZero() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 20,
            viewportHeight: 400,
            contentHeight: 2000
        )
        #expect(offset == 0, "首行前面没有可滚空间，必须停在 0（不能滚成负数）")
    }

    @Test("末行：clamp 到 maxOffset = contentHeight - viewportHeight")
    func lastLineClampsToMaxOffset() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 1980,
            viewportHeight: 400,
            contentHeight: 2000
        )
        #expect(offset == 1600)
    }

    @Test("内容不足一屏：返回 0")
    func shortContentReturnsZero() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 100,
            viewportHeight: 400,
            contentHeight: 300
        )
        #expect(offset == 0)
    }

    @Test("常规行：行中心 - 视口一半（误差 0）")
    func regularLineCentersExactly() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 920,
            viewportHeight: 400,
            contentHeight: 2000
        )
        #expect(offset == 720)
    }

    @Test("零几何（首帧未布局）：返回 0，不产生 NaN")
    func zeroGeometryReturnsZero() {
        #expect(LyricsCenterMath.centeredOffset(rowCenterY: 10, viewportHeight: 0, contentHeight: 500) == 0)
        #expect(LyricsCenterMath.centeredOffset(rowCenterY: 10, viewportHeight: 400, contentHeight: 0) == 0)
    }

    @Test("上内边距 40：行仍落在「可见区」中心（不是整块视口中心）")
    func topInsetShiftsCenter() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 920,
            viewportHeight: 400,
            contentHeight: 2000,
            topInset: 40,
            bottomInset: 0
        )
        #expect(offset == 700, "可见区是 [40, 400)，中心 220；行中心 920 → 偏移 920 - 220 = 700")
        // 反推：行的位置减偏移 = 220 = 40 + 可见高 360/2
        // 注意：右侧必须显式标 CGFloat —— 纯字面量算式会被推断成 Int，
        // `#expect` 跨类型比较直接为 false（即使数值相等）。
        let visibleCenter: CGFloat = 40 + (400 - 40) / 2
        #expect(920 - offset == visibleCenter)
    }

    @Test("下内边距同理：可见区中心上移一半")
    func bottomInsetShiftsCenter() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 920,
            viewportHeight: 400,
            contentHeight: 2000,
            topInset: 0,
            bottomInset: 60
        )
        let visibleCenter: CGFloat = 920 - (400 - 60) / 2
        #expect(offset == visibleCenter)
    }

    @Test("内边距吃掉整块视口：不产生负数 / NaN")
    func insetsLargerThanViewport() {
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: 920,
            viewportHeight: 100,
            contentHeight: 2000,
            topInset: 80,
            bottomInset: 80
        )
        #expect(offset == 840, "可见高按 0 处理 → 目标 = 920 - 80 - 0")
    }

    @Test("闭环残差：行在下方为正、上方为负、居中小于阈值")
    func centeringDeltaSign() {
        #expect(LyricsCenterMath.centeringDelta(rowMidY: 700, visibleMidY: 500) == 200)
        #expect(LyricsCenterMath.centeringDelta(rowMidY: 300, visibleMidY: 500) == -200)
        #expect(LyricsCenterMath.isCentered(delta: 0.4))
        #expect(!LyricsCenterMath.isCentered(delta: 0.6))
        #expect(!LyricsCenterMath.isCentered(delta: -0.6))
    }

    @Test("闭环一次收敛：用残差修正后残差归零（模拟一次迭代）")
    func singleCorrectionConverges() {
        var visibleMid: CGFloat = 500
        let rowMid: CGFloat = 780
        let delta = LyricsCenterMath.centeringDelta(rowMidY: rowMid, visibleMidY: visibleMid)
        // 一次「把内容沿 y 轴平移残差」的补正 = 可见区中心随之移动同样的量
        visibleMid += delta
        #expect(LyricsCenterMath.isCentered(
            delta: LyricsCenterMath.centeringDelta(rowMidY: rowMid, visibleMidY: visibleMid)
        ))
    }

    @Test("居中后再反推：行中心回到视口中心（含首末行）")
    func roundTripCenter() {
        let viewport: CGFloat = 400
        let content: CGFloat = 2000

        for rowCenter in stride(from: CGFloat(20), through: 1980, by: 130) {
            let offset = LyricsCenterMath.centeredOffset(
                rowCenterY: rowCenter,
                viewportHeight: viewport,
                contentHeight: content
            )
            let rowCenterInViewport = rowCenter - offset
            let maxOffset = content - viewport
            // 首末行受可滚范围限制，按“贴边”判定；其余必须严格居中
            if offset > 0, offset < maxOffset {
                #expect(abs(rowCenterInViewport - viewport / 2) < 0.001)
            } else {
                #expect(offset == 0 || offset == maxOffset)
            }
        }
    }
}
