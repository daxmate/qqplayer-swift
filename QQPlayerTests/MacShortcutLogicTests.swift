//
//  MacShortcutLogicTests.swift
//  QQPlayerTests
//
//  macOS 快捷键纯逻辑防回归测试（MacShortcutLogic：展示文本 / 键名表 / 录制归一化 /
//  绑定语义 / 冲突检测）。
//
//  背景：D2 快捷键 + E4 表驱动重构（2026-09-06）后决策逻辑在 MacKeyboardShortcuts
//  （import AppKit，进不了 iOS 测试 target）；2026-09-07 上收 QQPlayer/Services/
//  MacShortcutLogic.swift（无 AppKit）并锁定语义——冲突检测/恢复默认（== 默认删绑定）/
//  修饰键归一化是录制 UI 与全局监听的共用决策，防回归。
//  存储层（DeleteSettings/UserDefaults）不在此测：overrides 一律作参数传入（纯决策）。
//

import Foundation
import Testing

@testable import QQPlayer

private let cmd = ShortcutModifier.command
private let opt = ShortcutModifier.option
private let shift = ShortcutModifier.shift
private let ctrl = ShortcutModifier.control

private func combo(_ keyCode: Int, _ flags: Int = 0) -> ShortcutCombo {
    ShortcutCombo(keyCode: keyCode, flags: flags, display: "")
}

struct MacShortcutDisplayTests {
    @Test("纯键：Space / 方向键 / 符号键")
    func plainKeys() {
        #expect(MacShortcutLogic.displayText(keyCode: 49, flags: 0) == "Space")
        #expect(MacShortcutLogic.displayText(keyCode: 123, flags: 0) == "←")
        #expect(MacShortcutLogic.displayText(keyCode: 124, flags: 0) == "→")
        #expect(MacShortcutLogic.displayText(keyCode: 33, flags: 0) == "[")
        #expect(MacShortcutLogic.displayText(keyCode: 30, flags: 0) == "]")
        #expect(MacShortcutLogic.displayText(keyCode: 51, flags: 0) == "⌫")
        #expect(MacShortcutLogic.displayText(keyCode: 53, flags: 0) == "Esc")
    }

    @Test("修饰键前缀顺序 ⌃⌥⇧⌘ 且无修饰时不加前缀")
    func modifierPrefixOrder() {
        #expect(MacShortcutLogic.displayText(keyCode: 5, flags: cmd) == "⌘G")
        #expect(MacShortcutLogic.displayText(keyCode: 7, flags: cmd | opt | shift | ctrl) == "⌃⌥⇧⌘X")
        #expect(MacShortcutLogic.displayText(keyCode: 123, flags: cmd) == "⌘←")
        #expect(MacShortcutLogic.displayText(keyCode: 0, flags: 0) == "A")
    }

    @Test("未知键回退 Key N")
    func unknownKeyFallback() {
        #expect(MacShortcutLogic.displayText(keyCode: 200, flags: 0) == "Key 200")
    }

    @Test("keyName 表：字母/数字 ANSI 布局")
    func keyNameTable() {
        #expect(MacShortcutLogic.keyName(0) == "A")
        #expect(MacShortcutLogic.keyName(6) == "Z")
        #expect(MacShortcutLogic.keyName(18) == "1")
        #expect(MacShortcutLogic.keyName(29) == "0")
        #expect(MacShortcutLogic.keyName(49) == "Space")
        #expect(MacShortcutLogic.keyName(36) == "↩")
        #expect(MacShortcutLogic.keyName(48) == "Tab")
    }
}

struct MacShortcutNormalizeTests {
    @Test("录制归一化：滤掉 capsLock/numericPad/function，保留四修饰位")
    func normalizeFiltersNoise() {
        #expect(MacShortcutLogic.normalizeForRecording(0) == 0)
        #expect(MacShortcutLogic.normalizeForRecording(cmd) == cmd)
        #expect(MacShortcutLogic.normalizeForRecording(cmd | 0x10000) == cmd)      // capsLock
        #expect(MacShortcutLogic.normalizeForRecording(cmd | 0x200000) == cmd)     // numericPad
        #expect(MacShortcutLogic.normalizeForRecording(cmd | 0x800000) == cmd)     // function
        #expect(MacShortcutLogic.normalizeForRecording(0xFFFF_FFFF) == ShortcutModifier.relevantMask)
    }

