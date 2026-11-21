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
