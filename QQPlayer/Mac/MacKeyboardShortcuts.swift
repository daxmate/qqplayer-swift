//
//  MacKeyboardShortcuts.swift
//  QQPlayer
//
//  App-wide keyboard shortcuts (QQPlayerMac target only).
//
//  D2 固定快捷键 + E4 表驱动重构（web 版 shortcuts.ts 对齐，2026-09-06）：
//  - 快捷键定义表（id/label/默认组合/action），全部可录制重绑（web「配置表驱动、
//    全量可录制」语义）；自定义绑定存 DeleteSettings.shortcutBindings，
//    == 默认组合的绑定不存储（恢复默认 = 删绑定）
//  - 新增 G 跟唱开关 / A AB 循环开关（当前句=A） / B 等选终点时设当前句为终点
//  - 冲突检测：录制新组合与其它快捷键有效组合（含默认）冲突 → 拒绝并提示
//
//  既有语义不变：
//  Space 播放/暂停 · ←/→ ±10s · ⌘←/⌘→ 上一首/下一首 · R 播放顺序轮换 ·
//  F 收藏/取消当前曲 · [ / ] 倍速降/升档 · G 跟唱开关 · A AB 开关 · B 设 AB 终点
//
//  平台差异裁剪（沿用 D2）：↑/↓ 音量、⌘↑/⌘↓、M 静音不做（macOS 音量系统管理）；
//  ⌘K（SearchAnything）与 ⌘,（Settings）由菜单/系统已有，不在本表。
//
//  实现：NSEvent local monitor（App 内全局、不抢其他 App 的键）。播放按钮上原有
//  keyboardShortcut 已移除，统一走本监听——行为单一事实源，避免双触发。文本输入
//  焦点（NSTextField/NSSearchField 的 field editor 是 NSTextView）时全部放行。
//

import AppKit
import SwiftUI

/// 快捷键组合的修饰键常量（与 NSEvent.ModifierFlags rawValue 一致）
enum ShortcutModifier {
    static let shift = Int(NSEvent.ModifierFlags.shift.rawValue)      // 1<<17
    static let control = Int(NSEvent.ModifierFlags.control.rawValue)  // 1<<18
    static let option = Int(NSEvent.ModifierFlags.option.rawValue)    // 1<<19
    static let command = Int(NSEvent.ModifierFlags.command.rawValue)  // 1<<20
    /// 匹配/录制时只保留这四个修饰位（capsLock/numericPad/function 等忽略）
    static let relevantMask = shift | control | option | command
}

/// 键盘快捷键定义（E4 表驱动；action 一律 @MainActor——NSEvent monitor 在主线程）
struct MacShortcutDef {
    let id: String
    let labelKey: String
    let defaultCombo: ShortcutCombo
    let action: @MainActor () -> Void
}

/// 全局键盘快捷键监听（QQPlayerMac target only，@MainActor 单例式 enum）。
@MainActor
enum MacKeyboardShortcuts {
    private static var monitor: Any?
    private static var settingsObserver: NSObjectProtocol?
    /// 覆盖绑定缓存（nil = 未加载）；DeleteSettings.shortcutBindings
    private static var overrides: [String: ShortcutCombo]?

    // MARK: - 快捷键定义表（web SHORTCUTS 对齐子集；labelKey 本地化）

    /// 修饰键展示符号（顺序 ⌃⌥⇧⌘）
    private static func modifierPrefix(_ combo: ShortcutCombo) -> String {
        var prefix = ""
        if combo.flags & ShortcutModifier.control != 0 { prefix += "⌃" }
        if combo.flags & ShortcutModifier.option != 0 { prefix += "⌥" }
        if combo.flags & ShortcutModifier.shift != 0 { prefix += "⇧" }
        if combo.flags & ShortcutModifier.command != 0 { prefix += "⌘" }
        return prefix
    }

    /// 纯逻辑：keyCode + 修饰位 → 展示文本（⌃⌥⇧⌘ 前缀 + 键名；未知键 → "Key N"）。
    /// 设置面板录制后展示与列表渲染共用（行为单一事实源）。
    static func displayText(keyCode: Int, flags: Int) -> String {
        let combo = ShortcutCombo(keyCode: keyCode, flags: flags, display: "")
        return modifierPrefix(combo) + Self.keyName(keyCode)
    }

    /// keyCode → 键名（本表涉及键 + 通用字母/数字/符号/方向键）
    static func keyName(_ keyCode: Int) -> String {
        // ANSI 字母/数字（macOS 固定 keyCode 布局）
        if let char = ansiKeyChar[keyCode] { return char }
        switch keyCode {
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 51: return "⌫"
        case 53: return "Esc"
        case 36: return "↩"
        case 48: return "Tab"
        case 33: return "["
        case 30: return "]"
        default: return "Key \(keyCode)"
        }
    }

