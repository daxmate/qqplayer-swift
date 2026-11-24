//
//  MacMainWindowFrameWatch.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  主窗帧变化的**只读诊断观察器**（2026-11-24）。
//
//  为什么需要：2.2.1 出现「关掉设置窗后主窗向上跳一点」（偶发）。能产生窗口帧变化的路子不止一条
//  （styleMask 手术、AppKit 按 autosave 恢复 frame、SwiftUI 布局、别的窗口成为 key 后的重排…），
//  光读代码分不清是谁干的。`NSWindow.didResizeNotification` 是**同步 post**：
//  回调里 `Thread.callStackSymbols` 就带着触发者 —— 复现时日志直接把元凶写在脸上。
//
//  ⚠️ 只记录，**绝不改 frame**：这里不做任何 setFrame / orderFront / 布局动作，
//     否则观察器自己就成了新的帧变化来源。
//

import AppKit

@MainActor
final class MacMainWindowFrameWatch {
    static let shared = MacMainWindowFrameWatch()

    private var isStarted = false
    /// 上一次记录的帧（nil = 还没基准，第一条不记）。
    private var lastFrame: NSRect?
    private var observer: NSObjectProtocol?

    private init() {}

    /// 全应用生命周期只注册一次（`MacAppDelegate.applicationDidFinishLaunching` 调用）。
    func start() {
        guard !isStarted else { return }
        isStarted = true
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                MacMainWindowFrameWatch.shared.noteFrameChange(of: window)
            }
        }
    }

    /// 只认标题「QQPlayer」的非 panel 主窗（与 `MacAppDelegate.clampTitleMainWindowIfNeeded` 同一判据）。
    private func noteFrameChange(of window: NSWindow) {
        guard !(window is NSPanel), window.title == "QQPlayer" else { return }
        let frame = window.frame

        // live resize = 用户自己在拖边：只更新基准、不打日志，否则拖一次刷一屏。
        guard !window.inLiveResize else {
            lastFrame = frame
            return
        }

        defer { lastFrame = frame }
        guard let last = lastFrame else { return }
        let moved = abs(frame.origin.x - last.origin.x) > 1
            || abs(frame.origin.y - last.origin.y) > 1
            || abs(frame.width - last.width) > 1
            || abs(frame.height - last.height) > 1
        guard moved else { return }

        // 只留 12 帧：够看出「是谁 post 的」，又不至于每行都是半个栈。
        let stack = Thread.callStackSymbols.prefix(12).joined(separator: " <- ")
        AppLog.info(
            .ui,
            "ℹ️ 主窗帧变化 from=\(Self.describe(last)) to=\(Self.describe(frame)) styleMask=\(window.styleMask.rawValue) contentMin=\(Self.describe(window.contentMinSize)) stack=\(stack)"
        )
    }

    private static func describe(_ rect: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private static func describe(_ size: NSSize) -> String {
        String(format: "%.1fx%.1f", size.width, size.height)
    }
}
