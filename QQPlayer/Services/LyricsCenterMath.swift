//
//  LyricsCenterMath.swift
//  QQPlayer
//
//  平台无关的纯几何（iOS 测试 target 可直接单测；macOS 歌词面板是唯一当前调用方）。
//
//  高亮歌词行垂直居中的**唯一几何口径**（纯函数，可单测）。
//
//  背景：macOS 歌词面板原来用 `ScrollViewProxy.scrollTo(anchor: .center)` + 首尾
//  `max(视口/2 - 40, 0)` 的魔数占位。两个问题都会让高亮行偏出中心：
//    1. `- 40` 是一个行高的一半，行高随字号/译文/强调内边距变化 → 首末行系统性偏移；
//    2. 行强调内边距变化会让内容高度在滚动动画期间改变，动画落点按旧高度算 → 漂移。
//
//  这里把「行中心 → 内容偏移」抽成纯函数：调用方把量到的行中心（内容坐标系）与视口/内容
//  高度传进来，得到 `NSScrollView` 需要的内容偏移（已按可滚动范围 clamp）。
//

import CoreGraphics

enum LyricsCenterMath {
    /// 让「行中心」对齐「视口中心」所需的内容偏移（从内容顶部量起，向下为正）。
    ///
    /// - Parameters:
    ///   - rowCenterY: 行中心在**内容坐标系**里的 Y（含首部占位）
    ///   - viewportHeight: 歌词可视区高度
    ///   - contentHeight: 滚动内容总高（含首尾占位）
    /// - Returns: `0 ... max(contentHeight - viewportHeight, 0)` 之间的偏移
    static func centeredOffset(
        rowCenterY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0, contentHeight > 0 else { return 0 }
        let maxOffset = max(contentHeight - viewportHeight, 0)
        guard maxOffset > 0 else { return 0 }
        let target = rowCenterY - viewportHeight / 2
        return min(max(target, 0), maxOffset)
    }
}
