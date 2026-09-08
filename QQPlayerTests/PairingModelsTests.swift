//
//  PairingModelsTests.swift
//  QQPlayerTests
//
//  配对协议消息模型（S2, M1）JSON 编解码防回归：
//  - PairQRPayload / PairRequest / PairResponse 往返一致 + 键名（wire 用 camelCase）
//  - PeerDevice 往返一致 + 键名（DB 列即 JSON 键，snake_case，作 GRDB Record）
//  - PeerRole rawValue 契约（host/client，落库文本）
//  - 可选字段（reason/notes）缺失与显式 nil 都能解码
//
//  纯 Codable 模型测试，无 IO；GRDB 行级往返见 DeviceStoreTests。
//

import Foundation
import Testing

@testable import QQPlayer

struct PairingModelsTests {
    // MARK: - Fixtures

    private func sampleQR() -> PairQRPayload {
        PairQRPayload(
            protoVersion: SyncProtocolVersion.current,
            hostName: "张超的 MacBook Pro",
            deviceID: String(repeating: "ABCDEFG", count: 7) + "XYZ", // 52 字符占位
            publicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            sessionNonce: Data([1, 2, 3, 4, 5, 6, 7, 8]).base64EncodedString()
        )
    }

    private func sampleDevice() -> PeerDevice {
        PeerDevice(
            peerID: String(repeating: "ABCDEFG", count: 7) + "XYZ",
            peerPublicKey: Data(repeating: 9, count: 32).base64EncodedString(),
            displayName: "MacBook Pro",
            role: .host,
            pairedAt: 1_750_000_000,
            lastSeenAt: 1_750_000_100,
            notes: "客厅主机"
        )
    }

    // MARK: - Roundtrip

    @Test("PairQRPayload JSON 往返一致")
    func qrPayloadRoundtrip() throws {
        let original = sampleQR()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairQRPayload.self, from: data)
        #expect(decoded == original)
    }

    @Test("PairQRPayload wire 键名为 camelCase")
    func qrPayloadCamelCaseKeys() throws {
        let data = try JSONEncoder().encode(sampleQR())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protoVersion"] != nil)
        #expect(object["hostName"] != nil)
        #expect(object["deviceID"] != nil)
        #expect(object["publicKey"] != nil)
        #expect(object["sessionNonce"] != nil)
        #expect(object.count == 5)
    }

    @Test("PairRequest JSON 往返一致")
    func pairRequestRoundtrip() throws {
        let original = PairRequest(
            clientDeviceID: "CLIENT-ID-52-CHARACTERS-PLACEHOLDER",
            clientPublicKey: Data(repeating: 3, count: 32).base64EncodedString(),
            nonceSignature: Data(repeating: 4, count: 64).base64EncodedString()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("PairResponse JSON 往返一致（approved + reason 有值）")
    func pairResponseRoundtripWithReason() throws {
        let original = PairResponse(approved: false, reason: "用户拒绝")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("PairResponse 缺 reason 字段也能解码（approved-only 载荷）")
    func pairResponseDecodesWithoutReason() throws {
        let data = Data(#"{"approved":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
        #expect(decoded == PairResponse(approved: true, reason: nil))
    }

    @Test("PeerDevice JSON 往返一致（notes 有值）")
    func peerDeviceRoundtripWithNotes() throws {
        let original = sampleDevice()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PeerDevice.self, from: data)
        #expect(decoded == original)
    }

    @Test("PeerDevice notes 缺失/null 解码为 nil")
    func peerDeviceDecodesNilNotes() throws {
        // notes 键缺失
        let withoutKey = Data(#"{"peer_id":"ID","peer_public_key":"a2V5","display_name":"Mac","role":"host","paired_at":1,"last_seen_at":1}"#.utf8)
        #expect(try JSONDecoder().decode(PeerDevice.self, from: withoutKey).notes == nil)
        // notes 显式 null
        let withNull = Data(#"{"peer_id":"ID","peer_public_key":"a2V5","display_name":"Mac","role":"client","paired_at":1,"last_seen_at":1,"notes":null}"#.utf8)
        #expect(try JSONDecoder().decode(PeerDevice.self, from: withNull).notes == nil)
    }

    @Test("PeerDevice JSON 键为 snake_case（与 sync_device 列名一致）")
    func peerDeviceSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(sampleDevice())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["peer_id"] != nil)
        #expect(object["peer_public_key"] != nil)
        #expect(object["display_name"] != nil)
        #expect(object["paired_at"] != nil)
        #expect(object["last_seen_at"] != nil)
        #expect(object["role"] != nil)
        #expect(object["notes"] != nil)
        #expect(object.count == 7)
    }

    // MARK: - PeerRole 契约

    @Test("PeerRole rawValue 契约（落库/协议文本）")
    func peerRoleRawValues() {
        #expect(PeerRole.host.rawValue == "host")
        #expect(PeerRole.client.rawValue == "client")
    }

    @Test("PeerRole Codable 往返")
    func peerRoleCodableRoundtrip() throws {
        let data = try JSONEncoder().encode(PeerRole.client)
        #expect(try JSONDecoder().decode(PeerRole.self, from: data) == .client)
    }
}
