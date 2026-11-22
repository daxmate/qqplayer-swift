//
//  LyricsCenterMetrics.swift
//  QQPlayer
//
//  歌词高亮行垂直居中：行高 / 占位 / 目标档位字号的**纯函数**（macOS `MacLyricsView` 与 iOS `LyricsView` 共用）。
//  背景（2026-11-22）：切句时字号与 padding 曾随 emphasis 逐帧插值，`scrollTo` 按旧布局算偏移 → 高亮行偏上；
//  现在字号 / padding 一律按**目标档位**直接取值（布局同帧落定），滚动在布局落定后执行并做一次幂等校正。
//

import CoreGraphics
import Foundation

enum LyricsCenterMetrics {
    /// 系统字体的行高近似（ascender - descender + leading ≈ 1.2em）。
    static let lineHeightRatio: CGFloat = 1.2
    /// 滚动后「布局已落定」的幂等校正延迟（秒）。
    static let settleCorrectionDelay: TimeInterval = 0.05
    /// 居中日志用的命名坐标空间。
    static let coordinateSpaceName = "lyrics"

    /// 高亮行字号（目标档位，非逐帧插值；× fontScale）：
    /// 普通 1.0 → 26 / 0.66 → 19 / 0.40 及更远 → 16；跟唱 1.0 → 22 / 其它 → 19。
    static func fontSize(emphasis: Double, karaoke: Bool, fontScale: CGFloat) -> CGFloat {
        let base: CGFloat
        if karaoke {
            base = emphasis >= 0.99 ? 22 : 19
        } else if emphasis >= 0.99 {
            base = 26
        } else if emphasis >= 0.66 {
            base = 19
        } else {
            base = 16
        }
        return base * fontScale
    }

    /// 阅读态（普通模式手动滚动后）字号 = 正常大小下一档（19），不随距离分级。
    static func fontSize(emphasis: Double, karaoke: Bool, reading: Bool, fontScale: CGFloat) -> CGFloat {
        reading ? 19 * fontScale : fontSize(emphasis: emphasis, karaoke: karaoke, fontScale: fontScale)
    }

    /// 行上下内边距（点，不乘 fontScale）：普通 1.0 → 24 / 0.66 及更远 → 16；跟唱 18。
    static func verticalPadding(emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 18 }
        return emphasis >= 0.66 ? 24 : 16
    }

    /// 单行文本行高（近似）。
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        (fontSize * lineHeightRatio).rounded(.up)
    }

    /// 高亮行半高 = (行高 + 2×padding)/2，取当前档位。
    static func rowHalfHeight(emphasis: Double, karaoke: Bool, fontScale: CGFloat) -> CGFloat {
        let font = fontSize(emphasis: emphasis, karaoke: karaoke, fontScale: fontScale)
        let padding = verticalPadding(emphasis: emphasis, karaoke: karaoke)
        return (lineHeight(fontSize: font) + 2 * padding) / 2
    }

    /// 顶部 / 底部占位：视口一半减去高亮行半高，小视口归零。
    static func topInset(viewportHeight: CGFloat, rowHalfHeight: CGFloat) -> CGFloat {
        max(viewportHeight / 2 - rowHalfHeight, 0)
    }
}

/// 验收用居中日志（`[lyrics.center]` 一行；确认后删除）。连续几何变化时只保留最后一次。
/// 说明：本文件被多个 target 共享，故不直接依赖 `AppLog`，由调用方传入落日志闭包。
final class LyricsCenterLogger: @unchecked Sendable {
    static let shared = LyricsCenterLogger()

    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    /// View 层入口：避免 View / Mac 目录直接出现 `.shared`（结构性预算基线不动）。
    static func log(
        platform: String,
        rowMidY: CGFloat,
        viewportHeight: CGFloat,
        emit: @escaping @Sendable (String) -> Void
    ) {
        shared.schedule(
            platform: platform,
            rowMidY: rowMidY,
            viewportHeight: viewportHeight,
            log: emit
        )
    }

    func schedule(
        platform: String,
        rowMidY: CGFloat,
        viewportHeight: CGFloat,
        delay: TimeInterval = 0.3,
        log: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        pending?.cancel()
        let work = DispatchWorkItem {
            let center = viewportHeight / 2
            log(String(
                format: "[lyrics.center] platform=%@ rowMidY=%.1f viewCenterY=%.1f delta=%.1f",
                platform, rowMidY, center, rowMidY - center
            ))
        }
        pending = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
