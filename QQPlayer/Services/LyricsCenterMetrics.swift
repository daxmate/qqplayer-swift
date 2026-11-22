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
    /// 一次居中采样（诊断日志用；rowHeight 必须是实测值）。
    struct Sample: Sendable {
        var rowHeight: CGFloat
        var rowMidY: CGFloat
        var viewportHeight: CGFloat
        var inset: CGFloat
    }

    /// 高亮行居中的最新实测偏移（引用类型：几何回调写、滚动回调读）。
    final class Probe: @unchecked Sendable {
        /// 高亮行中心 − 视口中心（pt）；尚未测得时为 nil。
        var delta: CGFloat?
        /// 高亮行实测 frame 高度（含 padding / 译文 / 罗马音）；尚未测得时为 nil。
        var rowHeight: CGFloat?
        init() {}
    }

    /// 系统字体的行高近似（ascender - descender + leading ≈ 1.2em）。
    static let lineHeightRatio: CGFloat = 1.2
    /// 滚动后「布局已落定」的幂等校正延迟（秒）。
    static let settleCorrectionDelay: TimeInterval = 0.05
    /// 动画落定后重锚的补滚时机（秒）与容差（pt）：字号 / padding 逐帧插值使行高在动画中变化，
    /// 首次 scrollTo 按当时布局算偏移 → 落定后可能仍偏一点。只在 |delta| > 容差时补滚。
    static let settleReanchorDelays: [TimeInterval] = [0.45, 0.90]
    static let settleReanchorTolerance: CGFloat = 0.5
    /// 居中日志用的命名坐标空间。
    static let coordinateSpaceName = "lyrics"

    /// 高亮行字号（× fontScale）：分段线性插值（节点 = 改前的静态档位值）。
    /// 普通 1.0 → 26 / 0.66 → 19 / 0.40 及更远 → 16；跟唱 1.0 → 22 / 0.66 及更远 → 19。
    /// ⚠️ 逐帧插值是视觉要求（高亮行平滑放大 / 缩小），居中靠滚动时机 + 落定后重锚。
    static func fontSize(emphasis: Double, karaoke: Bool, fontScale: CGFloat) -> CGFloat {
        let base = karaoke
            ? lerp(emphasis, [(1.0, 22), (0.66, 19)])
            : lerp(emphasis, [(1.0, 26), (0.66, 19), (0.40, 16)])
        return CGFloat(base) * fontScale
    }

    /// 阅读态（普通模式手动滚动后）字号 = 正常大小下一档（19），不随距离分级。
    static func fontSize(emphasis: Double, karaoke: Bool, reading: Bool, fontScale: CGFloat) -> CGFloat {
        reading ? 19 * fontScale : fontSize(emphasis: emphasis, karaoke: karaoke, fontScale: fontScale)
    }

    /// 行上下内边距（点，不乘 fontScale）：普通分段线性插值 1.0 → 24 / 0.66 及更远 → 16；跟唱 18。
    static func verticalPadding(emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 18 }
        return CGFloat(lerp(emphasis, [(1.0, 24), (0.66, 16)]))
    }

    /// 分段线性插值：节点按 emphasis 降序给出，超出两端取端值（与 `MacLyricsView+Emphasis` 同口径）。
    static func lerp(_ value: Double, _ nodes: [(Double, Double)]) -> Double {
        guard let first = nodes.first, let last = nodes.last else { return value }
        if value >= first.0 { return first.1 }
        if value <= last.0 { return last.1 }
        for index in 1 ..< nodes.count {
            let upper = nodes[index - 1]
            let lower = nodes[index]
            guard value >= lower.0 else { continue }
            let span = upper.0 - lower.0
            guard span > 0 else { return upper.1 }
            let fraction = (value - lower.0) / span
            return lower.1 + (upper.1 - lower.1) * fraction
        }
        return last.1
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
    /// 本轮首个采样时间（防抖硬上限用）。
    private var pendingSince: Date?

    /// View 层入口：避免 View / Mac 目录直接出现 `.shared`（结构性预算基线不动）。
    /// 防抖上限：连续几何变化（动画逐帧 / 滚动）不得让日志永远发不出去。
    static let maximumDebounce: TimeInterval = 1.0

    static func log(
        platform: String,
        mode: String,
        sample: LyricsCenterMetrics.Sample,
        emit: @escaping @Sendable (String) -> Void
    ) {
        shared.schedule(platform: platform, mode: mode, sample: sample, log: emit)
    }

    func schedule(
        platform: String,
        mode: String,
        sample: LyricsCenterMetrics.Sample,
        delay: TimeInterval = 0.3,
        log: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        pending?.cancel()
        let now = Date()
        if pendingSince == nil { pendingSince = now }
        let elapsed = now.timeIntervalSince(pendingSince ?? now)
        // 防抖但设硬上限：动画逐帧改 midY 时旧的「只保留最后一次」会永远推迟
        let wait = max(0, min(delay, Self.maximumDebounce - elapsed))
        let work = DispatchWorkItem { [weak self] in
            let center = sample.viewportHeight / 2
            log(String(
                format: "[lyrics.center] platform=%@ mode=%@ rowH=%.1f viewportH=%.1f rowMidY=%.1f viewCenterY=%.1f delta=%.1f inset=%.1f",
                platform, mode, sample.rowHeight, sample.viewportHeight, sample.rowMidY, center, sample.rowMidY - center, sample.inset
            ))
            self?.lock.lock()
            self?.pendingSince = nil
            self?.lock.unlock()
        }
        pending = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }
}
