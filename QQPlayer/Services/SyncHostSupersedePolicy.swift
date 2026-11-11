//
//  SyncHostSupersedePolicy.swift
//  QQPlayer
//
//  同步 Host 会话「让位」（supersede）判定 —— **纯逻辑、无副作用、平台无关**。
//
//  为什么单独一个文件（照 `SyncHostGate.swift` 的先例）：判定服务的是 Mac 侧
//  `SyncHostCenter`（`QQPlayer/Mac/`，iOS 单测 target 看不到），但判定本身不持有
//  任何状态。抽到共享 Core（`QQPlayer/Services/`）后 QQPlayerTests 才能真跑这段
//  判定，而不是只靠编译 + 人工审查。
//
//  背景（2026-11-11 真机取证）：iPhone 退后台后会话 socket 半开、Mac 侧**永远收不到**
//  closed；回前台重新连入产生**新会话**时，旧实现 `guard libraryHost == nil else { return }`
//  把新会话直接丢掉 → `activeSession` 仍指向死会话，之后所有同步都在旧会话上等清单，
//  20s 必然超时，重试也不行，直到重启 App。
//
//  判定：同一台设备重连 = 旧会话让位（`.supersede`）；不同设备 = 保持 v1 单会话接线
//  （`.ignore`）。peerID 缺失时保守忽略 —— 宁可保留可能还活着的接线，也不凭空让位。
//
//  职责边界：只做判定（不碰会话 / 监听器 / host / DB）。状态的读写归 `SyncHostCenter`。
//

import Foundation

/// 新会话到达（`.ready`）时，对「当前已装配的曲库接线」应执行的动作。
enum SyncHostSupersedeDecision: Equatable, Sendable {
    /// 直接接线：当前没装配，或装配的就是这个会话（幂等）。
    case attach
    /// 已有**其他设备**的接线：保持 v1 单会话语义，忽略新会话。
    case ignore
    /// **同一台设备**重连：拆掉旧接线，让新会话接线。
    case supersede
}

/// 会话让位判定（无副作用）。
enum SyncHostSupersedePolicy {
    /// - Parameters:
    ///   - hasAttachedHost: 是否已装配曲库 host（生产侧 `libraryHost != nil`）。
    ///   - attachedSessionMatches: 已装配 host 绑定的会话是否就是这次的新会话（同一对象）。
    ///   - attachedPeerID: 已装配 host 绑定会话的对端 Device ID（半开时可能缺失）。
    ///   - newPeerID: 新会话的对端 Device ID（握手早期可能缺失）。
    static func decide(
        hasAttachedHost: Bool,
        attachedSessionMatches: Bool,
        attachedPeerID: String?,
        newPeerID: String?
    ) -> SyncHostSupersedeDecision {
        // 没装配 → 接线；装配的就是同一会话 → 也返回 .attach。
        // ⚠️ 调用方必须把 .attach 实现成**幂等**（同一会话已在绑定时直接返回）：
        // 本判定不知道 host 是否已绑定该会话的实例细节，幂等守卫留在 SyncHostCenter。
        guard hasAttachedHost, !attachedSessionMatches else { return .attach }
        // 判据不依赖 connectedPeer（半开时它是脏的）：以 host 绑定会话的 hello 为准。
        guard let attached = normalizedPeerID(attachedPeerID),
              let fresh = normalizedPeerID(newPeerID),
              attached == fresh
        else {
            return .ignore
        }
        return .supersede
    }

    /// 比较口径：去首尾空白；空串等同「没有 peerID」（nil）。
    private static func normalizedPeerID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
