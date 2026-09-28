//
//  MacTableScrollGeometry.swift
//  QQPlayer
//
//  macOS 曲库列表「把某行滚到可视区垂直居中」的**纯几何计算唯一事实源**（2026-09-28）。
//
//  为什么放共享层 `QQPlayer/Services/` 而不是 `QQPlayer/Mac/`：滚动目标的几何计算是纯逻辑、
//  必须可单测，而 iOS 单测 target 编不到 `QQPlayer/Mac/**`（该目录在 iOS 例外表里）——
//  与 MacLibrarySelection / MacIndexingGate / MacFolderWatchPolicy 同款：纯决策上收共享层，
//  Mac 侧只消费。AppKit 侧的落地（找 NSTableView、调 scroll）在
//  `QQPlayer/Mac/MacTrackListView+LocateScroll.swift`（那边是滚动动作的唯一入口）。
//
//  全仓只此一处定义「居中目标 origin」的口径：别在视图/桥接里再手写一遍夹取公式。
//

import CoreGraphics

/// Table 行「垂直居中滚动」的目标位置计算（纯函数，无 AppKit 依赖）。
enum MacTableScrollGeometry {
    /// 让 `rowMinY + rowHeight/2` 落在视口垂直中点的目标滚动 `origin.y`，
    /// 并夹取到合法内容范围 `[0, max(0, contentHeight - viewportHeight)]`。
    ///
    /// - 内容短于视口（`contentHeight <= viewportHeight`）→ 上限为 0 → 恒返回 0（无滚动空间）；
    /// - 首行 / 末行 → 分别被夹到 `0` / `contentHeight - viewportHeight`；
    /// - 空内容（`contentHeight == 0`）→ 0。
    ///
    /// 坐标口径：`NSTableView` 是 flipped（y 向下递增），`rect(ofRow:)` 与
    /// `NSClipView.bounds.origin` 同向，故直接相减即可。
    static func centeredOriginY(
        rowMinY: CGFloat,
        rowHeight: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        let maxOrigin = max(0, contentHeight - viewportHeight)
        let desired = rowMinY + rowHeight / 2 - viewportHeight / 2
        return min(max(desired, 0), maxOrigin)
    }
}
