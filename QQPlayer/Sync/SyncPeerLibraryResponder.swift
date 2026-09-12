//
//  SyncPeerLibraryResponder.swift
//  QQPlayer
//
//  T9（2026-09-12）「对端内容清单」**应答端**：收 `peer_library_request`（帧 15）→
//  读本端曲库事实（`SyncPeerLibraryCatalog`）→ 回 `peer_library_response`（帧 16）。
//
//  装配点：`SyncLibraryPassiveHost`（iOS 被动端装配，被动端 = 移动端，发起方恒为 Mac）。
//
//  硬约束（本文件是执行点）：
//  - **全程不抛**：载荷解码失败 / 事实读不出来 / 编码失败 → 只记账不炸会话；
//    非法 scope / 非法 offset-limit → 回空清单 + total 0（断会话代价远大于空页）。
//  - **钳制在应答侧**：limit 1...500、offset >= 0（请求来自对端 = 不可信输入）。
//  - 摘要（曲目数/总大小）随每次响应返回（UI 顶部展示不依赖分页）。
//
//  线程：会话线程（NW 队列）同步驱动；无内部可变状态（已无锁）。
//  会话槽位挂接统一走 `SyncSessionAttachment`（分发链，见 SyncPeerSession+Frames.swift）：
//  本实例释放只静默自己，**不牵连链上其它 handler**（🟡F1）。
//

import Foundation

final class SyncPeerLibraryResponder: @unchecked Sendable {
    private let session: SyncPeerSession
    /// 本端内容清单事实提供者（每请求一次求值：歌单成员随用户编辑而变，不做缓存）。
    private let catalogProvider: () -> SyncPeerLibraryCatalog

    // MARK: 诊断回调（锁外触发；仅供上层观测，不参与协议）

    /// 载荷解码失败（协议违例；对端拿不到响应会超时，此处只记账）。
    var onDecodeFailure: ((String) -> Void)?
    /// 已回应答（测试/诊断用）。
    var onResponseSent: ((SyncPeerLibraryResponsePayload) -> Void)?

    // MARK: 会话槽位挂接（分发链）

    private var attachment: SyncSessionAttachment?

    init(session: SyncPeerSession, catalogProvider: @escaping () -> SyncPeerLibraryCatalog) {
        self.session = session
        self.catalogProvider = catalogProvider
        attachment = SyncSessionAttachment(
            session: session,
            owner: self,
            onFrame: { [weak self] frame in self?.handleInboundFrame(frame) }
        )
    }

    /// 停止应答（会话关闭 / 服务停止）：静默自己并让出链位（幂等）。
    /// 不调用也会在本实例释放时自动摘除。
    func detach() {
        attachment?.detach()
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        guard frame.type == .peerLibraryRequest else { return }
        let request: SyncPeerLibraryRequestPayload
        do {
            request = try SyncPeerLibraryCodec.decode(SyncPeerLibraryRequestPayload.self, from: frame.payload)
        } catch {
            // 连 requestID 都解不出 → 无从回应答，只能忽略（对端按超时处理）
            onDecodeFailure?("peer_library_request 解码失败：\(error)")
            return
        }
        // 事实求值失败（生产实现保证不抛）→ 空清单；非法 scope 同样落到空清单分支。
        let catalog = catalogProvider()
        let response = catalog.response(for: request)
        guard let payload = try? SyncPeerLibraryCodec.encode(response) else {
            onDecodeFailure?("peer_library_response 编码失败（scope=\(request.scope)）")
            return
        }
        // 会话已断/未就绪：发不出去也只能忽略（不抛，不影响会话状态机）
        try? session.sendApplicationFrame(type: .peerLibraryResponse, payload: payload)
        onResponseSent?(response)
    }
}
