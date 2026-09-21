//
//  MacSearchAnythingLayer+WindowTricks.swift
//  QQPlayer
//
//  `MacSearchAnythingLayer` 的输入框定位与 Esc 本地监听（2026-09-21 从 `MacSearchAnythingLayer.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import AppKit
import SwiftUI

extension MacSearchAnythingLayer {
    // MARK: - 小工具

    /// 输入框 placeholder（唯一来源：输入框与 AppKit 兜底定位共用，避免兜底指错别的搜索框）
    /// 分片：跨文件可见（原 private）
    static let searchPlaceholder = "search_any_placeholder".localized

    /// 输入框稳定标识（AppKit 兜底定位的第一判据；比 placeholder 更不容易被改文案影响）
    /// 分片：跨文件可见（原 private）
    static let searchFieldIdentifier = "qqplayer.searchAnything.field"

    /// 焦点是否已经在文本输入上（编辑中的 field editor = NSTextView，或文本框本身）
    /// 分片：跨文件可见（原 private）
    static var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }

    /// AppKit 兜底：把浮层输入框设成第一响应者。
    /// 调用方先校验 `isTextInputFocused`——只有在 SwiftUI 的 `@FocusState` **没落地**时才走到这里，
    /// 所以不会出现两套焦点来源：决策仍在 `@FocusState`，本方法只执行「交权」这一动作。
    @MainActor
    /// 分片：跨文件可见（原 private）
    static func makeSearchFieldFirstResponder() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if let field = editableTextField(in: window.contentView) {
            return window.makeFirstResponder(field)
        }
        #if DEBUG
            // 定位失败时把窗口里的可编辑文本框全部打出来——真机一次跑就能看出判据哪里不对
            let candidates = editableFields(in: window.contentView).map {
                "id=\($0.accessibilityIdentifier()) placeholder=\($0.placeholderString ?? "-")"
            }
            AppLog.error(.ui, "[SearchAnything] 兜底定位失败，窗口内可编辑文本框：\(candidates)")
        #endif
        return false
    }

    /// 视图树里定位浮层输入框：先认稳定标识（可能挂在包装视图上），再认 placeholder 常量
    private static func editableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == searchFieldIdentifier {
            if let field = view as? NSTextField, field.isEditable { return field }
            if let nested = editableFields(in: view).first { return nested }
        }
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == searchPlaceholder {
            return field
        }
        for subview in view.subviews {
            if let found = editableTextField(in: subview) { return found }
        }
        return nil
    }

    /// 子树里全部可编辑文本框（仅定位失败时的取证打印用）
    private static func editableFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var result: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { result.append(field) }
        for subview in view.subviews {
            result.append(contentsOf: editableFields(in: subview))
        }
        return result
    }

    /// 诊断用（仅 Debug 打印）：当前 key window 的第一响应者是谁（组字中会标出来）。
    /// 用户报「打开面板打不了字 / Esc 收不起来」时，日志里这一行就是直接证据。
    /// 分片：跨文件可见（原 private）
    static func describeFirstResponder() -> String {
        guard let responder = NSApp.keyWindow?.firstResponder else { return "nil（无 key window）" }
        let marked = (responder as? NSTextView)?.hasMarkedText() ?? false
        return "\(type(of: responder))\(marked ? "（组字中）" : "")"
    }

// MARK: - Esc（唯一入口）

/// Esc 的**唯一处理点**：浮层可见期间的 AppKit 本地事件监听（keyCode 53）。
///
/// 为什么不用 `.onExitCommand`（本文件原来就挂在 panel 上）：它靠响应链把 `cancelOperation:`
/// 送达浮层。而面板弹出后第一响应者是输入框的 field editor（NSTextView），Esc 先被它按
/// 「取消编辑」语义吃掉，事件根本到不了浮层的 SwiftUI 响应链 → 用户实测「Esc 基本收不起来，
/// 点空白能收」（点空白走鼠标路径，不经键盘响应链）。
/// 为什么不用 `.onKeyPress(.escape)`：同属 SwiftUI 键盘事件路径，前置条件仍是焦点在浮层的
/// 焦点域内；焦点被输入框/输入法持有时事件到不了（同一个坑换了个写法）。
/// 本地监听装在 App 事件分发**之前**、与焦点无关：只要浮层在，Esc 一定先到我们手里。
///
/// 行为（用户 2026-09-18 拍板方案 a）：
///  - 输入法**组字中**（field editor `hasMarkedText()`）：**不拦截**，事件原样放给输入法——
///    第一次 Esc 只取消组字、浮层不关（macOS 习惯）；
///  - 其余情况：关浮层，且**只有真处理了才吞事件**（`nil`），否则原样 `return event`。
///
/// 生命周期：随浮层出现安装、消失立刻移除——否则浮层关了监听还在，会把别的界面的 Esc 一起吞掉。
/// 分片：跨文件可见（原 private）
struct SearchAnythingEscapeMonitor: ViewModifier {
    /// 关浮层动作（调用方唯一入口：`state.isOpen = false`）
    let onEscape: @MainActor () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    /// 安装（幂等：先移除再装，重复出现不会装出第二个）
    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 本地监听由主线程分发（AppKit 同一 @MainActor 域）→ 直接同步处理；
            // 不用 `MainActor.assumeIsolated`：NSEvent 非 Sendable，跨域捕获会触发警告
            Self.handle(event, onEscape: onEscape)
        }
    }

    /// 分片：跨文件可见（原 private）
    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// nil = 已处理（吞掉）；原样返回 = 放行
    @MainActor
    private static func handle(_ event: NSEvent, onEscape: @MainActor () -> Void) -> NSEvent? {
        guard event.keyCode == Self.escapeKeyCode else { return event }
        // 组字中：放给输入法（第一次 Esc 只取消组字，不关浮层）
        let composing = isComposingMarkedText
        #if DEBUG
            if AppLog.isEnabled(.debug, .ui) { AppLog.debug(.ui, "[SearchAnything] Esc：组字中=\(composing) → \(composing ? "放行给输入法" : "关浮层")") }
        #endif
        guard !composing else { return event }
        onEscape()
        return nil
    }

    /// Esc 的 keyCode（AppKit 与输入法都用 53）
    private static let escapeKeyCode: UInt16 = 53

    /// 是否正在输入法组字：编辑中的第一响应者是 field editor（NSTextView），
    /// 有未上屏的标记文本（拼音/假名候选）时 `hasMarkedText()` 为真。
    @MainActor
    private static var isComposingMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}
}

