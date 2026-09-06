//
//  DesktopWindowModeStateTests.swift
//  QQPlayerTests
//
//  迷你模式/桌面歌词窗纯状态机防回归测试（DesktopWindowModeState）。
//
//  背景（2026-09-06 用户拍板 E3 v2）：主窗 ⇄ 迷你窗互斥 + 桌面歌词随迷你联动——
//  桌面歌词可见 ⇒ 迷你模式激活；歌词窗显隐收敛 = isMiniActive && miniLyricsEnabled；
//  enterMini / showMainWindow 幂等。决策原内联在 MacDesktopWindowsManager（耦合 NSPanel
//  不可测），2026-09-07 上收为纯状态机并锁定语义（决策上收、执行下沉的项目铁律）。
//
//  注：#expect 宏捕获为不可变值，mutating 调用必须先执行再断言。
//

import Foundation
import Testing

@testable import QQPlayer

struct DesktopWindowModeStateTests {
    @Test("初始态：非迷你、歌词不可见")
    func initialState() {
        let state = DesktopWindowModeState()
        #expect(!state.isMiniActive)
        #expect(!state.isLyricVisible)
    }

    @Test("enterMini 首次进入返回 true 并激活迷你")
    func enterMiniActivates() {
        var state = DesktopWindowModeState()
        let changed = state.enterMini()
        #expect(changed)
        #expect(state.isMiniActive)
    }

    @Test("enterMini 幂等：已在迷你态重复调用返回 false 且状态不变")
    func enterMiniIsIdempotent() {
        var state = DesktopWindowModeState()
        let first = state.enterMini()
        #expect(first)
        let second = state.enterMini()
        #expect(!second)
        #expect(state.isMiniActive)
        #expect(!state.isLyricVisible)
    }

    @Test("不变量：主窗态即使 miniLyricsEnabled 歌词也不可见")
    func lyricRequiresMini() {
        var state = DesktopWindowModeState()
        let changed = state.reconcile(miniLyricsEnabled: true)
        #expect(!changed)
        #expect(!state.isLyricVisible)
    }

    @Test("迷你态 + miniLyricsEnabled → 歌词收敛可见")
    func lyricAppearsInMiniWithSetting() {
        var state = DesktopWindowModeState()
        state.enterMini()
        let changed = state.reconcile(miniLyricsEnabled: true)
        #expect(changed)
        #expect(state.isMiniActive)
        #expect(state.isLyricVisible)
    }

    @Test("迷你态 + miniLyricsEnabled 关闭 → 歌词不可见")
    func lyricHiddenWhenSettingOff() {
        var state = DesktopWindowModeState()
        state.enterMini()
        _ = state.reconcile(miniLyricsEnabled: true)
        let changed = state.reconcile(miniLyricsEnabled: false)
        #expect(changed)
        #expect(state.isLyricVisible == false)
    }

    @Test("reconcile 无变化返回 false（调用方无需动窗口）")
    func reconcileNoChangeReturnsFalse() {
        var state = DesktopWindowModeState()
        let offNoChange = state.reconcile(miniLyricsEnabled: false)
        #expect(!offNoChange)
        state.enterMini()
        _ = state.reconcile(miniLyricsEnabled: true)
        let again = state.reconcile(miniLyricsEnabled: true)
        #expect(!again)
    }

    @Test("showMainWindow 从迷你态返回 true 并清空迷你+歌词")
    func showMainClearsMiniState() {
        var state = DesktopWindowModeState()
        state.enterMini()
        _ = state.reconcile(miniLyricsEnabled: true)
        let changed = state.showMainWindow()
        #expect(changed)
        #expect(!state.isMiniActive)
        #expect(!state.isLyricVisible)
    }

    @Test("showMainWindow 幂等：主窗态重复调用返回 false")
    func showMainIsIdempotent() {
        var state = DesktopWindowModeState()
        let changed = state.showMainWindow()
        #expect(!changed)
        #expect(!state.isMiniActive)
    }

    @Test("迷你态关歌词后直接回主窗 → 全清")
    func showMainAfterLyricsOff() {
        var state = DesktopWindowModeState()
        state.enterMini()
        _ = state.reconcile(miniLyricsEnabled: false)
        let changed = state.showMainWindow()
        #expect(changed)
        #expect(!state.isMiniActive)
        #expect(!state.isLyricVisible)
    }

    @Test("迷你退出后再次进入可重新显示歌词（状态可复用）")
    func canReenterAfterExit() {
        var state = DesktopWindowModeState()
        state.enterMini()
        _ = state.reconcile(miniLyricsEnabled: true)
        _ = state.showMainWindow()
        let reenter = state.enterMini()
        #expect(reenter)
        let lyricAgain = state.reconcile(miniLyricsEnabled: true)
        #expect(lyricAgain)
        #expect(state.isMiniActive)
        #expect(state.isLyricVisible)
    }

    @Test("不变量穷举：操作序列后歌词可见 ⇒ 迷你激活")
    func invariantLyricImpliesMini() {
        // 覆盖 v2 用户可见交互（进迷你/带歌词/关歌词/回主窗/重进/设置开合）：
        // 用统一小步操作集合枚举长度 3 的全部序列（4^3=64 组，状态机小，穷举可负担），
        // 每组后断言不变量：歌词可见 ⇒ 迷你激活。
        let ops: [(String, (inout DesktopWindowModeState) -> Void)] = [
            ("enter", { _ = $0.enterMini() }),
            ("main", { _ = $0.showMainWindow() }),
            ("recOn", { _ = $0.reconcile(miniLyricsEnabled: true) }),
            ("recOff", { _ = $0.reconcile(miniLyricsEnabled: false) }),
        ]
        for a in ops {
            for b in ops {
                for c in ops {
                    var state = DesktopWindowModeState()
                    a.1(&state)
                    b.1(&state)
                    c.1(&state)
                    let ok = !state.isLyricVisible || state.isMiniActive
                    #expect(ok, "不变量破坏：\(a.0)→\(b.0)→\(c.0)")
                }
            }
        }
    }
}
