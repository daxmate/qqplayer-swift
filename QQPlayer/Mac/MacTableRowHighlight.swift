//
//  MacTableRowHighlight.swift
//  QQPlayer
//
//  当前播放行的**整行**底色（Mac 专属，2026-11-17）。
//
//  为什么走 AppKit 桥接：SwiftUI `Table` 没有「整行背景」API，过去只能在每个单元格上
//  各铺一块 `.background`，NSTableView 的列间距把它切成几段（真机截图：列间白缝、行首
//  行尾不齐）。真正横贯整行的是 `NSTableRowView`：这里零尺寸挂进单元格，沿 superview
//  链向上找到它，再设 `backgroundColor`，由行视图自己画一遍连续底色。
//
//  降级口径：找不到 `NSTableRowView` 时**静默不动** —— 结果是「没有底色」（序号列喇叭
//  图标 + 标题 accent 字色仍在），绝不留半截底色。选中态交给系统画，不在这里覆盖。
//

import AppKit
import SwiftUI

/// 挂进单元格的零尺寸探针：把整行底色写到所在 `NSTableRowView` 上。
struct MacTableRowHighlight: NSViewRepresentable {
    /// 本行是否为当前播放行
    let isActive: Bool
    /// 已按当前强调色算好的底色（含透明度）；深色模式由调用方的 appAccentColor 跟随
    let tint: Color

    func makeNSView(context: Context) -> MacTableRowHighlightProbe {
        let probe = MacTableRowHighlightProbe()
        probe.highlight(isActive: isActive, tint: NSColor(tint))
        return probe
    }

    func updateNSView(_ nsView: MacTableRowHighlightProbe, context: Context) {
        // 行复用：每次更新都按当前 isActive 重设，滚动后不会残留上一行的颜色
        nsView.highlight(isActive: isActive, tint: NSColor(tint))
    }

    static func dismantleNSView(_ nsView: MacTableRowHighlightProbe, coordinator: ()) {
        nsView.reset()
    }
}

/// 只写行背景、不画任何东西的探针视图。
final class MacTableRowHighlightProbe: NSView {
    /// 当前所在的行视图（superview 链向上找到的第一个）
    private var rowView: NSTableRowView?
    /// 选中态变化要立刻恢复/撤销底色，否则系统选中与自定义底色会打架
    private var selectionObservation: NSKeyValueObservation?
    private var isActive = false
    private var tint: NSColor = .clear
    /// 行视图自己的底色（NSTableRowView.backgroundColor 非可选），撤销时原样还回去
    private var rowBaseColor: NSColor = .clear
    /// 首次挂载时层级可能还没搭好，只补一次延迟解析，避免反复调度
    private var hasScheduledResolve = false

    /// 纯背景探针：不能参与命中测试，否则会挡住单元格的点击与悬停。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            reset()
            return
        }
        resolveRowViewIfNeeded()
        refreshBackground()
        scheduleResolveIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else {
            // 被移出层级（行复用/滚动回收）：清掉旧行的底色，等重新挂载再算
            reset()
            return
        }
        resolveRowViewIfNeeded()
        refreshBackground()
        scheduleResolveIfNeeded()
    }

    /// SwiftUI 每次求值都会调到这里：更新意图并同步到行视图。
    func highlight(isActive: Bool, tint: NSColor) {
        self.isActive = isActive
        self.tint = tint
        resolveRowViewIfNeeded()
        refreshBackground()
        scheduleResolveIfNeeded()
    }

    /// 放弃对行背景的所有权（卸载/复用前调用），把行视图恢复成系统默认。
    func reset() {
        selectionObservation = nil
        rowView?.backgroundColor = rowBaseColor
        rowView = nil
    }

    /// 沿 superview 链向上找本行；找不到就保持现状（降级为没有底色，绝不半截铺色）。
    private func resolveRowViewIfNeeded() {
        var candidate = superview
        while let view = candidate {
            if let row = view as? NSTableRowView {
                adopt(row)
                return
            }
            candidate = view.superview
        }
    }

    private func adopt(_ row: NSTableRowView) {
        guard row !== rowView else { return }
        rowView?.backgroundColor = rowBaseColor
        selectionObservation = nil
        rowBaseColor = row.backgroundColor
        rowView = row
        selectionObservation = row.observe(\.isSelected, options: [.new]) { [weak self] _, _ in
            // isSelected 只由主线程改（NSTableView 选中），按主 actor 续上
            MainActor.assumeIsolated {
                self?.refreshBackground()
            }
        }
    }

    private func refreshBackground() {
        guard let rowView else { return }
        // 选中态由 AppKit 画（含非活跃窗口的灰色选中），这里不参与，只负责普通行
        let shouldTint = isActive && !rowView.isSelected
        rowView.backgroundColor = shouldTint ? tint : rowBaseColor
    }

    private func scheduleResolveIfNeeded() {
        guard rowView == nil, !hasScheduledResolve else { return }
        hasScheduledResolve = true
        Task { @MainActor in
            self.hasScheduledResolve = false
            self.resolveRowViewIfNeeded()
            self.refreshBackground()
        }
    }
}
