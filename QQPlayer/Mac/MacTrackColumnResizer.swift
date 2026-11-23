//
//  MacTrackColumnResizer.swift
//  QQPlayer
//
//  无表头曲目列表的「拖拽改列宽」热区（Mac 专属，2026-11-23）。
//
//  背景：列表用 `.tableColumnHeaders(.hidden)` 隐藏表头后，原生列宽拖拽随之失效
//  （列宽拖拽是 NSTableHeaderView 的功能，内容区不管）。方案 b：表头继续保持隐藏，
//  另加一层**全透明**的 AppKit 热区覆盖层——只在列边界 ±4pt 内接管鼠标（其余区域
//  hitTest 返回 nil，直接穿透给 Table：单击选中 / 双击播放 / 右键菜单 / 悬停 ♥ 都不受影响），
//  靠近边界显示左右缩放光标，按住拖动实时改相邻两根弹性列的宽度。
//
//  单一真相源：`MacTrackColumnWidths`（MacTrackListView 的 @State）→ 直接喂给
//  TableColumn 的 `.width(min:ideal:max:)`。拖动结束只写这一处；SwiftUI 重算视图时
//  重新应用的也是同一组数值，因此不会把用户拖出来的宽度改回旧值。拖动过程中同时把
//  **同一次计算**得出的宽度写进 `NSTableColumn.width`（零帧延迟、跟手），两条渲染路径
//  喂的是同一个数，不存在两份互相打架的状态。
//
//  边界对齐：边界 x 不靠「累加列宽」推算，而是读 NSTableView 自己的列几何
//  `rect(ofColumn:)`（相邻两列之间的间隙中点）再 convert 到本视图坐标——与 AppKit
//  实际布局同源，intercellSpacing 变了也不会错位；窗口缩放/横向滚动后同样实时读取。
//

import AppKit
import SwiftUI

/// 三根弹性列的宽度（**单一真相源**，语义见文件头）。
struct MacTrackColumnWidths: Equatable {
    var title = MacTrackColumnLayout.titleInitialWidth
    var artist = MacTrackColumnLayout.artistInitialWidth
    var album = MacTrackColumnLayout.albumInitialWidth
}

/// 列布局口径：列序 / 最小宽度 / 可拖边界。列序与 TableColumn 声明顺序一致。
enum MacTrackColumnLayout {
    // 列序：0 封面(固定) / 1 标题 / 2 艺人 / 3 专辑 / 4 时长(固定) / 5 ♥(固定)
    static let titleIndex = 1
    static let artistIndex = 2
    static let albumIndex = 3
    static let minimumColumnCount = 6

    static let titleInitialWidth: CGFloat = 300
    static let artistInitialWidth: CGFloat = 140
    static let albumInitialWidth: CGFloat = 180

    static let titleMinWidth: CGFloat = 120
    static let artistMinWidth: CGFloat = 60
    static let albumMinWidth: CGFloat = 60

    /// 热区半宽：边界 ±4pt
    static let boundaryHitHalfWidth: CGFloat = 4

    /// 一条可拖边界 = 相邻两列的列序
    struct Boundary {
        let left: Int
        let right: Int
    }

    /// 只接「两根都是弹性列」的边界：标题|艺人、艺人|专辑。
    /// 固定列（封面/时长/♥）的边界不接管——拖动它们没有合理语义。
    static let boundaries = [
        Boundary(left: titleIndex, right: artistIndex),
        Boundary(left: artistIndex, right: albumIndex),
    ]

    static func minWidth(ofColumn index: Int) -> CGFloat {
        switch index {
        case titleIndex: titleMinWidth
        case artistIndex: artistMinWidth
        case albumIndex: albumMinWidth
        default: 0
        }
    }
}

/// 以 `.overlay` 挂在 Table 上的透明热区。
struct MacTrackColumnResizer: NSViewRepresentable {
    /// 当前（被 SwiftUI 采用的）列宽；只在首次解析到 NSTableView 时铺开一次。
    var widths: MacTrackColumnWidths
    /// 拖动结束提交：写回 SwiftUI state（单一真相源）。
    var onCommit: (MacTrackColumnWidths) -> Void

    func makeNSView(context: Context) -> MacTrackColumnResizerView {
        let view = MacTrackColumnResizerView()
        view.apply(widths)
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ view: MacTrackColumnResizerView, context: Context) {
        view.apply(widths)
        view.onCommit = onCommit
    }
}

/// 透明热区视图：只有 `hitTest` 命中列边界时才参与事件，其余全部穿透。
final class MacTrackColumnResizerView: NSView {
    var onCommit: ((MacTrackColumnWidths) -> Void)?

    private weak var table: NSTableView?
    private var preferredWidths = MacTrackColumnWidths()
    private var appliedInitialWidths = false
    private var dragState: DragState?
    private var cursorTrackingAreas: [NSTrackingArea] = []
    private var lastHotZoneSignature: [CGFloat] = []
    private var resolveAttempts = 0
    private var hasScheduledResolve = false

