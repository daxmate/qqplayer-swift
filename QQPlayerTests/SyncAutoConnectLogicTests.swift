//
//  SyncAutoConnectLogicTests.swift
//  QQPlayerTests
//
//  S2 接线：iOS 扫码确认后自动回连的纯逻辑防回归：
//  - SyncConnectLogic.pickHost：QR hostName case-insensitive 匹配优先、
//    无匹配取第一个、空结果 nil（expectedPeerDeviceID pinning 兜底连错安全）
//  - SyncConnectLogic.failure(fromCloseReason:)：会话关闭原因 → 失败模型映射
//    （rejected/timedOut/connectionFailed 分类；userCancelled = 静默不呈现）
//  - SyncPairOutcome(connectFailure:hostName:)：失败模型 → UI outcome 映射
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncAutoConnectLogicTests {
    // MARK: - 主机挑选

    private func makeHost(_ name: String) -> SyncDiscoveredHost {
        SyncDiscoveredHost(
            name: name,
            endpoint: .service(name: name, type: SyncBrowser.serviceType, domain: "", interface: nil)
        )
    }

    @Test("pickHost：QR hostName case-insensitive 匹配优先")
    func pickHostPrefersCaseInsensitiveMatch() {
        let hosts = [makeHost("Living-Room-Mac"), makeHost("Studio")]
        let picked = SyncConnectLogic.pickHost(from: hosts, qrHostName: "living-room-mac")
        #expect(picked?.name == "Living-Room-Mac")
    }

    @Test("pickHost：无名称匹配 → 取第一个发现结果（pinning 保证连错也安全）")
    func pickHostFallsBackToFirst() {
        let hosts = [makeHost("Alpha"), makeHost("Beta")]
        let picked = SyncConnectLogic.pickHost(from: hosts, qrHostName: "Gamma")
        #expect(picked?.name == "Alpha")
    }

    @Test("pickHost：空结果 → nil")
    func pickHostEmptyReturnsNil() {
        #expect(SyncConnectLogic.pickHost(from: [], qrHostName: "Mac") == nil)
    }

    // MARK: - 关闭原因 → 失败模型

    @Test("关闭原因映射：pairingRejected → rejected(原因)")
    func closeReasonRejected() {
        let failure = SyncConnectLogic.failure(fromCloseReason: .pairingRejected("用户点拒绝"))
        #expect(failure == .rejected(reason: "用户点拒绝"))
    }

    @Test("关闭原因映射：handshakeTimeout → timedOut")
    func closeReasonTimeout() {
        #expect(SyncConnectLogic.failure(fromCloseReason: .handshakeTimeout) == .timedOut)
    }

    @Test("关闭原因映射：握手失败/对端不可信/协议违例/存储错误 → connectionFailed")
    func closeReasonHandshakeFailures() {
        #expect(SyncConnectLogic.failure(fromCloseReason: .handshakeFailed(.signatureInvalid)) == .connectionFailed(detail: "signatureInvalid"))
        #expect(SyncConnectLogic.failure(fromCloseReason: .peerUntrusted("DEVICE-ID")) == .connectionFailed(detail: "DEVICE-ID"))
        #expect(SyncConnectLogic.failure(fromCloseReason: .protocolViolation("坏帧")) == .connectionFailed(detail: "坏帧"))
        #expect(SyncConnectLogic.failure(fromCloseReason: .storageError("写失败")) == .connectionFailed(detail: "写失败"))
        #expect(SyncConnectLogic.failure(fromCloseReason: .transportError) == .connectionFailed(detail: nil))
    }

    @Test("关闭原因映射：远端断开/bye → connectionFailed（批准窗内异常断开）")
    func closeReasonRemoteClosed() {
        #expect(SyncConnectLogic.failure(fromCloseReason: .remoteClosed) == .connectionFailed(detail: nil))
        #expect(SyncConnectLogic.failure(fromCloseReason: .receivedBye) == .connectionFailed(detail: nil))
    }

    @Test("关闭原因映射：userCancelled → nil（本端主动取消不呈现失败）")
    func closeReasonUserCancelledIsSilent() {
        #expect(SyncConnectLogic.failure(fromCloseReason: .userCancelled) == nil)
    }

    // MARK: - 失败模型 → UI outcome

    @Test("outcome 映射：hostNotFound 携带 hostName")
    func outcomeHostNotFound() {
        let outcome = SyncPairOutcome(connectFailure: .hostNotFound(hostName: "MacBook"), hostName: nil)
        #expect(outcome == .hostNotFound(hostName: "MacBook"))
        // hostName 缺失时回退到调用方传入的兜底
        let fallback = SyncPairOutcome(connectFailure: .hostNotFound(hostName: nil), hostName: "QR 主机")
        #expect(fallback == .hostNotFound(hostName: "QR 主机"))
    }

    @Test("outcome 映射：rejected/timedOut/connectionFailed")
    func outcomeFailureMapping() {
        #expect(SyncPairOutcome(connectFailure: .rejected(reason: "拒绝"), hostName: nil) == .connectRejected(reason: "拒绝"))
        #expect(SyncPairOutcome(connectFailure: .timedOut, hostName: nil) == .connectTimedOut)
        #expect(SyncPairOutcome(connectFailure: .connectionFailed(detail: "网络错误"), hostName: nil) == .connectFailed(detail: "网络错误"))
        #expect(SyncPairOutcome(connectFailure: .connectionFailed(detail: nil), hostName: nil) == .connectFailed(detail: nil))
    }
}
