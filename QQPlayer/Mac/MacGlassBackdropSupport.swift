//
//  MacGlassBackdropSupport.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  主窗玻璃模式的「背板剥离」支撑件（2026-11-25 拆出 MacWindowGlass.swift，控结构预算）：
//    - 判据（材质族 / 深度 / 祖先 / 已隐藏）→ 纯逻辑，harness 可直编断言；
//    - 视图树里的表格滚动容器查找；
//    - 属性接管记录器（原值还原）；
//    - 中栏曲目列表的滚动背板剥离器。
//
//  ⚠️ 本文件不画任何东西，只读 / 改 AppKit 背板属性。
//

import AppKit
import SwiftUI

// MARK: - 背板剥离判据（纯逻辑，harness 直编断言）

/// 主窗玻璃模式下要剥掉的系统背板材质族。
///
/// 用自有枚举而不是直接拿 `NSVisualEffectView.Material`：判据要能在
/// `scripts/mac-chrome-harness`（swiftc 直编生产源码、无 App target）里真跑断言。
enum MacGlassBackdropMaterial: String, CaseIterable, Equatable {
    case sidebar
    case underWindowBackground
    case headerView
}

/// 一次「这层背板要不要剥」的判定；失败分支同时就是日志口径。
enum MacGlassStripDecision: Equatable {
    case strip
    /// 材质不属于背板族（搜索框 / 行内小材质等）
    case skipNotBackdropMaterial
    /// 候选正好是探针的祖先：隐藏它会连侧栏内容一起抹掉
    case skipAncestorOfProbe
    /// 超出祖先链上探预算
    case skipTooDeep
    /// 已经是隐藏态：无需重复写入
    case skipAlreadyHidden

    var logCode: String {
        switch self {
        case .strip: return "strip"
        case .skipNotBackdropMaterial: return "not-backdrop"
        case .skipAncestorOfProbe: return "ancestor"
        case .skipTooDeep: return "too-deep"
        case .skipAlreadyHidden: return "already-hidden"
        }
    }
}

enum MacGlassBackdropPolicy {
    /// 祖先链最大上探层数。macOS 15 实测侧栏背板挂在第 10 层以外（原实现死线 10 层会漏），
    /// 放宽到 16：仍然有界，同时覆盖 `NSSplitViewItem` 的托管层级。
    static let maxAncestorDepth = 16

    /// 判定顺序：材质族 → 深度 → 祖先 → 是否已隐藏。
    /// 「已经隐藏」也走判定（而不是提前 return），是为了让每次 `strip()` 都能复查：
    /// 系统把同一个背板重新显示出来时，下一轮布局要能再隐藏（macOS 15 的一次性剥离修复点）。
    static func decision(
        material: MacGlassBackdropMaterial?,
        depth: Int,
        isAncestorOfProbe: Bool,
        alreadyHidden: Bool
    ) -> MacGlassStripDecision {
        guard material != nil else { return .skipNotBackdropMaterial }
        guard depth >= 0, depth < maxAncestorDepth else { return .skipTooDeep }
        guard !isAncestorOfProbe else { return .skipAncestorOfProbe }
        guard !alreadyHidden else { return .skipAlreadyHidden }
        return .strip
    }
}

extension NSVisualEffectView.Material {
    /// 归一到「背板族」；nil = 该材质不参与剥离（搜索框 / 行内小材质等）。
    var macGlassBackdropFamily: MacGlassBackdropMaterial? {
        switch self {
        case .sidebar: return .sidebar
        case .underWindowBackground: return .underWindowBackground
        case .headerView: return .headerView
        default: return nil
        }
    }
}

