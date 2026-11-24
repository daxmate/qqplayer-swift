//
//  MacWindowFrameAnchor.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  掩码手术（`styleMask` 增删 `.fullSizeContentView`）的**帧锚定唯一实现**（2026-11-24）。
//
//  为什么需要：给 `NSWindow.styleMask` 插 / 删 `.fullSizeContentView` 时，AppKit 会重算窗口 frame——
//  **高度会变**（unified 工具栏那一档，实测 32 / 52pt 级），但 `origin` 不动。
//  用户的观感就是「窗口自己往上跳了一下」：下边缘没动、上边缘随高度上移，
//  而人眼锚定的是标题栏 / 上边缘，所以读出来是「窗口向上移动了一点」。
//
//  本工具只做一件事：手术前后各取一次 frame，高度变了就把 `origin.y` 掰回来，
//  让**上边缘（maxY）保持不动**，x / width 一律不动。不改任何其它窗口属性。
//
//  ⚠️ 只用于「我们自己主动改 styleMask」的 4 个点：设置窗玻璃 apply / restore、主窗 chrome apply / restore。
//     其它窗口帧变化（用户拖拽、SwiftUI 布局、AppKit 恢复 frame）都不该走这里。
//

import AppKit

enum MacWindowFrameAnchor {
    /// 纯几何：把 `after` 校正成「上边缘与 `before` 对齐」。
    ///
    /// - 高度不变 → 原样返回 `after`（这种情况下的位移是别的机制干的，不归本工具管）。
    /// - 高度变了 → 保留 `after` 的 size 与 `origin.x`，只把 `origin.y` 改写成
    ///   `before.maxY - after.height`（等价于让 `maxY` 落在 `before.maxY` 上）。
    static func anchoredFrame(before: NSRect, after: NSRect) -> NSRect {
        guard before.height != after.height else { return after }
        var corrected = after
        corrected.origin.y = before.maxY - after.height
        return corrected
    }

    /// 包住一次掩码手术：记录 before → 执行 body → 读 after → 必要时把 frame 锚回去。
    ///
    /// 返回值供调用点打诊断日志（格式统一走 `logLine(op:why:title:outcome:)`）：
    /// - `before` / `after`：手术前后的真实 frame（`deltaH` 由这两者相减得出）。
    /// - `corrected`：**实际生效**的 frame。没校正（高度没变或窗口不可见）时等于 `after`。
    ///
    /// `isVisible == false` 时**不** setFrame：窗口正在关闭 / 还没显示，
    /// 这时动 frame 只会污染 AppKit 的 autosave frame，观感上也没有任何收益。
    @discardableResult
    static func perform(
        on window: NSWindow,
        _ body: () -> Void
    ) -> (before: NSRect, after: NSRect, corrected: NSRect) {
        let before = window.frame
        body()
        let after = window.frame
        let anchored = anchoredFrame(before: before, after: after)
        guard anchored != after, window.isVisible else {
            return (before, after, after)
        }
        window.setFrame(anchored, display: true)
        return (before, after, anchored)
    }

    /// 结构化日志行（**唯一**格式出处）；调用点只负责 `AppLog.info(.ui, logLine(...))`。
    ///
    /// 一行一条、行内不换行（`docs/logging.md`）。`corrected` 表示「真的把 frame 掰回去了」。
    static func logLine(
        op: String,
        why: String,
        title: String,
        outcome: (before: NSRect, after: NSRect, corrected: NSRect)
    ) -> String {
        let deltaH = outcome.after.height - outcome.before.height
        let applied = outcome.corrected != outcome.after
        let name = title.isEmpty ? "-" : title
        let delta = String(format: "%.1f", deltaH)
        return "ℹ️ [窗口帧] op=\(op) title=\(name) deltaH=\(delta) corrected=\(applied) why=\(why)"
    }

    /// 掩码手术后打一条诊断日志（**仅高度真变了才打**，正常路径不刷屏）。
    ///
    /// `emit` 由调用点传入（`AppLog.info(.ui, ...)`）——本文件刻意**不依赖 AppLog**，
    /// 这样纯几何 + 格式这两块能被 `scripts/mac-chrome-harness` 单独 swiftc 编译断言。
    static func report(
        _ outcome: (before: NSRect, after: NSRect, corrected: NSRect),
        op: String,
        why: String,
        title: String,
        emit: (String) -> Void
    ) {
        guard outcome.before.height != outcome.after.height else { return }
        emit(logLine(op: op, why: why, title: title, outcome: outcome))
    }
}