    private struct DragState {
        let boundary: MacTrackColumnLayout.Boundary
        let startBoundaryX: CGFloat
        let startLeftWidth: CGFloat
        let startRightWidth: CGFloat
    }

    // MARK: - 生命周期

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // 只断引用：观察者统一在 deinit / 重新解析时按对象摘除（swiftlint 口径）
            table = nil
            return
        }
        _ = resolveTableIfNeeded()
        refreshCursorHotZones()
    }

    override func layout() {
        super.layout()
        guard resolveTableIfNeeded() != nil else { return }
        let signature = hotZoneSignature()
        guard signature != lastHotZoneSignature else { return }
        lastHotZoneSignature = signature
        refreshCursorHotZones()
    }

    /// 热区几何指纹：边界 x + 自身高度。变了才重建 cursor rect / tracking area。
    private func hotZoneSignature() -> [CGFloat] {
        let xs = MacTrackColumnLayout.boundaries.compactMap { boundaryX($0) }
        return xs + [bounds.width, bounds.height]
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingAreas()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 命中判定（穿透的关键）

    /// 点在哪里都返回 nil，只有列边界 ±4pt 返回 self —— 鼠标因此只会在这几处被截住，
    /// 其它位置照常落到下面的 NSTableView（选中/双击/右键/悬停全靠它）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return boundary(near: local) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // MARK: - 光标

    override func resetCursorRects() {
        super.resetCursorRects()
        guard table != nil else { return }
        for boundary in MacTrackColumnLayout.boundaries {
            guard let rect = boundaryRect(boundary) else { continue }
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    /// 光标路径二（cursor rect 的兜底）：按边界分块登记 tracking area，
    /// 进入边界块给缩放光标，进入其余区域给默认箭头——两者都在，任一路径失效仍有光标。
    override func cursorUpdate(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if boundary(near: local) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func refreshCursorHotZones() {
        window?.invalidateCursorRects(for: self)
        refreshTrackingAreas()
    }

    private func refreshTrackingAreas() {
        cursorTrackingAreas.forEach { removeTrackingArea($0) }
        cursorTrackingAreas.removeAll()
        guard table != nil, bounds.width > 0, bounds.height > 0 else { return }
        let options: NSTrackingArea.Options = [.cursorUpdate, .activeInActiveApp]
        let background = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(background)
        cursorTrackingAreas.append(background)
        for boundary in MacTrackColumnLayout.boundaries {
            guard let rect = boundaryRect(boundary) else { continue }
            let area = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            cursorTrackingAreas.append(area)
        }
    }

    /// 边界热区矩形（本视图坐标）：±4pt 的竖条。
    private func boundaryRect(_ boundary: MacTrackColumnLayout.Boundary) -> NSRect? {
        guard let x = boundaryX(boundary) else { return nil }
        let half = MacTrackColumnLayout.boundaryHitHalfWidth
        return NSRect(x: x - half, y: 0, width: half * 2, height: bounds.height)
    }

    // MARK: - 拖拽

    override func mouseDown(with event: NSEvent) {
        guard let table,
              let (boundary, x) = boundary(near: convert(event.locationInWindow, from: nil)),
              table.numberOfColumns > boundary.right
        else { return }
        dragState = DragState(
            boundary: boundary,
            startBoundaryX: x,
            startLeftWidth: table.tableColumns[boundary.left].width,
            startRightWidth: table.tableColumns[boundary.right].width
        )
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragState, let table, table.numberOfColumns > dragState.boundary.right else { return }
        let currentX = convert(event.locationInWindow, from: nil).x
        let delta = clampedDelta(currentX - dragState.startBoundaryX, drag: dragState)
        table.tableColumns[dragState.boundary.left].width = dragState.startLeftWidth + delta
        table.tableColumns[dragState.boundary.right].width = dragState.startRightWidth - delta
        // 拖动中光标已是 resizeLeftRight，热区等 mouseUp 再重算（避免逐帧重建 tracking area）
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragState = nil
            refreshCursorHotZones()
        }
        guard dragState != nil, let table,
              table.numberOfColumns > MacTrackColumnLayout.albumIndex else { return }
        onCommit?(
            MacTrackColumnWidths(
                title: table.tableColumns[MacTrackColumnLayout.titleIndex].width,
                artist: table.tableColumns[MacTrackColumnLayout.artistIndex].width,
                album: table.tableColumns[MacTrackColumnLayout.albumIndex].width
            )
        )
    }

    /// 把鼠标位移钳到「两边都不低于最小宽度」的区间内。
    private func clampedDelta(_ delta: CGFloat, drag: DragState) -> CGFloat {
        let lower = MacTrackColumnLayout.minWidth(ofColumn: drag.boundary.left) - drag.startLeftWidth
        let upper = drag.startRightWidth - MacTrackColumnLayout.minWidth(ofColumn: drag.boundary.right)
        guard lower <= upper else { return lower }
        return min(max(delta, lower), upper)
    }

    // MARK: - 几何（与 NSTableView 实际列宽同源）

    /// 一条边界的 x（本视图坐标）：相邻两列之间的间隙中点。
    private func boundaryX(_ boundary: MacTrackColumnLayout.Boundary) -> CGFloat? {
        guard let table, table.numberOfColumns > boundary.right else { return nil }
        let leftRect = table.rect(ofColumn: boundary.left)
        let rightRect = table.rect(ofColumn: boundary.right)
        guard !leftRect.isEmpty, !rightRect.isEmpty else { return nil }
        let dividerX = (leftRect.maxX + rightRect.minX) / 2
        return convert(NSPoint(x: dividerX, y: bounds.midY), from: table).x
    }

    private func boundary(
        near point: NSPoint
    ) -> (MacTrackColumnLayout.Boundary, CGFloat)? {
        let half = MacTrackColumnLayout.boundaryHitHalfWidth
        var best: (MacTrackColumnLayout.Boundary, CGFloat)?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for boundary in MacTrackColumnLayout.boundaries {
            guard let x = boundaryX(boundary) else { continue }
            let distance = abs(point.x - x)
            guard distance <= half, distance < bestDistance else { continue }
            best = (boundary, x)
            bestDistance = distance
        }
        return best
    }

    // MARK: - 找所在 NSTableView

    @discardableResult
    private func resolveTableIfNeeded() -> NSTableView? {
        if let table, table.window === window, isUsable(table) { return table }
        guard let window, let root = window.contentView else { return nil }
        let myRect = convert(bounds, to: nil)

        var aligned: (table: NSTableView, area: CGFloat)?
        var fallback: (table: NSTableView, area: CGFloat)?
        func walk(_ view: NSView) {
            if let candidate = view as? NSTableView,
               candidate.numberOfColumns >= MacTrackColumnLayout.minimumColumnCount,
               !candidate.isHiddenOrHasHiddenAncestor {
                let rect = candidate.convert(candidate.bounds, to: nil)
                let inter = rect.intersection(myRect)
                let area = inter.isNull ? 0 : inter.width * inter.height
                if area > 0 {
                    if abs(rect.minX - myRect.minX) <= 2,
                       aligned == nil || area > aligned!.area {
                        aligned = (candidate, area)
                    }
                    if fallback == nil || area > fallback!.area {
                        fallback = (candidate, area)
                    }
                }
            }
            view.subviews.forEach(walk)
        }
        walk(root)

        guard let found = aligned?.table ?? fallback?.table else {
            scheduleResolveIfNeeded()
            return nil
        }
        table = found
        configureColumns(found)
        observeGeometry(of: found)
        return found
    }

    /// 已解析的 table 是否仍然可用（切列表模式后旧 table 可能被留在层级里但已隐藏）。
    private func isUsable(_ table: NSTableView) -> Bool {
        guard !table.isHiddenOrHasHiddenAncestor else { return false }
        let tableRect = table.convert(table.bounds, to: nil)
        let myRect = convert(bounds, to: nil)
        return tableRect.intersects(myRect)
    }

    /// 最小宽度交给 NSTableColumn 自己兜一层（拖动路径已在 `clampedDelta` 里钳过）。
    private func configureColumns(_ table: NSTableView) {
        guard table.numberOfColumns > MacTrackColumnLayout.albumIndex else { return }
        for index in [
            MacTrackColumnLayout.titleIndex,
            MacTrackColumnLayout.artistIndex,
            MacTrackColumnLayout.albumIndex,
        ] {
            table.tableColumns[index].minWidth = MacTrackColumnLayout.minWidth(ofColumn: index)
        }
        guard !appliedInitialWidths else { return }
        appliedInitialWidths = true
        table.tableColumns[MacTrackColumnLayout.titleIndex].width = preferredWidths.title
        table.tableColumns[MacTrackColumnLayout.artistIndex].width = preferredWidths.artist
        table.tableColumns[MacTrackColumnLayout.albumIndex].width = preferredWidths.album
    }

    /// 列宽变化 / 横向滚动 / 自身尺寸变化都重算光标热区，避免错位。
    private func observeGeometry(of table: NSTableView) {
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(
            self,
            selector: #selector(geometryDidChange),
            name: NSView.frameDidChangeNotification,
            object: table
        )
        center.addObserver(
            self,
            selector: #selector(geometryDidChange),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )
        if let clipView = table.enclosingScrollView?.contentView {
            center.addObserver(
                self,
                selector: #selector(geometryDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    @objc private func geometryDidChange() {
        refreshCursorHotZones()
    }

    private func scheduleResolveIfNeeded() {
        guard !hasScheduledResolve, window != nil,
              resolveAttempts < 20 else { return }
        hasScheduledResolve = true
        resolveAttempts += 1
        Task { @MainActor in
            self.hasScheduledResolve = false
            _ = self.resolveTableIfNeeded()
            self.refreshCursorHotZones()
        }
    }

    /// SwiftUI 侧最新列宽：只作为首次铺开与提交基线，不参与逐帧渲染。
    func apply(_ widths: MacTrackColumnWidths) {
        preferredWidths = widths
    }
}
