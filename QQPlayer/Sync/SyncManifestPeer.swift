//
//  SyncManifestPeer.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）manifest 帧的会话层分发钩子：把对端发来的
//  manifest_request 解码 → 交给本地 manifest 提供者 → 回 manifest_response；
//  把对端回到的 manifest_response 解码 → 交给上层（M3-3b 接对账）。
//
//  **本文件只做分发，不做端到端接线**（M3-3b 负责：曲库根/manifest 生成器接入、
//  收到响应后跑 SyncManifestReconciler、toFetch 走 SyncFileSender 拉取、toDelete
//  走删除确认）。与 SyncChangeLogPeer 同构：链式挂接会话 onApplicationFrame
//  （先己后彼），结束用 enabled 开关静默自己（不拆链）。
//
//  安全选择：本地 manifest 提供者缺省（未接线）时**不应答**——空 manifest 会被
//  对端解读为"远端文件全部消失"，进而产出 toDelete 删掉对端整个同步集合。
//  宁可让请求方超时，也绝不回空表。
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

    // 会话槽位链式挂接
    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var forwardingEnabled = true

    init(session: SyncPeerSession) {
        self.session = session
        attachHandlers()
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

    // MARK: 会话槽位挂接（链式：先己后彼；结束用开关静默，不拆链）

    private func attachHandlers() {
        priorAppHandler = session.onApplicationFrame
        session.onApplicationFrame = { [weak self] frame in
            guard let self, self.forwardingEnabled else {
                self?.priorAppHandler?(frame)
                return
            }
            self.handleInboundFrame(frame)
            self.priorAppHandler?(frame)
        }
    }
}
