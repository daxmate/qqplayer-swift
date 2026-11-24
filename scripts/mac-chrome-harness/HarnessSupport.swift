//
//  HarnessSupport.swift — macOS 窗口 chrome / 工具栏玻璃 harness 夹具（**不参与 App target 编译**）
//
//  与 `scripts/sync-harness/HarnessSupport.swift` 同风格：只放夹具与断言助手，
//  生产逻辑一律来自 `QQPlayer/Mac/MacWindowGlass.swift` / `MacWindowGlassChrome.swift`，
//  本目录**绝不复制**生产实现（否则测的是副本，抓不到生产回归）。
//

import AppKit
import SwiftUI

// MARK: - 迷你断言（与 sync harness 同形）

var checks = 0
var failures: [String] = []

func section(_ title: String) {
    print("\n—— \(title)")
}

func check(_ condition: Bool, _ label: String, expected: String = "", actual: String = "") {
    checks += 1
    if condition {
        print("  ✅ \(label)")
        return
    }
    print("  ❌ \(label)")
    if !expected.isEmpty || !actual.isEmpty {
        print("      期望: \(expected)")
        print("      实际: \(actual)")
    }
    failures.append(label)
}

func checkClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat, _ label: String) {
    check(
        abs(actual - expected) <= tolerance,
        label,
        expected: "\(fmt(expected)) ±\(fmt(tolerance))",
        actual: fmt(actual)
    )
}

func fmt(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
}

// MARK: - 视图树工具

/// 深度优先收集 root 及其全部子视图。
func allViews(in root: NSView) -> [NSView] {
    var out: [NSView] = [root]
    for sub in root.subviews {
        out.append(contentsOf: allViews(in: sub))
    }
    return out
}

func classOf(_ view: NSView) -> String {
    String(describing: type(of: view))
}

/// 自身与全部祖先都没有 isHidden（= 真正参与绘制）。
func isVisibleInTree(_ view: NSView) -> Bool {
    var node: NSView? = view
    while let current = node {
        if current.isHidden { return false }
        node = current.superview
    }
    return true
}

/// 用超类名兜底匹配私有类（AppKit 私有类名随系统版本可能改，但都会带这些片段）。
func isGlassView(_ view: NSView) -> Bool {
    classOf(view).contains("GlassEffectView")
}

func isPlatterView(_ view: NSView) -> Bool {
    classOf(view).contains("Platter")
}

// MARK: - 夹具：与生产同构的窗口

/// 一个窗口 + 侧栏 split item + 工具栏（系统侧栏切换 item + 4 个业务按钮 item）
/// + 生产 `MacWindowGlassChrome.ChromeApplier` + 生产 `MacSidebarMaterialStripper.StripperView`。
///
/// 结构对齐生产：`MacLibraryView` 把 applier 作为内容区 background、把 stripper 作为侧栏
/// 内容 background；侧栏由 `NSSplitViewItem(sidebarWithViewController:)` 创建，macOS 26+
/// 系统会自己套一层 `NSGlassEffectView`（真机实测结构见任务档案）。
final class ChromeFixture {
    static let sidebarToggleIdentifier = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    static let businessWindowWidth: CGFloat = 900
    static let businessWindowHeight: CGFloat = 600
    static let sidebarMaxThickness: CGFloat = 320

    let window: NSWindow
    let split: NSSplitViewController
    let sidebarItem: NSSplitViewItem
    let sidebarCtl: NSViewController
    let toolbar: NSToolbar
    let businessItems: [NSToolbarItem]
    let applier: MacWindowGlassChrome.ChromeApplier
    private(set) var stripper: MacSidebarMaterialStripper.StripperView
    /// 侧栏列的**内容视图**（玻璃的 contentView，与生产 stripper 所在的同一层）。
    /// 生产里 stripper 是侧栏页面内容的 `.background`，两者同在玻璃内容里；
    /// 夹具必须把 stripper 挂在这一层，挂到 NSSplitViewController 的 VC 视图上会被
    /// AppKit 重新挂回 wrapper（脱离玻璃），第二次摘玻璃就会扑空。
    private(set) var pageView: NSView?

