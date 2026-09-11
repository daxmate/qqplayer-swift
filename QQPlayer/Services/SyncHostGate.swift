//
//  SyncHostGate.swift
//  QQPlayer
//
//  M6（T1，2026-09-11）同步 Host 常驻监听 · **启停判定纯逻辑**（平台无关，可单测）。
//
//  为什么单独一个文件（而不是写在 SyncHostCenter 里）：
//  监听生命周期的**拥有者**是 Mac 侧 `SyncHostCenter`（`QQPlayer/Mac/`，属
//  QQPlayerMac target，iOS 单测 target 看不到）；而「能不能启动 / 该不该停 / 开关
//  切换后要做什么」是**无副作用布尔判定**。把它抽到共享 Core（`QQPlayer/Services/`，
//  与 `MacShortcutLogic` / `DesktopWindowModeState` 同一先例），QQPlayerTests
//  （iOS 单测 target）才能真正跑到这段判定，而不是只靠编译 + 人工审查。
//
//  职责边界：只做判定，**不持有状态、不碰监听器 / DB / UserDefaults**
//  （带任何依赖都进不了 iOS 单测）。状态的读写归 `SyncHostCenter`。
//

import Foundation

/// 开关切换后应执行的动作。
enum SyncHostToggleAction: Equatable, Sendable {
    /// 无需动作（状态与期望一致）。
    case none
    /// 启动监听。
    case start
    /// 停止监听。
    case stop
}

/// Host 常驻监听启停判定（无副作用）。
enum SyncHostGate {
    /// 是否可以启动：开关开启**且**未在运行。
    /// 已在运行时返回 false —— 幂等要求「重复 start 不得重启监听」
    /// （重启会踢掉已配对会话、作废已注册 QR nonce）。
    static func shouldStart(allowsLAN: Bool, isRunning: Bool) -> Bool {
        allowsLAN && !isRunning
    }

    /// 是否应该停止：开关关闭**且**仍在运行。
    /// 未运行时返回 false（避免无谓的 stop 调用；stop 本身幂等，这里只是判定收口）。
    static func shouldStop(allowsLAN: Bool, isRunning: Bool) -> Bool {
        !allowsLAN && isRunning
    }

    /// 开关切换后的动作（`SyncHostCenter.allowsLANConnections.didSet` 用）。
    static func toggleAction(allowsLAN: Bool, isRunning: Bool) -> SyncHostToggleAction {
        if shouldStart(allowsLAN: allowsLAN, isRunning: isRunning) { return .start }
        if shouldStop(allowsLAN: allowsLAN, isRunning: isRunning) { return .stop }
        return .none
    }
}