/// 在视图树里找「承载表格的滚动容器」（侧栏 List / 中栏 Table 都是 NSTableView 内核）。
enum MacGlassBackdropSearch {
    /// 从探针向上找最近的、子树里含表格滚动容器的祖先。
    /// 只上探 `maxAncestorDepth` 层、每个祖先子树只下探 `maxSubtreeDepth` 层，
    /// 保证在最外层容器上也不会把别栏的表格认成自己。
    static func tableScrollView(
        above probe: NSView,
        maxAncestorDepth: Int = MacGlassBackdropPolicy.maxAncestorDepth,
        maxSubtreeDepth: Int = 6
    ) -> NSScrollView? {
        var node = probe.superview
        var depth = 0
        while let view = node, depth < maxAncestorDepth {
            if let found = firstTableScrollView(in: view, depthLeft: maxSubtreeDepth) { return found }
            node = view.superview
            depth += 1
        }
        return nil
    }

    private static func firstTableScrollView(in view: NSView, depthLeft: Int) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
        // 表格行不承载背板，也不再往下走（与设置窗剥离器同口径）
        guard depthLeft > 0, !(view is NSTableView) else { return nil }
        for subview in view.subviews {
            if let found = firstTableScrollView(in: subview, depthLeft: depthLeft - 1) { return found }
        }
        return nil
    }
}

/// 记录「玻璃模式下被改过的 AppKit 属性」，关玻璃 / 视图拆除时逐项还原。
///
/// 设置窗那套兜底（NSTableView.backgroundColor = .clear、NSScrollView / NSClipView
/// drawsBackground = false、隐藏同族 NSVisualEffectView）现在主窗侧栏与中栏列表都要用，
/// 所以只在这里记一次**原值**：重复调用只重放，不把「改过的值」当原值（否则还原不回去）。
final class MacGlassBackdropAdjustments {
    private final class Entry {
        weak var view: NSView?
        let kind: Kind
        var originalHidden = false
        var originalDrawsBackground = false
        var originalTableBackground: NSColor?

        init(view: NSView, kind: Kind) {
            self.view = view
            self.kind = kind
        }

        /// 重放时**只在值不同时写**：每次写属性都会让 AppKit 标脏布局，
        /// 无脑重写会和 `layout()` 里的重放形成自激循环。
        func reapply() {
            switch kind {
            case .visualEffectHidden:
                if let effect = view as? NSVisualEffectView, !effect.isHidden {
                    effect.isHidden = true
                }
            case .scrollViewBackground:
                if let scrollView = view as? NSScrollView, scrollView.drawsBackground {
                    scrollView.drawsBackground = false
                }
            case .clipViewBackground:
                if let clipView = view as? NSClipView, clipView.drawsBackground {
                    clipView.drawsBackground = false
                }
            case .tableViewBackground:
                if let tableView = view as? NSTableView, tableView.backgroundColor != .clear {
                    tableView.backgroundColor = .clear
                }
            }
        }
    }

    private enum Kind {
        case visualEffectHidden
        case scrollViewBackground
        case clipViewBackground
        case tableViewBackground
    }

    /// 扫描深度上限：超过 8 层基本是布局容器，没有继续下探的价值。
    private static let scanDepthLimit = 8

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []

    /// 已接管的视图数（日志口径）
    var count: Int { entries.count }

    /// 从 `root` 起逐层接管背板属性（幂等）。
    func apply(in root: NSView) {
        applyRecursively(root, depth: 0)
    }

    /// 还原所有记录过的属性；无记录时是 no-op（关闭玻璃的用户没有任何额外开销）。
    func revert() {
        for id in order {
            guard let entry = entries[id] else { continue }
            guard let view = entry.view else { continue }
            switch entry.kind {
            case .visualEffectHidden:
                view.isHidden = entry.originalHidden
            case .scrollViewBackground:
                (view as? NSScrollView)?.drawsBackground = entry.originalDrawsBackground
            case .clipViewBackground:
                (view as? NSClipView)?.drawsBackground = entry.originalDrawsBackground
            case .tableViewBackground:
                (view as? NSTableView)?.backgroundColor = entry.originalTableBackground ?? .clear
            }
        }
        entries.removeAll()
        order.removeAll()
    }

    private func applyRecursively(_ view: NSView, depth: Int) {
        adjust(view)
        guard !(view is NSTableView), depth < Self.scanDepthLimit else { return }
        for subview in view.subviews {
            applyRecursively(subview, depth: depth + 1)
        }
    }