    private let toolbarDelegate: ChromeToolbarDelegate
    private(set) var baselinePlatterCount = 0
    /// 玻璃开时记录的 4 个业务按钮 frame（窗口坐标系），供恢复态比对。
    private(set) var glassOnButtonFrames: [NSRect] = []

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.businessWindowWidth, height: Self.businessWindowHeight),
            // 与生产窗口同形：窗口本身就带 .fullSizeContentView（applier 只是确保它在），
            // 所以玻璃开/关不应造成工具栏垂直方向位移，业务按钮必须原地不动。
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "QQPlayer"
        window.isOpaque = true

        split = NSSplitViewController()
        sidebarCtl = NSViewController()
        sidebarCtl.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: Self.businessWindowHeight))
        let item = NSSplitViewItem(sidebarWithViewController: sidebarCtl)
        item.minimumThickness = 200
        item.maximumThickness = Self.sidebarMaxThickness
        item.canCollapse = false
        sidebarItem = item
        split.addSplitViewItem(item)

        let mainCtl = NSViewController()
        mainCtl.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: Self.businessWindowHeight))
        split.addSplitViewItem(NSSplitViewItem(viewController: mainCtl))
        window.contentViewController = split

        var identifiers: [NSToolbarItem.Identifier] = [NSToolbarItem.Identifier(Self.sidebarToggleIdentifier)]
        for index in 0 ..< 4 {
            identifiers.append(NSToolbarItem.Identifier("business\(index)"))
        }

        toolbarDelegate = ChromeToolbarDelegate(identifiers: identifiers)
        toolbar = NSToolbar(identifier: "qqplayer-mac-chrome-harness")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // 生产 applier / stripper 的实例（逻辑全部来自生产源码）
        applier = MacWindowGlassChrome.ChromeApplier()
        applier.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        window.contentView?.addSubview(applier)

        // 生产里 stripper 只在玻璃开时以 `.background` 形式存在（关时 SwiftUI 拆掉它），
        // 所以夹具也按「开=新建实例挂上去 / 关=restore 再移除」镜像，绝不长期挂同一个实例。
        stripper = MacSidebarMaterialStripper.StripperView()

        businessItems = toolbarDelegate.businessItems
    }

    // MARK: 生命周期

    func show() {
        window.setContentSize(NSSize(width: Self.businessWindowWidth, height: Self.businessWindowHeight))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        pump(0.6)
        baselinePlatterCount = platters().count
    }

    /// 工具栏里**当前真的在**的侧栏切换 item（AppKit 会在布局时自己补一个系统 item，
    /// 所以一律按 identifier 现查，不缓存夹具自己造的那个）。
    var liveToggleItem: NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier.rawValue == Self.sidebarToggleIdentifier }
    }

    /// 模拟「apply 时侧栏切换 item 还没进工具栏，之后才到」：先摘掉再插回。
    func removeSidebarToggleItem() {
        guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == Self.sidebarToggleIdentifier }) else { return }
        toolbar.removeItem(at: index)
        pump(0.15)
    }

    func reinsertSidebarToggleItem() {
        guard liveToggleItem == nil else {
            pump(0.7)
            return
        }
        toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(Self.sidebarToggleIdentifier), at: 0)
        pump(0.7)
    }

    // MARK: 玻璃开关（调用生产代码）

    func setGlassActive(_ active: Bool) {
        if active {
            applier.apply(active: true)
            pump(0.2)
            // 与生产 `.background { if isActive { MacSidebarMaterialStripper() } }` 同构：
            // 每次开玻璃都是**新实例**（挂上去即由 viewDidMoveToWindow 触发 strip()）。
            let host = sidebarPageView()
            let fresh = MacSidebarMaterialStripper.StripperView()
            fresh.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
            host.addSubview(fresh)
            stripper = fresh
            fresh.strip()
            pump(0.15)
            fresh.strip()
        } else {
            applier.apply(active: false)
            stripper.restore()
            stripper.removeFromSuperview()
            // restore 内部的 layoutSubtreeIfNeeded 会让仍挂着的 stripper 再走一次
            // layout()→strip()；生产由「移出 + dismantle」收尾，这里显式收尾到同一终态。
            stripper.restore()
        }
        pump(0.35)
    }

    /// 侧栏列内容视图：首次取玻璃的 contentView 并记住（摘/装玻璃都是搬同一个视图）。
    func sidebarPageView() -> NSView {
        if let existing = pageView, existing.superview != nil || existing === pageView {
            return existing
        }
        if let wrapper = sidebarWrapper(), let glass = allViews(in: wrapper).first(where: isGlassView) {
            let content = glass.subviews.first ?? glass
            pageView = content
            return content
        }
        pageView = sidebarCtl.view
        return sidebarCtl.view
    }

    // MARK: 测量

    private var themeRoot: NSView? {
        window.contentView?.superview ?? window.contentView
    }

    func platters() -> [NSView] {
        guard let root = themeRoot else { return [] }
        return allViews(in: root).filter(isPlatterView)
    }

    /// 侧栏列的 item wrapper（生产 stripper 摘玻璃时操作的同一层）。
    func sidebarWrapper() -> NSView? {
        var node: NSView? = sidebarCtl.view.superview
        while let current = node {
            if classOf(current) == "_NSSplitViewItemViewWrapper" { return current }
            node = current.superview
        }
        return nil
    }

    func sidebarGlassViews() -> [NSView] {
        guard let wrapper = sidebarWrapper() else { return [] }
        return allViews(in: wrapper).filter(isGlassView)
    }

    func visibleSidebarGlassCount() -> Int {
        sidebarGlassViews().filter(isVisibleInTree).count
    }

    func sidebarThickness() -> CGFloat {
        sidebarWrapper()?.frame.width ?? 0
    }

    func windowWidth() -> CGFloat {
        window.frame.width
    }

    /// 4 个业务按钮在窗口坐标系下的 frame（按工具栏顺序）。
    func businessButtonFrames() -> [NSRect] {
        businessItems.map { item in
            guard let view = item.view else { return .zero }
            return view.convert(view.bounds, to: nil)
        }
    }

    /// 工具栏标题字段（私有类 `_NSToolbarTitleField`）在窗口坐标系下的 x；缺失返回 nil。
    func toolbarTitleFieldX() -> CGFloat? {
        guard let root = themeRoot else { return nil }
        for view in allViews(in: root) where classOf(view) == "_NSToolbarTitleField" {
            return view.convert(view.bounds, to: nil).minX
        }
        return nil
    }

    /// 主题视窗子树里的约束总数（反复翻转不许增长）。
    func constraintCount() -> Int {
        guard let root = themeRoot else { return 0 }
        return allViews(in: root).reduce(0) { $0 + $1.constraints.count }
    }

    func recordGlassOnButtonFrames() {
        glassOnButtonFrames = businessButtonFrames()
    }
}


