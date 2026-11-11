//
//  SyncHostSupersedePolicyTests.swift
//  QQPlayerTests
//
//  同步 Host 会话「让位」判定 `SyncHostSupersedePolicy` 纯逻辑测试（2026-11-11）：
//  - 未装配 → 接线
//  - 已装配且同一会话 → 幂等接线（不重复 attach）
//  - 同设备新会话 → 让位（半开旧会话占位的正解）
//  - 不同设备 → 忽略（保持 v1 单会话接线）
//  - peerID 缺失 / 空白 → 保守忽略（不凭空让位）
//  - 全组合枚举：结果恒为三态之一，且与「同设备」事实一致（防判定漂移）
//
//  为什么这些能测：`SyncHostSupersedePolicy` 刻意放在共享 Core（`QQPlayer/Services/`，
//  与 `SyncHostGate` 同一先例），不带会话/监听器依赖 → iOS 单测 target 可直接覆盖。
//  生产侧 `SyncHostCenter` 的接线时序仍靠编译 + 审查 + 真机验收（Mac target 无单测）。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncHostSupersedePolicyTests {
    @Test("未装配：直接接线（不论 peerID 是否已知）")
    func noAttachedHostAttaches() {
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: false,
                attachedSessionMatches: false,
                attachedPeerID: nil,
                newPeerID: "peer-a"
            ) == .attach
        )
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: false,
                attachedSessionMatches: false,
                attachedPeerID: "peer-a",
                newPeerID: nil
            ) == .attach
        )
    }

    @Test("已装配且就是同一会话：幂等接线")
    func sameSessionAttaches() {
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: true,
                attachedPeerID: "peer-a",
                newPeerID: "peer-a"
            ) == .attach
        )
        // 同一对象即使 peerID 暂时读不到也按幂等处理（不拆自己）。
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: true,
                attachedPeerID: nil,
                newPeerID: nil
            ) == .attach
        )
    }

    @Test("同设备新会话：旧会话让位（半开占位的正解）")
    func samePeerSupersedes() {
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: false,
                attachedPeerID: "peer-a",
                newPeerID: "peer-a"
            ) == .supersede
        )
    }

    @Test("不同设备：忽略新会话（保持 v1 单会话接线）")
    func differentPeerIsIgnored() {
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: false,
                attachedPeerID: "peer-a",
                newPeerID: "peer-b"
            ) == .ignore
        )
    }

    @Test("peerID 缺失或空白：保守忽略（绝不凭空让位）")
    func missingPeerIsIgnored() {
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: false,
                attachedPeerID: nil,
                newPeerID: "peer-a"
            ) == .ignore
        )
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: false,
                attachedPeerID: "peer-a",
                newPeerID: ""
            ) == .ignore
        )
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: false,
                attachedPeerID: "   ",
                newPeerID: "peer-a"
            ) == .ignore
        )
    }

    @Test("peerID 只有首尾空白差异：仍算同设备（trim 比较口径）")
    func trimmedPeerSupersedes() {
        #expect(
            SyncHostSupersedePolicy.decide(
                hasAttachedHost: true,
                attachedSessionMatches: false,
                attachedPeerID: " peer-a\n",
                newPeerID: "peer-a "
            ) == .supersede
        )
    }

    @Test("全组合枚举：三态恒定，且 .supersede 只在「已装配 + 异会话 + 同设备」出现")
    func allCombinationsStayConsistent() {
        let peers: [String?] = [nil, "", " ", "peer-a", "peer-b", " peer-a "]
        for hasAttachedHost in [false, true] {
            for attachedSessionMatches in [false, true] {
                for attachedPeerID in peers {
                    for newPeerID in peers {
                        let decision = SyncHostSupersedePolicy.decide(
                            hasAttachedHost: hasAttachedHost,
                            attachedSessionMatches: attachedSessionMatches,
                            attachedPeerID: attachedPeerID,
                            newPeerID: newPeerID
                        )
                        let attached = attachedPeerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let fresh = newPeerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let samePeer = !attached.isEmpty && attached == fresh
                        if !hasAttachedHost || attachedSessionMatches {
                            #expect(decision == .attach)
                        } else if samePeer {
                            #expect(decision == .supersede)
                        } else {
                            #expect(decision == .ignore)
                        }
                    }
                }
            }
        }
    }
}
