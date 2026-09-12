//
//  SyncManifestPeer.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）manifest 帧的会话层分发钩子：把对端发来的
//  manifest_request 解码 → 交给本地 manifest 提供者 → 回 manifest_response；
//  把对端回到的 manifest_response 解码 → 交给上层（M3-3b 接对账）。
//
//  **本文件只做分发，不做端到端接线**（M3-3b 负责：曲库根/manifest 生成器接入、
//  收到响应后跑 SyncManifestReconciler、toFetch 走 SyncFileSender 拉取）。与
//  SyncChangeLogPeer 同构：挂接会话 onApplicationFrame（先己后彼）——挂接与释放
//  语义统一走 `SyncSessionAttachment`（会话事件分发链，见 SyncPeerSession+Frames.swift）：
//  本实例释放**不得**让链上更早的 handler 收不到帧（🟡F1）。
//
//  安全选择：本地 manifest 提供者缺省（未接线）时**不应答**——空 manifest 会被
//  对端解读为"远端曲库是空的"，据此对该端曲库做出错误判断（漏拉/误判为已同步）。
//  宁可让请求方超时，也绝不回空表。（同步不传播删除，故不存在"误删"风险；此处
//  兜的是"误判为空库"。）
//

import Foundation

final class SyncManifestPeer: @unchecked Sendable {
    /// 解析错误（帧载荷 JSON 非法）——调用方按协议违例处理。
    enum DecodeError: Error, Equatable {
        case invalidPayload(String)
    }

    private let session: SyncPeerSession

    /// 本地 manifest 提供者：收到请求 → 返回本地（已过滤）条目。
    /// M3-3b 接入 = 扫描曲库 + SyncManifestGenerator.generate + collection.filter。
    var localManifestProvider: ((SyncCollection) -> [ManifestEntry])?
    /// 本地曲库根显示名（响应附带的诊断字段）。
    var localRootName: (() -> String?)?
    /// 收到对端 manifest 响应（M3-3b 接 SyncManifestReconciler）。
    var onManifestReceived: ((SyncManifestResponse) -> Void)?
    /// 解码失败（载荷非法；锁外触发）。
    var onDecodeFailure: ((DecodeError) -> Void)?
    /// 收到请求但本地提供者未接线（未应答；诊断用）。
    var onProviderUnavailable: (() -> Void)?

    // 会话槽位挂接（分发链）
    private var attachment: SyncSessionAttachment?

    init(session: SyncPeerSession) {
        self.session = session
        attachment = SyncSessionAttachment(
            session: session,
            owner: self,
            onFrame: { [weak self] frame in self?.handleInboundFrame(frame) }
        )
    }

    /// 停止收帧（会话结束 / 本轮结束）：静默自己并让出链位（幂等）。
    /// 不调用也会在**本实例释放时自动摘除**；无论哪种，链上其它 handler 都不受影响。
    func detach() {
        attachment?.detach()
    }

    // MARK: 对外 API

    /// 主动请求对端 manifest（M3-3b 在 ready 后调用）。
    func requestManifest(collection: SyncCollection = .all) throws {
        let request = SyncManifestRequest(collection: collection)
        let payload = try SyncManifestCodec.encode(request)
        try session.sendApplicationFrame(type: .manifestRequest, payload: payload)
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        switch frame.type {
        case .manifestRequest:
            handleRequest(frame)
        case .manifestResponse:
            handleResponse(frame)
        default:
            break // 其他业务帧（file_* / change_log_*）不归本类
        }
    }

    // MARK: 收帧处理

    private func handleRequest(_ frame: SyncFrame) {
        let request: SyncManifestRequest
        do {
            request = try SyncManifestCodec.decode(SyncManifestRequest.self, from: frame.payload)
        } catch {
            onDecodeFailure?(.invalidPayload("manifest_request 解码失败：\(error)"))
            return
        }
        guard let provider = localManifestProvider else {
            // 未接线：不应答（空 manifest 会被误读为"全部消失"→ 对端误删）
            onProviderUnavailable?()
            return
        }
        let response = SyncManifestResponse(
            entries: provider(request.collection),
            rootName: localRootName?()
        )
        do {
            let payload = try SyncManifestCodec.encode(response)
            try session.sendApplicationFrame(type: .manifestResponse, payload: payload)
        } catch {
            onDecodeFailure?(.invalidPayload("manifest_request 应答失败：\(error)"))
        }
    }

    private func handleResponse(_ frame: SyncFrame) {
        let response: SyncManifestResponse
        do {
            response = try SyncManifestCodec.decode(SyncManifestResponse.self, from: frame.payload)
        } catch {
            onDecodeFailure?(.invalidPayload("manifest_response 解码失败：\(error)"))
            return
        }
        onManifestReceived?(response)
    }

}