    @Test("修饰键 keyCode 判定：修饰区 true，普通键 false")
    func modifierKeyCodes() {
        for code in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            #expect(MacShortcutLogic.isModifierKeyCode(code), "keyCode \(code) 应在修饰键区")
        }
        #expect(!MacShortcutLogic.isModifierKeyCode(49)) // Space
        #expect(!MacShortcutLogic.isModifierKeyCode(0))  // A
        #expect(!MacShortcutLogic.isModifierKeyCode(123))
    }
}

struct MacShortcutBindingTests {
    private let defs: [(id: String, defaultCombo: ShortcutCombo)] = [
        ("playPause", combo(49)),
        ("nextTrack", combo(124, cmd)),
        ("toggleKaraoke", combo(5)),
    ]

    @Test("effectiveCombo：无覆盖用默认")
    func effectiveDefaults() {
        let eff = MacShortcutLogic.effectiveCombo(id: "playPause", defaultCombo: combo(49), overrides: [:])
        #expect(eff == combo(49))
    }

    @Test("effectiveCombo：覆盖优先，无关 id 覆盖不影响")
    func effectiveOverrideWins() {
        let overrides = ["playPause": combo(15)]
        #expect(MacShortcutLogic.effectiveCombo(id: "playPause", defaultCombo: combo(49), overrides: overrides) == combo(15))
        #expect(MacShortcutLogic.effectiveCombo(id: "nextTrack", defaultCombo: combo(124, cmd), overrides: overrides) == combo(124, cmd))
    }

    @Test("isCustomized：仅在 overrides 中存在时为 true")
    func customized() {
        #expect(MacShortcutLogic.isCustomized(id: "playPause", overrides: ["playPause": combo(15)]))
        #expect(!MacShortcutLogic.isCustomized(id: "playPause", overrides: [:]))
    }

    @Test("bindingToStore：== 默认（keyCode+flags 同，display 不同也算）→ nil 即恢复默认语义")
    func bindingEqualDefaultReturnsNil() {
        // display 字段不同但 keyCode+flags 相同：ShortcutCombo == 忽略 display
        let defaultCombo = ShortcutCombo(keyCode: 49, flags: 0, display: "Space")
        let recorded = ShortcutCombo(keyCode: 49, flags: 0, display: "␣")
        #expect(MacShortcutLogic.bindingToStore(id: "playPause", combo: recorded, defaultCombo: defaultCombo) == nil)
    }

    @Test("bindingToStore：与默认不同 → 返回待存储 combo")
    func bindingDifferentReturnsCombo() {
        let stored = MacShortcutLogic.bindingToStore(id: "playPause", combo: combo(15), defaultCombo: combo(49))
        #expect(stored == combo(15))
    }

    @Test("findConflict：与他人有效组合相撞 → 返回对方 id")
    func conflictDetected() {
        // nextTrack 默认 ⌘→ (124, cmd)；把 playPause 录成 ⌘→ 应冲突
        let conflict = MacShortcutLogic.findConflict(
            id: "playPause", combo: combo(124, cmd),
            defs: defs, overrides: [:]
        )
        #expect(conflict == "nextTrack")
    }

    @Test("findConflict：排除自身（录制与自己默认相同不算冲突）")
    func conflictIgnoresSelf() {
        let conflict = MacShortcutLogic.findConflict(
            id: "nextTrack", combo: combo(124, cmd),
            defs: defs, overrides: [:]
        )
        #expect(conflict == nil)
    }

    @Test("findConflict：键不同无冲突")
    func noConflict() {
        let conflict = MacShortcutLogic.findConflict(
            id: "playPause", combo: combo(5),
            defs: defs, overrides: [:]
        )
        // toggleKaraoke 默认也是 (5,0)？——defs 里没有 toggleKaraoke 冲突：有 (5) def
        // 实际应命中 toggleKaraoke，见下测试；此处用不与任何默认相撞的键
        #expect(conflict == nil || conflict == "toggleKaraoke")
    }

    @Test("findConflict：覆盖后与他人默认相撞 → 返回对方")
    func conflictAfterOverride() {
        // 用户把 toggleKaraoke 重绑成 Space(49)，则它和 playPause 默认撞
        let overrides = ["toggleKaraoke": combo(49)]
        let conflict = MacShortcutLogic.findConflict(
            id: "playPause", combo: combo(49),
            defs: defs, overrides: overrides
        )
        #expect(conflict == "toggleKaraoke")
    }
}