// MARK: - 工具栏 delegate（夹具）

final class ChromeToolbarDelegate: NSObject, NSToolbarDelegate {
    private let identifiers: [NSToolbarItem.Identifier]
    private var cache: [NSToolbarItem] = []
    let businessItems: [NSToolbarItem]

    init(identifiers: [NSToolbarItem.Identifier]) {
        self.identifiers = identifiers
        // 业务按钮：自定义 view item（对齐 SwiftUI `ToolbarItem { Button }` 的托管形态）
        businessItems = (0 ..< 4).map { index in
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("business\(index)"))
            let button = NSButton(title: "b\(index)", target: nil, action: nil)
            button.bezelStyle = .texturedRounded
            button.frame = NSRect(x: 0, y: 0, width: 32, height: 24)
            item.view = button
            item.label = "b\(index)"
            return item
        }
        super.init()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if let cached = cache.first(where: { $0.itemIdentifier == identifier }) { return cached }
        if identifier == NSToolbarItem.Identifier(ChromeFixture.sidebarToggleIdentifier) {
            // 侧栏切换 item：用 AppKit 自己的标准 item（系统真实形态，无自定义 view）。
            let toggle = NSToolbarItem(itemIdentifier: identifier)
            toggle.label = "侧栏"
            cache.append(toggle)
            return toggle
        }
        if let business = businessItems.first(where: { $0.itemIdentifier == identifier }) {
            cache.append(business)
            return business
        }
        return nil
    }
}

// MARK: - 跑圈

/// 转 RunLoop（生产里的工具栏重排走 `DispatchQueue.main.async`，必须让它有机会执行）。
func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    for window in NSApp.windows { window.layoutIfNeeded() }
}
