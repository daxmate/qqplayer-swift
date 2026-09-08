//
//  SyncPairingFlow.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）配对流程接线薄层 + 设备列表辅助（纯逻辑，可单测）：
//  - SyncPairingFlow：UI 输入（扫码 JSON 文本 / 手输 ID）→ 状态机事件映射。
//    扫码解析/输入到机器事件的组装收敛于此，SwiftUI 层只持有机器实例并
//    handle 事件，使「UI → 状态机」接线脱离视图可测（任务：接线薄层抽纯函数）。
//  - PairingFailure.localizedKey：失败原因 → 本地化 key（文案值在各语言
//    Localizable.strings；纯 key 映射避免 UI 层写 switch）。
//  - SyncDeviceList：DeviceStore 列表数据源纯函数（角色过滤 / ID 短格式），
//    macOS「全部设备」与 iOS「已配对主机」两处消费同一入口（行为单一事实源）。
//

import Foundation

/// 配对流程接线薄层：UI 输入 → PairingStateMachine.Event 的纯转换。
enum SyncPairingFlow {
    /// 扫码得到的文本 → receivedQR 事件。
    /// 解析失败（非 UTF-8/字段缺失）抛 SyncQRCodecError，调用方展示失败。
    static func qrEvent(from json: String, alreadyPaired: Bool, at now: TimeInterval) throws -> PairingStateMachine.Event {
        let payload = try SyncQRCodec.decode(json)
        return .receivedQR(payload, at: now, alreadyPaired: alreadyPaired)
    }

    /// 手输文本（容忍分隔符/空白/大小写）→ manualIDEntered 事件。
    /// 规范化/字符集校验在机器内部完成（candidate(fromManualInput:)）。
    static func manualEvent(from rawID: String, alreadyPaired: Bool, at now: TimeInterval) -> PairingStateMachine.Event {
        .manualIDEntered(rawID, at: now, alreadyPaired: alreadyPaired)
    }
}

/// 配对失败原因 → 本地化 key（文案值在多语言 Localizable.strings）。
extension PairingFailure {
    var localizedKey: String {
        switch self {
        case .invalidQRPayload: return "sync_failure_invalid_payload"
        case .invalidDeviceID: return "sync_failure_invalid_device_id"
        case .invalidPublicKey: return "sync_failure_invalid_public_key"
        case .fingerprintMismatch: return "sync_failure_fingerprint_mismatch"
        case .notAwaitingConfirmation: return "sync_failure_not_awaiting"
        }
    }
}

/// 已配对设备列表数据源辅助（纯函数）。
enum SyncDeviceList {
    /// role == .host 的记录（iOS「已配对主机」列表；macOS 全量直读 DeviceStore.all()）。
    static func hosts(in devices: [PeerDevice]) -> [PeerDevice] {
        devices.filter { $0.role == .host }
    }

    /// 设备行 ID 短格式（首组 + 末组，比全量分组 ID 少占地）。
    /// 非规范化 ID 兜底返回 nil（展示层显示原始值由调用方决定）。
    static func shortIDText(_ device: PeerDevice) -> String? {
        guard let parts = DeviceID.shortComparisonParts(device.peerID) else { return nil }
        return "\(parts.first) … \(parts.last)"
    }

    /// 设备展示名兜底：空名（手输候选握手前）显示占位文案 key。
    static func displayName(_ device: PeerDevice, fallbackKey: String = "sync_unknown_device") -> String {
        device.displayName.isEmpty ? fallbackKey.localized : device.displayName
    }

    /// 候选展示名兜底（确认卡/批准卡用；手输候选握手前名未知）。
    static func displayName(_ candidate: PeerCandidate, fallbackKey: String = "sync_unknown_device") -> String {
        candidate.displayName.isEmpty ? fallbackKey.localized : candidate.displayName
    }
}
