//
//  MacKeyboardShortcuts.swift
//  QQPlayer
//
//  App-wide keyboard shortcuts (QQPlayerMac target only).
//
//  D 组快捷键（web 版 shortcuts.ts 对齐，2026-09-05）：
//  Space 播放/暂停 · ←/→ ±10s · ⌘←/⌘→ 上一首/下一首 · R 播放顺序轮换 ·
//  F 收藏/取消当前曲 · [ / ] 倍速降/升档
//
//  平台差异裁剪：
//  - web 的 ↑/↓ 音量、⌘↑/⌘↓ 大步音量、M 静音不做——macOS 音量由系统管理
//    （PlayerEngine 无 App 内音量概念，iOS 才轮询 outputVolume）
//  - G 跟唱开关 / L 译文开关 / A/B 设点 / 跟唱上下句暂缓：依赖歌词与跟唱
//    UI 语义（双击歌词/按钮入口已存在），随歌词设置批次再议
//  - ⌘K（SearchAnything）与 ⌘,（Settings）由菜单/系统已有，不重复注册
//
//  实现：NSEvent local monitor（App 内全局、不抢其他 App 的键）。播放按钮上
//  原有的 keyboardShortcut(.space)/⌘←/⌘→ 已移除，统一走本监听——行为单一
//  事实源，避免 monitor 与 SwiftUI 按钮双触发。文本输入焦点（TextField /
//  NSSearchField 的 field editor 是 NSTextView）时全部放行，避免打字误触。
//

import AppKit

/// 全局键盘快捷键监听（QQPlayerMac target only，@MainActor 单例式 enum）。
@MainActor
enum MacKeyboardShortcuts {
    private static var monitor: Any?

    /// keyCode（ANSI 布局无关，与键盘输入法状态无关）。
    private enum Key {
        static let space: UInt16 = 49
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let r: UInt16 = 15
        static let f: UInt16 = 3
        static let leftBracket: UInt16 = 33
        static let rightBracket: UInt16 = 30
    }

    /// 安装监听（App 启动调用一次；重复调用幂等）。
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    // MARK: - 事件处理

    /// 返回 nil = 事件已消费（不再分发）；返回 event = 放行。
    private static func handle(_ event: NSEvent) -> NSEvent? {
        // 文本输入焦点（NSTextField / NSSearchField 的 field editor）→ 全部放行，
        // 打字不能触发播放快捷键（空格/字母/方向键都是输入内容）。
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let hasControl = flags.contains(.control)
        let plain = !hasCommand && !hasOption && !hasControl

        switch event.keyCode {
        case Key.space:
            guard plain else { return event }
            Task { @MainActor in
                let player = PlayerEngine.shared
                if player.isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
            }
            return nil

        case Key.left, Key.right:
            // ⌘← / ⌘→ = 上一首 / 下一首（web prevTrack/nextTrack）
            if hasCommand, !hasOption, !hasControl {
                Task { @MainActor in
                    if event.keyCode == Key.left {
                        await PlayerEngine.shared.previousTrack()
                    } else {
                        await PlayerEngine.shared.nextTrack()
                    }
                }
                return nil
            }
            // 纯 ←/→ = ±10s seek（对齐 web；iTunes 同款：列表焦点时也全局 seek）
            guard plain else { return event }
            Task { @MainActor in
                let player = PlayerEngine.shared
                guard player.currentTrack != nil, player.duration > 0 else { return }
                let delta: TimeInterval = event.keyCode == Key.left ? -10 : 10
                let target = min(max(player.playbackTime + delta, 0), player.duration)
                await player.seek(to: target)
            }
            return nil

        case Key.r:
            // R = 播放顺序轮换（顺序 → 随机 → 循环列表 → 单曲循环）
            guard plain else { return event }
            Task { @MainActor in
                PlayerEngine.shared.cyclePlaybackOrderMode()
            }
            return nil

        case Key.f:
            // F = 收藏/取消收藏当前曲（红心 UI 经 FavoritesChanged 通知同步）
            guard plain else { return event }
            Task { @MainActor in
                guard let track = PlayerEngine.shared.currentTrack else { return }
                try? AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
            }
            return nil

        case Key.leftBracket, Key.rightBracket:
            // [ / ] = 倍速降/升一档（speedLevels 0.5-1.0；web slower/faster 对齐）
            guard plain else { return event }
            Task { @MainActor in
                let karaoke = KaraokeController.shared
                let levels = KaraokeController.speedLevels
                let current = levels.firstIndex(of: karaoke.speed) ?? 0
                let delta = event.keyCode == Key.leftBracket ? -1 : 1
                let target = min(max(current + delta, 0), levels.count - 1)
                karaoke.setSpeed(levels[target])
            }
            return nil

        default:
            return event
        }
    }
}
