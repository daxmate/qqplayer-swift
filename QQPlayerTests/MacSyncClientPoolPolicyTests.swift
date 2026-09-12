//
//  MacSyncClientPoolPolicyTests.swift
//  QQPlayerTests
//
//  对端客户端池「退役保活」上限策略回归用例
//  —— 2026-09-12 审计批次 B4 · M5。
//
//  修复前 `MacSyncPeerClientPool.retired` 只追加（`retired[key, default: []].append(old)`），
//  仅在会话关闭时整批清空：用户在同步面板反复切「上传/下载」或断开重连，退役实例
//  （各自带锁与待决请求表）就持续堆积——长会话内存增长。
//
//  注意：池本身在 `QQPlayer/Mac/`（QQPlayerMac target），iOS 测试 target 看不到；
//  故上限决策下沉到共享 `MacSyncClientPoolPolicy`（本文件锁定），生产 pool 直接调用它。
//  修复前该策略函数不存在 → 用例连编译都过不了。
//

import Foundation
import Testing

@testable import QQPlayer

struct MacSyncClientPoolPolicyTests {
    @Test("上限 = 每会话保活 1 个退役实例")
    func capIsOne() {
        #expect(MacSyncClientPoolPolicy.maxRetiredPerSession == 1)
    }

    @Test("反复退役只保留最新一个（修复前会无限追加）")
    func keepsOnlyNewestClient() {
        var retired: [Int] = []
        for client in 1 ... 5 {
            retired = MacSyncClientPoolPolicy.retiring(retired, appending: client)
        }
        #expect(retired == [5])
    }

    @Test("未到上限时按追加顺序保留")
    func appendsBelowCap() {
        let retired = MacSyncClientPoolPolicy.retiring([], appending: 1)
        #expect(retired == [1])
    }

    @Test("上限为 1 时连续退役的内存增长有界（5 次退役 → 常数 1）")
    func growthIsBounded() {
        var retired: [Int] = []
        for client in 1 ... 5 {
            retired = MacSyncClientPoolPolicy.retiring(retired, appending: client)
            #expect(retired.count <= MacSyncClientPoolPolicy.maxRetiredPerSession)
        }
    }
}
