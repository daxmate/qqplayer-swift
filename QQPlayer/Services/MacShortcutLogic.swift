//
//  MacShortcutLogic.swift
//  QQPlayer
//
//  快捷键展示/冲突/绑定决策纯逻辑（D2/E4；无 AppKit，可单测）。
//  存储层（DeleteSettings）与 action 闭包在 Mac 侧，此处只做决策。
//
//  来源（2026-09-07）：从 Mac/MacKeyboardShortcuts.swift 搬移纯函数体（displayText /
//  modifierPrefix / keyName / ansiKeyChar / isModifierKeyCode / normalizedFlags /
//  effectiveCombo / isCustomized / findConflict 及新增 bindingToStore），行为照抄；
//  @MainActor 壳与 allDefs 表留在 MacKeyboardShortcuts，经此文件转调——决策单一事实源。
//
import Foundation

/// 快捷键修饰键常量（NSEvent.ModifierFlags rawValue 字面量：shift 1<<17 / control 1<<18 / option 1<<19 / command 1<<20）
enum ShortcutModifier {
    static let shift = 1 << 17
    static let control = 1 << 18
    static let option = 1 << 19
    static let command = 1 << 20
    /// 匹配/录制时只保留这四个修饰位（capsLock/numericPad/function 等忽略）
    static let relevantMask = shift | control | option | command
}

enum MacShortcutLogic {
    // MARK: - 展示文本（keyCode + 修饰位 → "⌃⌥⇧⌘X"）

    /// 修饰键展示符号（顺序 ⌃⌥⇧⌘；原实现收 ShortcutCombo，等价改写为收 flags）
    static func modifierPrefix(flags: Int) -> String {
        var prefix = ""
        if flags & ShortcutModifier.control != 0 { prefix += "⌃" }
        if flags & ShortcutModifier.option != 0 { prefix += "⌥" }
        if flags & ShortcutModifier.shift != 0 { prefix += "⇧" }
        if flags & ShortcutModifier.command != 0 { prefix += "⌘" }
        return prefix
    }

    /// 纯逻辑：keyCode + 修饰位 → 展示文本（⌃⌥⇧⌘ 前缀 + 键名；未知键 → "Key N"）。
    static func displayText(keyCode: Int, flags: Int) -> String {
        modifierPrefix(flags: flags) + keyName(keyCode)
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

    // MARK: - 录制归一化 / 修饰键判定

    /// 只保留 cmd/opt/ctrl/shift 位（capsLock/numericPad/function 忽略）。
    /// 原实现（MacKeyboardShortcuts.normalizedFlags）先 intersection(.deviceIndependentFlagsMask)
    /// 再 & relevantMask；因 relevantMask 各位全在 deviceIndependent 保留区（0xFFFF0000），
    /// 等价于直接 & relevantMask——壳层保留原 NSEvent 表达式传 rawValue 亦可，见 MacKeyboardShortcuts。
    static func normalizeForRecording(_ rawFlags: Int) -> Int {
        rawFlags & ShortcutModifier.relevantMask
    }

    /// 录制输入 → 合法组合？（过滤纯修饰键按下：keyCode 落在修饰键区）
    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        // ⇧16/56 58? ANSI：shift 56/60、ctrl 59/62、opt 58/61、cmd 55/54
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    // MARK: - 绑定决策（overrides 作参数传入，不碰存储）

    /// 某快捷键当前生效组合（覆盖优先，缺省用默认）
    static func effectiveCombo(id: String, defaultCombo: ShortcutCombo, overrides: [String: ShortcutCombo]) -> ShortcutCombo {
        overrides[id] ?? defaultCombo
    }

    /// 是否被用户自定义过（面板「恢复默认」按钮状态用）
    static func isCustomized(id: String, overrides: [String: ShortcutCombo]) -> Bool {
        overrides[id] != nil
    }

    /// 录制保存决策：== 默认（ShortcutCombo == 语义：keyCode+flags 同即可）→ nil 表示
    /// 「恢复默认 = 不存储」；否则返回要写入的 combo。
    static func bindingToStore(id: String, combo: ShortcutCombo, defaultCombo: ShortcutCombo) -> ShortcutCombo? {
        combo == defaultCombo ? nil : combo
    }

    /// 冲突检测：combo 与「除 id 外各 def 的有效组合」同 keyCode+flags → 返回冲突 def 的 id。
    /// defs 由调用方从 allDefs 派生（(id, defaultCombo) 元组，闭包依赖留在 Mac 侧）。
    static func findConflict(id: String, combo: ShortcutCombo, defs: [(id: String, defaultCombo: ShortcutCombo)], overrides: [String: ShortcutCombo]) -> String? {
        for def in defs where def.id != id {
            let other = effectiveCombo(id: def.id, defaultCombo: def.defaultCombo, overrides: overrides)
            if other.keyCode == combo.keyCode, other.flags == combo.flags {
                return def.id
            }
        }
        return nil
    }

    // MARK: - 键盘自动重复策略（2026-09-12 审计 B4 · M1）

    /// 允许「长按连发」（`NSEvent.isARepeat`）的快捷键 id：只有 seek 类希望重复
    /// （按住 ←/→ 连续快退/快进）。其余全是 toggle / 轮换类——播放暂停、收藏、
    /// 跟唱、AB 循环、播放顺序轮换——重复会来回抖动、反复写库。
    static let repeatableShortcutIds: Set<String> = ["seekBack", "seekForward"]

    /// 收到一次按键事件后是否应执行 action：非重复事件一律执行；
    /// 自动重复事件仅 repeatable 类执行（其余仍由监听消费，不冒泡给响应链）。
    static func shouldRunAction(id: String, isARepeat: Bool) -> Bool {
        !isARepeat || repeatableShortcutIds.contains(id)
    }
}
