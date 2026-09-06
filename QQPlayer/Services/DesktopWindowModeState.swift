//
//  DesktopWindowModeState.swift
//  QQPlayer
//
//  迷你模式/桌面歌词窗的纯状态机（E3 v2：主窗 ⇄ 迷你窗 + 桌面歌词，2026-09-06 用户拍板）。
//  决策上收（DesktopWindowsManager 只执行窗口副作用）。不变量：
//    1. 桌面歌词可见 ⇒ 迷你模式激活（lyricVisible ⇒ isMiniActive）
//    2. 歌词窗显隐收敛 = isMiniActive && miniLyricsEnabled（reconcile）
//    3. enterMini / showMainWindow 幂等
//
import Foundation

struct DesktopWindowModeState: Equatable, Sendable {
    private(set) var isMiniActive = false
    private(set) var isLyricVisible = false

    /// 进入迷你模式；已在迷你态 → false（无变化）
    @discardableResult
    mutating func enterMini() -> Bool {
        guard !isMiniActive else { return false }
        isMiniActive = true
        return true
    }

    /// 返回主窗：迷你态 → 清迷你+歌词，返回 true；主窗态幂等 → false
    @discardableResult
    mutating func showMainWindow() -> Bool {
        guard isMiniActive else { return false }
        isMiniActive = false
        isLyricVisible = false
        return true
    }

    /// 收敛歌词窗（模式/设置变化后调用）：目标 = isMiniActive && miniLyricsEnabled。返回是否有变化。
    @discardableResult
    mutating func reconcile(miniLyricsEnabled: Bool) -> Bool {
        let want = isMiniActive && miniLyricsEnabled
        guard want != isLyricVisible else { return false }
        isLyricVisible = want
        return true
    }
}
