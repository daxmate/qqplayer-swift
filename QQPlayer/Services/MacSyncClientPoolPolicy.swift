//
//  MacSyncClientPoolPolicy.swift
//  QQPlayer
//
//  对端内容客户端池的「退役保活」策略（2026-09-12 审计批次 B4 · M5；无 AppKit →
//  双 target 共享、可在 iOS 测试 target 单测）。
//
//  背景：`SyncPeerLibraryClient.cancel()` 会永久废掉一个实例，而实例被释放会让它
//  挂在会话分发链上的槽位摘除（`SyncSessionAttachment.deinit → detach`）。所以
//  「取消在途请求」的做法是换一个新客户端、把旧的退役保活在池里。
//
//  缺陷（审计 M5）：退役数组只追加、只在会话关闭时清空——用户在同步面板反复切
//  「上传/下载」或断开重连，退役实例（各自带锁与待决请求表）就持续堆积。
//
//  策略：每会话只保活最新 `maxRetiredPerSession` 个。分发链按**存活 handler 列表**
//  倒序调用（`SyncEventHandlerChain.dispatch` 会跳过 owner 已释放的项），因此丢掉
//  更早的退役实例只会摘除它自己的那一项，不影响链上其它 handler。
//

import Foundation

enum MacSyncClientPoolPolicy {
    /// 每个会话保活的退役实例上限（1 = 只保活最新一个；见文件头链接说明）
    static let maxRetiredPerSession = 1

    /// 追加一个退役实例并按上限裁剪（保留**最新**的若干个）。
    static func retiring<Client>(_ retired: [Client], appending client: Client) -> [Client] {
        var list = retired
        list.append(client)
        if list.count > maxRetiredPerSession {
            list.removeFirst(list.count - maxRetiredPerSession)
        }
        return list
    }
}
