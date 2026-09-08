//
//  DeviceStoreTests.swift
//  QQPlayerTests
//
//  S2 M1：sync_device 配对记录存储 CRUD 测试。
//  通过 DatabaseManager.init(dbWriter:) 测试缝 + createTables() 在内存 GRDB
//  上跑真实生产代码路径（与 PlayHistoryCleanupTests 同模式），覆盖：
//  - upsert 新增与同 peerID 整体替换（updated_at 刷新）
//  - remove 幂等（不存在也成功）
//  - all 排序稳定（displayName, peerID）
//  - byPeerID 命中/未命中
//  - PeerRole 持久化 roundtrip（host/client）
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct DeviceStoreTests {
    // MARK: - Fixture

    private static func makeStore() throws -> (DeviceStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (DeviceStore(database: manager), dbQueue)
    }

    private static func sampleDevice(
        peerID: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEFGHIJKLMNOPQRST",
        displayName: String = "MacBook Pro",
        role: PeerRole = .host,
        pairedAt: Int64 = 1_700_000_000,
        notes: String? = nil
    ) -> PeerDevice {
        PeerDevice(
            peerID: peerID,
            peerPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            displayName: displayName,
            role: role,
            pairedAt: pairedAt,
            lastSeenAt: pairedAt,
            notes: notes
        )
    }

    // MARK: - upsert

    @Test("upsert：新增记录可查回，字段完整")
    func upsertInserts() throws {
        let (store, _) = try Self.makeStore()
        let device = Self.sampleDevice()

        try store.upsert(device)

        let fetched = try store.byPeerID(device.peerID)
        #expect(fetched != nil)
        #expect(fetched?.displayName == "MacBook Pro")
        #expect(fetched?.role == .host)
        #expect(fetched?.peerPublicKey == device.peerPublicKey)
        #expect(fetched?.pairedAt == device.pairedAt)
    }

    @Test("upsert：同 peerID 整体替换（重配对路径），updated_at 刷新")
    func upsertReplaces() throws {
        let (store, _) = try Self.makeStore()
        let original = Self.sampleDevice(displayName: "旧名字")

        try store.upsert(original)
        // 重配对：同 peerID 新公钥 + 新名字 + 新 pairedAt
        let replacement = Self.sampleDevice(
            displayName: "新名字",
            role: .client,
            pairedAt: 1_800_000_000
        )
        try store.upsert(replacement)

        let fetched = try store.byPeerID(replacement.peerID)
        #expect(fetched?.displayName == "新名字")
        #expect(fetched?.role == .client)
        #expect(fetched?.pairedAt == 1_800_000_000)
        #expect(fetched?.peerPublicKey == replacement.peerPublicKey)
        // 只应有一条记录
        let all = try store.all()
        #expect(all.count == 1)
    }

    @Test("upsert：多台主机互不干扰（多配对语义）")
    func upsertMultiplePeers() throws {
        let (store, _) = try Self.makeStore()
        let mac = Self.sampleDevice(
            peerID: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            displayName: "MacBook Pro"
        )
        let nas = Self.sampleDevice(
            peerID: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            displayName: "NAS",
            role: .host
        )

        try store.upsert(mac)
        try store.upsert(nas)

        #expect(try store.all().count == 2)
        #expect(try store.byPeerID(nas.peerID)?.displayName == "NAS")
    }

    // MARK: - remove

    @Test("remove：删除后查不到；不存在时幂等成功")
    func removeIsIdempotent() throws {
        let (store, _) = try Self.makeStore()
        let device = Self.sampleDevice()
        try store.upsert(device)

        try store.remove(peerID: device.peerID)
        #expect(try store.byPeerID(device.peerID) == nil)
        #expect(try store.all().isEmpty)

        // 幂等：删不存在的也不抛
        try store.remove(peerID: device.peerID)
    }

    // MARK: - all / ordering

    @Test("all：按 displayName 稳定排序")
    func allOrderedByDisplayName() throws {
        let (store, _) = try Self.makeStore()
        try store.upsert(Self.sampleDevice(peerID: String(repeating: "C", count: 52), displayName: "Charlie"))
        try store.upsert(Self.sampleDevice(peerID: String(repeating: "A", count: 52), displayName: "Alice"))
        try store.upsert(Self.sampleDevice(peerID: String(repeating: "B", count: 52), displayName: "Bob"))

        let all = try store.all()
        #expect(all.map(\.displayName) == ["Alice", "Bob", "Charlie"])
    }

    // MARK: - role roundtrip

    @Test("PeerRole：host/client 持久化 roundtrip")
    func roleRoundtrip() throws {
        let (store, _) = try Self.makeStore()
        let host = Self.sampleDevice(role: .host)
        let client = Self.sampleDevice(
            peerID: String(repeating: "D", count: 52),
            role: .client
        )
        try store.upsert(host)
        try store.upsert(client)

        #expect(try store.byPeerID(host.peerID)?.role == .host)
        #expect(try store.byPeerID(client.peerID)?.role == .client)
    }

    // MARK: - PeerDevice → GRDB 直读（列名契约）

    @Test("sync_device 列契约：snake_case 列直读与 CodingKeys 一致")
    func columnContract() throws {
        let (_, dbQueue) = try Self.makeStore()
        let device = Self.sampleDevice(notes: "书房主机")
        let store = try DeviceStore(database: DatabaseManager(dbWriter: dbQueue))
        try store.upsert(device)

        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_device WHERE peer_id = ?", arguments: [device.peerID])
            #expect(row != nil)
            #expect(row?["peer_public_key"] as? String == device.peerPublicKey)
            #expect(row?["role"] as? String == PeerRole.host.rawValue)
            #expect(row?["notes"] as? String == "书房主机")
        }
    }
}
