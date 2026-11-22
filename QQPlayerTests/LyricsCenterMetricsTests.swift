//
//  LyricsCenterMetricsTests.swift
//  QQPlayerTests
//
//  歌词高亮行垂直居中的行高度量（LyricsCenterMetrics）锁值测试。
//  背景（2026-11-22）：切句后高亮行偏上，根因是字号 / padding 逐帧插值 + 同步 scrollTo；
//  修复后行高按目标档位落定，占位 = 视口一半 - 高亮行半高。本测试钉住档位取值与公式。
//

import Testing

@testable import QQPlayer

struct LyricsCenterMetricsFontSizeTests {
    @Test("普通模式字号档位：1.0 → 26 / 0.66 → 19 / 0.40 及更远 → 16")
    func normalTiers() {
        #expect(LyricsCenterMetrics.fontSize(emphasis: 1.0, karaoke: false, fontScale: 1.0) == 26)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 0.66, karaoke: false, fontScale: 1.0) == 19)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 0.40, karaoke: false, fontScale: 1.0) == 16)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 0.20, karaoke: false, fontScale: 1.0) == 16)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 0.08, karaoke: false, fontScale: 1.0) == 16)
    }

    @Test("跟唱字号档位：1.0 → 22 / 0.66 → 19")
    func karaokeTiers() {
        #expect(LyricsCenterMetrics.fontSize(emphasis: 1.0, karaoke: true, fontScale: 1.0) == 22)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 0.66, karaoke: true, fontScale: 1.0) == 19)
    }

    @Test("字号 × fontScale：1.0 / 1.33")
    func scaled() {
        #expect(LyricsCenterMetrics.fontSize(emphasis: 1.0, karaoke: false, fontScale: 1.0) == 26)
        #expect(abs(LyricsCenterMetrics.fontSize(emphasis: 1.0, karaoke: false, fontScale: 1.33) - 34.58) < 0.001)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 1.0, karaoke: false, fontScale: 1.33) == 26 * 1.33)
    }

    @Test("阅读态字号 = 正常大小下一档（19）× fontScale")
    func readingTier() {
        #expect(LyricsCenterMetrics.fontSize(emphasis: 1.0, karaoke: false, reading: true, fontScale: 1.0) == 19)
        #expect(LyricsCenterMetrics.fontSize(emphasis: 0.66, karaoke: false, reading: true, fontScale: 1.33) == 19 * 1.33)
    }
}

struct LyricsCenterMetricsPaddingTests {
    @Test("普通模式 padding：1.0 → 24 / 0.66 及更远 → 16")
    func normalPadding() {
        #expect(LyricsCenterMetrics.verticalPadding(emphasis: 1.0, karaoke: false) == 24)
        #expect(LyricsCenterMetrics.verticalPadding(emphasis: 0.66, karaoke: false) == 16)
        #expect(LyricsCenterMetrics.verticalPadding(emphasis: 0.40, karaoke: false) == 16)
    }

    @Test("跟唱 padding 恒为 18")
    func karaokePadding() {
        #expect(LyricsCenterMetrics.verticalPadding(emphasis: 1.0, karaoke: true) == 18)
        #expect(LyricsCenterMetrics.verticalPadding(emphasis: 0.66, karaoke: true) == 18)
    }
}

struct LyricsCenterMetricsRowHalfHeightTests {
    @Test("行高 = ceil(字号 × 1.2)")
    func lineHeight() {
        #expect(LyricsCenterMetrics.lineHeight(fontSize: 26) == 32)
        #expect(LyricsCenterMetrics.lineHeight(fontSize: 19) == 23)
        #expect(LyricsCenterMetrics.lineHeight(fontSize: 22) == 27)
    }

    @Test("普通模式高亮行半高：26/19/16 档")
    func normalRows() {
        #expect(LyricsCenterMetrics.rowHalfHeight(emphasis: 1.0, karaoke: false, fontScale: 1.0) == 40)
        #expect(LyricsCenterMetrics.rowHalfHeight(emphasis: 0.66, karaoke: false, fontScale: 1.0) == 27.5)
        #expect(LyricsCenterMetrics.rowHalfHeight(emphasis: 0.40, karaoke: false, fontScale: 1.0) == 26)
    }

    @Test("跟唱高亮行半高：22/19 档")
    func karaokeRows() {
        #expect(LyricsCenterMetrics.rowHalfHeight(emphasis: 1.0, karaoke: true, fontScale: 1.0) == 31.5)
        #expect(LyricsCenterMetrics.rowHalfHeight(emphasis: 0.66, karaoke: true, fontScale: 1.0) == 29.5)
    }

    @Test("fontScale 1.33 高亮行半高")
    func scaledRows() {
        // 26 × 1.33 = 34.58 → ceil(41.496) = 42；(42 + 48)/2 = 45
        #expect(LyricsCenterMetrics.rowHalfHeight(emphasis: 1.0, karaoke: false, fontScale: 1.33) == 45)
    }
}

struct LyricsCenterMetricsTopInsetTests {
    @Test("常规视口：视口一半 - 行半高")
    func regularViewport() {
        #expect(LyricsCenterMetrics.topInset(viewportHeight: 400, rowHalfHeight: 40) == 160)
        #expect(LyricsCenterMetrics.topInset(viewportHeight: 300, rowHalfHeight: 31.5) == 118.5)
    }

    @Test("小视口 / 刚好装下高亮行：归零")
    func tinyViewport() {
        #expect(LyricsCenterMetrics.topInset(viewportHeight: 80, rowHalfHeight: 40) == 0)
        #expect(LyricsCenterMetrics.topInset(viewportHeight: 60, rowHalfHeight: 40) == 0)
    }
}