    private func adjust(_ view: NSView) {
        let id = ObjectIdentifier(view)
        if let existing = entries[id], existing.view === view {
            existing.reapply()
            return
        }
        if let effect = view as? NSVisualEffectView {
            guard effect.material.macGlassBackdropFamily != nil else { return }
            let entry = Entry(view: effect, kind: .visualEffectHidden)
            entry.originalHidden = effect.isHidden
            store(entry)
            entry.reapply()
            return
        }
        if let scrollView = view as? NSScrollView {
            let entry = Entry(view: scrollView, kind: .scrollViewBackground)
            entry.originalDrawsBackground = scrollView.drawsBackground
            store(entry)
            entry.reapply()
            return
        }
        if let clipView = view as? NSClipView {
            let entry = Entry(view: clipView, kind: .clipViewBackground)
            entry.originalDrawsBackground = clipView.drawsBackground
            store(entry)
            entry.reapply()
            return
        }
        if let tableView = view as? NSTableView {
            let entry = Entry(view: tableView, kind: .tableViewBackground)
            entry.originalTableBackground = tableView.backgroundColor
            store(entry)
            entry.reapply()
        }
    }

    private func store(_ entry: Entry) {
        guard let view = entry.view else { return }
        let id = ObjectIdentifier(view)
        entries[id] = entry
        order.append(id)
    }
}

/// 中栏曲目列表的滚动背板剥离器（玻璃生效时挂在 Table 上）。
///
/// 白底来源不是 Table 内容（`.scrollContentBackground(.hidden)` 已清掉），
/// 而是滚动容器自己：`NSScrollView.drawsBackground` + `NSClipView.drawsBackground`
/// 在表格内容之外（含底部水平滚动条槽位）铺系统背景色。
/// 这里只改属性并记录原值，玻璃关闭 / 视图拆除时整组还原。
///
/// **为什么不改 `NSScroller` 的 knobStyle / scrollerStyle**：白底来自滚动容器自己的
/// `drawsBackground`，关掉后滚动条槽位直接继承窗底玻璃；强行改成 `.overlay` 会覆盖
/// 用户「始终显示滚动条」的系统偏好（macOS 15 那台机器正是常显滚动条），属于越权改观感。
/// 因此只关背景，不碰滚动条样式。
struct MacGlassTableBackdropStripper: NSViewRepresentable {
    /// 玻璃是否生效（唯一入口：`macWindowGlassActive` 环境值；调用点不用重复传参）
    @Environment(\.macWindowGlassActive) private var isWindowGlassActive

    func makeNSView(context: Context) -> BackdropView {
        BackdropView()
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.apply(active: isWindowGlassActive)
    }

    static func dismantleNSView(_ view: BackdropView, coordinator: ()) {
        view.restore()
    }

    /// 只改背板属性、不画任何东西的宿主视图。
    final class BackdropView: NSView {
        private let adjustments = MacGlassBackdropAdjustments()
        private var active = false
        /// 日志节流：同一种结果只记一条（layout 每帧都会重放）
        private var lastLogCode: String?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(active: Bool) {
            self.active = active
            if active {
                reapply()
            } else {
                restore()
            }
        }

        func restore() {
            adjustments.revert()
            lastLogCode = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                restore()
            } else {
                reapply()
            }
        }

        override func layout() {
            super.layout()
            // 视图重建 / 列宽变化后重放（幂等：只补写，不重记原值）
            reapply()
        }

        private func reapply() {
            guard active, window != nil else { return }
            guard let scrollView = MacGlassBackdropSearch.tableScrollView(above: self) else {
                logOnce("result=miss")
                return
            }
            adjustments.apply(in: scrollView)
            logOnce("result=hit views=\(adjustments.count)")
        }

        private func logOnce(_ detail: String) {
            guard lastLogCode != detail else { return }
            lastLogCode = detail
            AppLog.info(.ui, "[glass] table.background \(detail)")
        }
    }
}
