//
//  MacMainWindowSelection.swift
//  QQPlayer
//
//  主窗候选选择 —— 纯逻辑，不依赖 AppKit（QQPlayerTests 在 iOS 上也能编、能跑）。
//
//  为什么存在（2026-11-25）：2026-11-24 产品显示名改成「婷听 / TingFi」后，运行实例的
//  主窗**标题已不是 "QQPlayer"**，旧判据（按标题找主窗）必然落空，而且失败完全静默
//  ——迷你窗点封面回主窗 = 什么都不发生。窗口标题随产品名变，天生不是稳定身份；
//  这里把「选哪个窗口当主窗」抽成只看 identifier / panel / canBecomeMain 的纯函数，
//  AppKit 侧（MacMainWindowResolver）只负责把 NSWindow 拍平成候选。
//

import Foundation

/// 一个窗口的判据快照（故意不含 title：标题不是主窗身份来源）。
struct MacMainWindowCandidate: Equatable {
    /// `NSWindow.identifier`（视图侧登记主窗时打上的稳定标识）。
    var identifier: String?
    /// `NSPanel`（迷你窗 / 桌面歌词窗等浮窗）永不作为主窗。
    var isPanel: Bool
    /// `NSWindow.canBecomeMain`。
    var canBecomeMain: Bool
    /// `NSWindow.isVisible`：只做现场记录，**不参与** ①② 级选择（见 pick 注释）。
    var isVisible: Bool
    /// 是否为视图侧登记的那一个窗口（弱引用仍有效）。
    var isRegistered: Bool
    /// `NSWindow.isReleasedWhenClosed`：已关闭且会释放的窗口是僵尸态，不能当主窗。
    var isReleasedWhenClosed: Bool

    init(
        identifier: String? = nil,
        isPanel: Bool = false,
        canBecomeMain: Bool = true,
        isVisible: Bool = true,
        isRegistered: Bool = false,
        isReleasedWhenClosed: Bool = false
    ) {
        self.identifier = identifier
        self.isPanel = isPanel
        self.canBecomeMain = canBecomeMain
        self.isVisible = isVisible
        self.isRegistered = isRegistered
        self.isReleasedWhenClosed = isReleasedWhenClosed
    }
}

/// 命中的层级 —— 日志必须能看出「这次是用哪一级判据找到主窗的」。
enum MacMainWindowMatchSource: String, Equatable {
    /// ① 视图侧登记的主窗弱引用。
    case registered
    /// ② `NSWindow.identifier` 命中登记标识。
    case identifier
    /// ③ 兜底：非 panel 且 `canBecomeMain`（会打日志，不作为首选）。
    case canBecomeMain
}

/// 选择结果（值类型，方便单测直接比较）。
struct MacMainWindowPick: Equatable {
    /// 命中候选在输入数组里的下标。
    let index: Int
    let source: MacMainWindowMatchSource
}

enum MacMainWindowSelection {
    /// 主窗稳定标识（与 `MacMainWindowResolver.windowIdentifier` 同一个字符串，单一来源）。
    static let mainWindowIdentifier = "com.daxmate.qqplayer.mainWindow"

    /// 按 ① → ② → ③ 选主窗。
    ///
    /// - 同级多候选时取**数组顺序**里的第一个（`NSApp.windows` 顺序 = 前到后）：
    ///   同一输入永远同一结果，与窗口标题无关。
    /// - ①② 都不看 `isVisible`：迷你模式下主窗是 `orderOut`（`isVisible == false`）状态，
    ///   它正是要被 `makeKeyAndOrderFront` 恢复的那个窗口 —— 用可见性过滤会把唯一正解漏掉。
    static func pick(from candidates: [MacMainWindowCandidate]) -> MacMainWindowPick? {
        if let index = candidates.firstIndex(where: {
            $0.isRegistered && !$0.isPanel && !$0.isReleasedWhenClosed
        }) {
            return MacMainWindowPick(index: index, source: .registered)
        }
        if let index = candidates.firstIndex(where: {
            !$0.isPanel && $0.identifier == mainWindowIdentifier
        }) {
            return MacMainWindowPick(index: index, source: .identifier)
        }
        if let index = candidates.firstIndex(where: {
            !$0.isPanel && $0.canBecomeMain && !$0.isReleasedWhenClosed
        }) {
            return MacMainWindowPick(index: index, source: .canBecomeMain)
        }
        return nil
    }
}
