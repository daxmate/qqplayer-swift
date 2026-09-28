//
//  MacTrackListView+LocateScroll.swift
//  QQPlayer
//
//  macOS 曲库列表「定位当前播放」的滚动落地（Mac 专属，2026-09-28）。
//
//  为什么是 AppKit 桥接（本包已核 macOS 27.0 SDK 的 SwiftUI.swiftinterface）：
//  需求 = 点「定位当前播放」后把当前行滚到可视区**垂直居中**。SwiftUI `Table` 没有公开的
//  「滚到某行」接口：
//    · `scrollPosition(id:anchor:)`（macOS 14+）是 `View` 上的通用扩展，Apple 文档只承诺
//      「a scroll view within this view」的滚动行为，**未对 `Table` 表态**（无先例、无法在
//      本地验证真机效果，而失败形态恰是「静默不滚」= 本 bug 本身）；
//    · `ScrollViewReader` / `ScrollViewProxy.scrollTo` 需要 `ScrollView` + `id` 结构，
//      `Table` 不是 `ScrollView`。
//  ⇒ 走 AppKit 桥接：沿视图树找到承载 Table 的 `NSTableView`，按共享层
//  `MacTableScrollGeometry.centeredOriginY` 算出目标 origin，再 `NSClipView.scroll(to:)`
//  + `reflectScrolledClipView`。几何口径的唯一事实源在 `MacTableScrollGeometry`。
//
//  ⚠️ 唯一入口：全仓「把 Table 某行滚到可视区垂直居中」只允许走本文件的
//  `MacTableScroll.centerRow`（有形状契约测试守：禁止别处直连 `enclosingScrollView` /
//  `scrollRowToVisible` / `.scroll(to:` / `reflectScrolledClipView`）。
//

import AppKit
import SwiftUI

/// 「把 Table 行滚动到可视区垂直居中」的唯一入口（Mac 专属）。
enum MacTableScroll {
    /// 把 `row` 行滚到可视区垂直居中。
    /// 找不到承载表 / 行号越界 / 无滚动容器 / 行高为 0 → **静默 no-op**（不崩、不刷日志）。
    @MainActor
    static func centerRow(_ row: Int, from view: NSView) {
        guard let tableView = hostingTableView(of: view) else { return }
        guard row >= 0, row < tableView.numberOfRows else { return }
        guard let scrollView = tableView.enclosingScrollView else { return }
        let clipView = scrollView.contentView

        let rowRect = tableView.rect(ofRow: row)
        guard rowRect.height > 0 else { return }

        let originY = MacTableScrollGeometry.centeredOriginY(
            rowMinY: rowRect.minY,
            rowHeight: rowRect.height,
            viewportHeight: clipView.bounds.height,
            contentHeight: tableView.bounds.height
        )
        clipView.scroll(NSPoint(x: clipView.bounds.origin.x, y: originY))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 找承载「本 representable 所衬的那张 Table」的 `NSTableView`。
    ///
    /// SwiftUI 没有公开途径把自定义视图塞进 `Table` 的 AppKit 子树，故 `.background` 挂上的
    /// representable 通常与 Table **同容器并列**（兄弟），而不是 Table 的子孙——单靠
    /// 「沿 superview 向上」不一定碰到 `NSTableView`。因此两步：
    ///   ① 向上找：若背景视图恰落在 Table 子树内，`NSTableView` 会是某个祖先 → 直接返回；
    ///   ② 逐层向上，取**第一个「子树里含与自身 frame 交叠的 `NSTableView`」的祖先**——
    ///      背景与 Table 同框，故交叠面积最大者即所衬的那张表（可避开侧栏等同一窗口里的
    ///      其它 `NSTableView`）。找不到任何交叠表 → 继续向上；到根仍没有 → nil。
    @MainActor
    private static func hostingTableView(of view: NSView) -> NSTableView? {
        // 背景视图在窗口坐标系里的矩形（窗口内各视图可互相换算，便于跨层级比交叠）
        let viewRect = view.convert(view.bounds, to: nil)
        var node: NSView? = view
        while let current = node {
            if let tableView = current as? NSTableView { return tableView }
            if let best = bestOverlappingTableView(in: current, viewRect: viewRect) { return best }
            node = current.superview
        }
        return nil
    }

    /// `node` 子树里与 `viewRect`（窗口坐标）交叠面积最大的 `NSTableView`；无交叠返回 nil。
    /// 用**滚动容器（可视区）**而不是整张文档视图算交叠：文档视图可能远高于视口。
    @MainActor
    private static func bestOverlappingTableView(in node: NSView, viewRect: NSRect) -> NSTableView? {
        var best: NSTableView?
        var bestArea: CGFloat = 0
        for tableView in tableViews(in: node) {
            let scrollView = tableView.enclosingScrollView ?? tableView
            let rect = scrollView.convert(scrollView.bounds, to: nil)
            let intersection = rect.intersection(viewRect)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = tableView
            }
        }
        return best
    }

    /// 子树里的全部 `NSTableView`（深度优先）。
    @MainActor
    private static func tableViews(in node: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        if let tableView = node as? NSTableView { result.append(tableView) }
        for subview in node.subviews {
            result.append(contentsOf: tableViews(in: subview))
        }
        return result
    }
}

/// 定位滚动信号桥：`request` 变化且 `row != nil` 时，把该行滚到可视区垂直居中。
/// 由 `MacTrackListView` 以 `.background(...)` + `allowsHitTesting(false)` 挂进视图树。
struct MacTableLocateScroller: NSViewRepresentable {
    /// 自增请求号（与 `MacTrackListView.locateRequestID` 同一信号）
    let request: Int
    /// 目标显示行序号（`nil` = 当前播放曲不在本列表 → 不滚）
    let row: Int?

    /// 初始 `lastRequest` 与当前 `request` 对齐 ⇒ 首次装配/出现时不无故滚动，
    /// 只有请求号**变化**（按钮点击）才滚。
    func makeCoordinator() -> Coordinator { Coordinator(lastRequest: request) }

    /// 轻量占位视图：只作为「沿视图树找宿主 Table」的起点，不绘制、不响应事件。
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let row else { return }
        // 只在请求号变化时滚动：否则 SwiftUI 每次常规重绘都会把用户手动滚动的位置拽回去
        guard context.coordinator.lastRequest != request else { return }
        context.coordinator.lastRequest = request
        // 下一主 actor 轮次：等「选中」落表、行高就绪后再滚
        Task { @MainActor in
            MacTableScroll.centerRow(row, from: nsView)
        }
    }

    final class Coordinator {
        var lastRequest: Int
        init(lastRequest: Int) { self.lastRequest = lastRequest }
    }
}