    private static let ansiKeyChar: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
    ]

    /// 快捷键定义表（顺序 = 设置面板展示顺序；分组注释保持可读）
    static let allDefs: [MacShortcutDef] = [
        // ---- 播放控制 ----
        MacShortcutDef(
            id: "playPause", labelKey: "shortcut_play_pause",
            defaultCombo: ShortcutCombo(keyCode: 49, flags: 0, display: "Space")
        ) {
            let player = PlayerEngine.shared
            if player.isPlaying {
                player.pause()
            } else {
                player.play()
            }
        },
        MacShortcutDef(
            id: "seekBack", labelKey: "shortcut_seek_back",
            defaultCombo: ShortcutCombo(keyCode: 123, flags: 0, display: "←")
        ) {
            Self.seekRelative(-10)
        },
        MacShortcutDef(
            id: "seekForward", labelKey: "shortcut_seek_forward",
            defaultCombo: ShortcutCombo(keyCode: 124, flags: 0, display: "→")
        ) {
            Self.seekRelative(10)
        },
        MacShortcutDef(
            id: "prevTrack", labelKey: "shortcut_prev_track",
            defaultCombo: ShortcutCombo(keyCode: 123, flags: ShortcutModifier.command, display: "⌘←")
        ) {
            Task { @MainActor in await PlayerEngine.shared.previousTrack() }
        },
        MacShortcutDef(
            id: "nextTrack", labelKey: "shortcut_next_track",
            defaultCombo: ShortcutCombo(keyCode: 124, flags: ShortcutModifier.command, display: "⌘→")
        ) {
            Task { @MainActor in await PlayerEngine.shared.nextTrack() }
        },
        MacShortcutDef(
            id: "cyclePlayMode", labelKey: "shortcut_cycle_play_mode",
            defaultCombo: ShortcutCombo(keyCode: 15, flags: 0, display: "R")
        ) {
            PlayerEngine.shared.cyclePlaybackOrderMode()
        },
        MacShortcutDef(
            id: "toggleFavorite", labelKey: "shortcut_toggle_favorite",
            defaultCombo: ShortcutCombo(keyCode: 3, flags: 0, display: "F")
        ) {
            guard let track = PlayerEngine.shared.currentTrack else { return }
            try? AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
        },
        MacShortcutDef(
            id: "speedDown", labelKey: "shortcut_speed_down",
            defaultCombo: ShortcutCombo(keyCode: 33, flags: 0, display: "[")
        ) {
            Self.cycleSpeed(-1)
        },
        MacShortcutDef(
            id: "speedUp", labelKey: "shortcut_speed_up",
            defaultCombo: ShortcutCombo(keyCode: 30, flags: 0, display: "]")
        ) {
            Self.cycleSpeed(1)
        },

        // ---- 跟唱（E4 新增：G/A/B，语义镜像 KaraokeControlBar 按钮）----
        MacShortcutDef(
            id: "toggleKaraoke", labelKey: "shortcut_toggle_karaoke",
            defaultCombo: ShortcutCombo(keyCode: 5, flags: 0, display: "G")
        ) {
            KaraokeController.shared.toggleKaraokeMode()
        },
        MacShortcutDef(
            id: "abToggle", labelKey: "shortcut_ab_toggle",
            defaultCombo: ShortcutCombo(keyCode: 0, flags: 0, display: "A")
        ) {
            Self.toggleABAtCurrentLine()
        },
        MacShortcutDef(
            id: "abEnd", labelKey: "shortcut_ab_end",
            defaultCombo: ShortcutCombo(keyCode: 11, flags: 0, display: "B")
        ) {
            Self.setABEndAtCurrentLine()
        },
    ]

    // MARK: - 安装

    /// 安装监听（App 启动调用一次；重复调用幂等）。
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
        // 设置改动（录制/重置）→ 清绑定缓存，下次按键重读
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .qqplayerSettingsDidChange,
                object: nil,
                queue: .main
            ) { _ in
                // 通知在主线程队列投递；Swift 5 模式下直接清缓存即可
                overrides = nil
            }
        }
    }

    /// 暂停全局监听（设置页录制快捷键期间调用，避免按下键先触发动作）；幂等。
    static func suspend() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// 恢复全局监听（录制结束/离开设置页）；幂等，与 install 同路径。
    static func resume() {
        install()
    }

    // MARK: - 绑定读写（DeleteSettings.shortcutBindings；== 默认不存储）

    /// 当前覆盖绑定（首次访问加载；设置变更通知后清缓存）
    private static func currentOverrides() -> [String: ShortcutCombo] {
        if let overrides { return overrides }
        let loaded = DeleteSettings.load().shortcutBindings
        overrides = loaded
        return loaded
    }

    /// 某快捷键当前生效组合（覆盖优先，缺省用默认）
    static func effectiveCombo(for def: MacShortcutDef) -> ShortcutCombo {
        currentOverrides()[def.id] ?? def.defaultCombo
    }

    /// 是否被用户自定义过（面板「恢复默认」按钮状态用）
    static func isCustomized(_ id: String) -> Bool {
        currentOverrides()[id] != nil
    }

    /// 录制保存：== 默认 → 删绑定（恢复默认语义）；否则写入。返回新生效组合。
    @discardableResult
    static func saveBinding(id: String, combo: ShortcutCombo) -> ShortcutCombo {
        var settings = DeleteSettings.load()
        if let def = allDefs.first(where: { $0.id == id }),
           combo.keyCode == def.defaultCombo.keyCode,
           combo.flags == def.defaultCombo.flags {
            settings.shortcutBindings.removeValue(forKey: id)
        } else {
            settings.shortcutBindings[id] = combo
        }
        settings.save() // 发 .qqplayerSettingsDidChange → 本类清缓存
        return effectiveCombo(for: allDefs.first { $0.id == id } ?? allDefs[0])
    }

    /// 恢复默认（删绑定；== 默认语义幂等）
    static func resetBinding(id: String) {
        var settings = DeleteSettings.load()
        settings.shortcutBindings.removeValue(forKey: id)
        settings.save()
    }

    // MARK: - 冲突检测（纯逻辑：对比其它快捷键的有效组合）

    /// 新组合与「除 id 外的全部快捷键有效组合」冲突 → 返回冲突的快捷键 id。
    @discardableResult
    static func findConflict(for id: String, combo: ShortcutCombo) -> String? {
        for def in allDefs where def.id != id {
            let other = effectiveCombo(for: def)
            if other.keyCode == combo.keyCode, other.flags == combo.flags {
                return def.id
            }
        }
        return nil
    }

    /// 录制输入 → 合法组合？（过滤纯修饰键按下：keyCode 落在修饰键区）
    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        // ⇧16/56 58? ANSI：shift 56/60、ctrl 59/62、opt 58/61、cmd 55/54
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    // MARK: - 事件处理

    /// 返回 nil = 事件已消费；返回 event = 放行。
    private static func handle(_ event: NSEvent) -> NSEvent? {
        // 文本输入焦点 → 全部放行（打字不触发快捷键）
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return event
        }

        let flags = normalizedFlags(event.modifierFlags)
        guard let def = allDefs.first(where: { def in
            let combo = effectiveCombo(for: def)
            return combo.keyCode == Int(event.keyCode) && combo.flags == flags
        }) else {
            return event
        }
        def.action()
        return nil
    }

    /// 只保留 cmd/opt/ctrl/shift 位（capsLock/numericPad/function 忽略）
    private static func normalizedFlags(_ flags: NSEvent.ModifierFlags) -> Int {
        Int(flags.intersection(.deviceIndependentFlagsMask).rawValue) & ShortcutModifier.relevantMask
    }

    /// 录制时归一化修饰键（供设置面板调用）
    static func normalizedFlagsForRecording(_ flags: NSEvent.ModifierFlags) -> Int {
        normalizedFlags(flags)
    }

    // MARK: - Actions

    private static func seekRelative(_ delta: TimeInterval) {
        let player = PlayerEngine.shared
        guard player.currentTrack != nil, player.duration > 0 else { return }
        let target = min(max(player.playbackTime + delta, 0), player.duration)
        Task { @MainActor in await player.seek(to: target) }
    }

    /// [ / ]：倍速降/升一档（speedLevels 0.5-1.0；web slower/faster 对齐）
    private static func cycleSpeed(_ delta: Int) {
        let karaoke = KaraokeController.shared
        let levels = KaraokeController.speedLevels
        let current = levels.firstIndex(of: karaoke.speed) ?? 0
        let target = min(max(current + delta, 0), levels.count - 1)
        karaoke.setSpeed(levels[target])
    }

    /// A：AB 循环开关（镜像 KaraokeControlBar AB 按钮：已启用 → 退出；否则当前句=A）
    private static func toggleABAtCurrentLine() {
        let karaoke = KaraokeController.shared
        if karaoke.abLoop != nil {
            karaoke.exitABLoop()
            return
        }
        guard karaoke.isKaraokeOn else { return }
        let player = PlayerEngine.shared
        guard player.currentTrack != nil else { return }
        let index = LyricTiming.activeLineIndex(time: player.playbackTime, in: karaoke.currentLines)
        guard let index else { return }
        karaoke.enterABLoop(currentLine: index)
    }

    /// B：等选终点（abLoop.b == nil）时设当前句为终点（走 clickLine 的 setABEnd 路径；
    /// 其它状态 B 无动作，避免误触跳句）
    private static func setABEndAtCurrentLine() {
        let karaoke = KaraokeController.shared
        guard karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil else { return }
        let player = PlayerEngine.shared
        guard player.currentTrack != nil else { return }
        let index = LyricTiming.activeLineIndex(time: player.playbackTime, in: karaoke.currentLines)
        guard let index else { return }
        karaoke.clickLine(index: index) // 等选终点态 → 仅 setABEnd，不跳句
    }
}
