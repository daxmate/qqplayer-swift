//
//  MacMainWindowResolver.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  主窗解析的 **AppKit 侧唯一实现**（2026-11-25）。
//
//  选择规则本身在 `MacMainWindowSelection`（纯逻辑、可在 QQPlayerTests 里跑）；
//  这里只做两件事：把 `NSWindow` 拍平成候选、给全仓唯一一个「主窗是谁」的入口。
//  窗口标题不参与任何判据 —— 2026-11-24 产品显示名改成「婷听 / TingFi」后，
//  按标题找主窗必然落空（迷你窗点封面回主窗会静默失败）。
//

import AppKit

@MainActor
enum MacMainWindowResolver {
    /// 登记主窗时写进 `NSWindow.identifier` 的稳定标识。
    static var windowIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(MacMainWindowSelection.mainWindowIdentifier)
    }

    /// `NSWindow` → 纯候选（title 不进快照，标题不是身份来源）。
    static func candidate(for window: NSWindow, registered: NSWindow?) -> MacMainWindowCandidate {
        MacMainWindowCandidate(
            identifier: window.identifier?.rawValue,
            isPanel: window is NSPanel,
            canBecomeMain: window.canBecomeMain,
            isVisible: window.isVisible,
            isRegistered: window === registered,
            isReleasedWhenClosed: window.isReleasedWhenClosed
        )
    }

    /// 解析主窗（唯一入口）：① 登记的弱引用 → ② identifier → ③ 非 panel + canBecomeMain。
    /// 注：NSApp.windows 不写成默认参数 —— 默认参数在 nonisolated 上下文求值，
    ///     会触发 main-actor 隔离警告（构建要求零警告）。
    static func resolve(registered: NSWindow?) -> (window: NSWindow, source: MacMainWindowMatchSource)? {
        resolve(in: NSApp.windows, registered: registered)
    }

    /// 可注入窗口列表的版本（单测/harness 用）。
    static func resolve(
        in windows: [NSWindow],
        registered: NSWindow?
    ) -> (window: NSWindow, source: MacMainWindowMatchSource)? {
        let candidates = windows.map { candidate(for: $0, registered: registered) }
        guard let pick = MacMainWindowSelection.pick(from: candidates) else { return nil }
        return (windows[pick.index], pick.source)
    }

    /// 严格判定「这个窗口是不是主窗」—— became-key 路径与帧观察器用。
    ///
    /// **不退化到 `canBecomeMain`**：设置窗也是普通窗口、也能成为 key，
    /// 退化会把它当成主窗（撑到三栏界面的最小尺寸 / 把设置窗的帧变化记成主窗跳变）。
    static func isMainWindow(_ window: NSWindow, registered: NSWindow?) -> Bool {
        guard !(window is NSPanel) else { return false }
        if let registered, window === registered, !window.isReleasedWhenClosed {
            return true
        }
        return window.identifier?.rawValue == MacMainWindowSelection.mainWindowIdentifier
    }

    /// 解析失败时的现场清单：一行一窗，附上判据字段（避免把日志刷爆）。
    static func windowDump() -> String {
        windowDump(in: NSApp.windows)
    }

    /// 可注入窗口列表的版本。
    static func windowDump(in windows: [NSWindow]) -> String {
        guard !windows.isEmpty else { return "  (NSApp.windows 为空)" }
        return windows.map { window in
            let identifier = window.identifier?.rawValue ?? "-"
            let frame = NSStringFromRect(window.frame)
            return "  - \(type(of: window)) identifier=\(identifier) visible=\(window.isVisible) canBecomeMain=\(window.canBecomeMain) releasedWhenClosed=\(window.isReleasedWhenClosed) frame=\(frame)"
        }
        .joined(separator: "\n")
    }
}
