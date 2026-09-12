//
//  LocalDeviceNameTests.swift
//  QQPlayerTests
//
//  本机展示名（LocalDeviceNameStore）+ 握手 display_name 刷新链路测试：
//  - LocalDeviceNameStore：无保存值回落系统默认名；setName 有值/空白/trim 语义
//  - SyncHello.name 向后兼容：旧端 JSON（无 name 键）解码 nil；带名往返一致；
//    name 纯展示（不进签名输入，改名不破坏验签）
//  - DeviceStore.updateDisplayName：只改 display_name + updated_at；
//    不存在幂等无操作；同名不写；空白名不写
//
//  未覆盖：SyncHostCenter `.ready` 刷新路径的端到端用例——`SyncHostCenter`
//  在 `QQPlayer/Mac/`（iOS target 例外表排除，QQPlayerTests 是 iOS 测试 target
//  看不到该类），仓库又无 Mac 测试 target，故只能在 Mac 侧编译验证 + 由
//  DeviceStore.updateDisplayName / SyncHello.name 两层单测锁定语义。
//

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct LocalDeviceNameTests {
    // MARK: - 夹具

    /// 独立 suite 的 UserDefaults（用完即清，不碰 standard）。
    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "qqplayer.tests.local-device-name.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private static func makeNameStore(
        defaults: UserDefaults,
        key: String = LocalDeviceNameStore.defaultKey,
        systemDefault: String = "系统默认名"
    ) -> LocalDeviceNameStore {
        LocalDeviceNameStore(defaults: defaults, key: key, systemDefault: { systemDefault })
    }

    /// 内存 GRDB + 真实生产代码路径（与 DeviceStoreTests 同模式）。
    private static func makeDeviceStore() throws -> (DeviceStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (DeviceStore(database: manager), dbQueue)
    }

    private static func sampleDevice(
        peerID: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEFGHIJKLMNOPQRST",
        displayName: String = "iPhone",
        role: PeerRole = .client
    ) -> PeerDevice {
        PeerDevice(
            peerID: peerID,
            peerPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            displayName: displayName,
            role: role,
            pairedAt: 1_700_000_000,
            lastSeenAt: 1_700_000_500,
            notes: "书房"
        )
    }

    /// 直读 sync_device 原始行（列级契约断言用）。
    private static func rawRow(_ dbQueue: DatabaseQueue, peerID: String) throws -> Row {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM sync_device WHERE peer_id = ?",
                arguments: [peerID]
            )
        } ?? Row()
    }

    // MARK: - LocalDeviceNameStore

    @Test("LocalDeviceNameStore：无保存值 → 回落注入的 systemDefault")
    func fallsBackToSystemDefault() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = Self.makeNameStore(defaults: defaults, systemDefault: "dax 的 MacBook Pro")

        #expect(store.name == "dax 的 MacBook Pro")
        // 未写键（回落不落盘）
        #expect(defaults.string(forKey: LocalDeviceNameStore.defaultKey) == nil)
    }

    @Test("LocalDeviceNameStore：setName 有值 → 返回该值")
    func setNameStoresValue() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Self.makeNameStore(defaults: defaults)

        store.setName("dax's iPhone")

        #expect(store.name == "dax's iPhone")
        #expect(defaults.string(forKey: LocalDeviceNameStore.defaultKey) == "dax's iPhone")
    }

    @Test("LocalDeviceNameStore：首尾空白被 trim")
    func setNameTrimsWhitespace() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Self.makeNameStore(defaults: defaults)

        store.setName("  dax's iPhone \n")

        #expect(store.name == "dax's iPhone")
        #expect(defaults.string(forKey: LocalDeviceNameStore.defaultKey) == "dax's iPhone")
    }

    @Test("LocalDeviceNameStore：setName 空/纯空白/nil → 清除保存值并回落")
    func setNameClearsOnBlank() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Self.makeNameStore(defaults: defaults, systemDefault: "系统默认名")

        for blank in ["", "   ", "\n\t"] {
            store.setName("dax's iPhone")
            #expect(store.name == "dax's iPhone")

            store.setName(blank)
            #expect(store.name == "系统默认名")
            #expect(defaults.string(forKey: LocalDeviceNameStore.defaultKey) == nil)
        }

        store.setName("dax's iPhone")
        store.setName(nil)
        #expect(store.name == "系统默认名")
        #expect(defaults.string(forKey: LocalDeviceNameStore.defaultKey) == nil)
    }

    @Test("LocalDeviceNameStore：外部写入的空白值也回落（读侧防御）")
    func blankPersistedValueFallsBack() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Self.makeNameStore(defaults: defaults, systemDefault: "系统默认名")

        defaults.set("   ", forKey: LocalDeviceNameStore.defaultKey)

        #expect(store.name == "系统默认名")
    }

    @Test("LocalDeviceNameStore：自定义键互不干扰")
    func customKeyIsolation() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = Self.makeNameStore(defaults: defaults, key: "sync.name.a", systemDefault: "默认A")
        let b = Self.makeNameStore(defaults: defaults, key: "sync.name.b", systemDefault: "默认B")
        a.setName("设备A")

        #expect(a.name == "设备A")
        #expect(b.name == "默认B")
    }

    // MARK: - SyncHello 向后兼容

    @Test("SyncHello：旧 JSON（无 name 键）解码出 name == nil")
    func decodesLegacyHelloWithoutName() throws {
        // 旧端 wire 形态：只有 5 个字段（role/deviceID/peerDeviceID/ephemeralPublicKey/signature）
        let legacy = Data(#"""
        {"role":"client","deviceID":"AAAA","peerDeviceID":"BBBB","ephemeralPublicKey":"a2V5","signature":"c2ln"}
        """#.utf8)

        let decoded = try JSONDecoder().decode(SyncHello.self, from: legacy)

        #expect(decoded.name == nil)
        #expect(decoded.role == SyncHello.roleClient)
        #expect(decoded.deviceID == "AAAA")
    }

    @Test("SyncHello：带 name 往返编码一致；nil 不写键（旧端可读）")
    func roundTripWithName() throws {
        let identity = SyncIdentity.generate()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: identity,
            peerDeviceID: "PEER",
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation,
            name: "dax's iPhone"
        )

        let data = try JSONEncoder().encode(hello)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] as? String == "dax's iPhone")
        #expect(try JSONDecoder().decode(SyncHello.self, from: data) == hello)

        // nil = 不写 name 键（旧端解码不受影响）
        let unnamed = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: identity,
            peerDeviceID: "PEER",
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        let unnamedData = try JSONEncoder().encode(unnamed)
        let unnamedObject = try #require(try JSONSerialization.jsonObject(with: unnamedData) as? [String: Any])
        #expect(unnamedObject["name"] == nil)
        #expect(try JSONDecoder().decode(SyncHello.self, from: unnamedData).name == nil)
    }

    @Test("SyncHello：name 纯展示不参与签名（改名不破坏验签）")
    func nameIsNotPartOfSignature() throws {
        let identity = SyncIdentity.generate()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: identity,
            peerDeviceID: identity.deviceID,
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation,
            name: "dax's iPhone"
        )

        // 中间人改名（payload 明文：hello 阶段无加密）→ 签名仍有效
        hello.name = "attacker"

        try SyncHandshake.verifyHello(
            hello,
            signerPublicKeyRaw: identity.publicKeyRaw,
            expectedRole: SyncHello.roleClient,
            expectedPeerDeviceID: identity.deviceID,
            allowEmptyPeerBinding: true
        )
    }

    // MARK: - DeviceStore.updateDisplayName

    @Test("updateDisplayName：存在记录 → 只改 display_name + updated_at，其它列不变")
    func updatesDisplayNameOnly() throws {
        let (store, dbQueue) = try Self.makeDeviceStore()
        let device = Self.sampleDevice(displayName: "iPhone")
        try store.upsert(device)
        // 把 updated_at 钉在已知旧值（upsert 恒刷新为 now，这里要区分「写没写」）
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_device SET updated_at = ? WHERE peer_id = ?",
                arguments: [Int64(1_600_000_000), device.peerID]
            )
        }

        try store.updateDisplayName(peerID: device.peerID, name: "dax's iPhone")

        let row = try Self.rawRow(dbQueue, peerID: device.peerID)
        #expect(row["display_name"] as? String == "dax's iPhone")
        // 其它列原样
        #expect(row["peer_public_key"] as? String == device.peerPublicKey)
        #expect(row["role"] as? String == PeerRole.client.rawValue)
        #expect(row["paired_at"] as? Int64 == 1_700_000_000)
        #expect(row["last_seen_at"] as? Int64 == 1_700_000_500)
        #expect(row["notes"] as? String == "书房")
        // updated_at 已刷新
        let updatedAt = try #require(row["updated_at"] as? Int64)
        #expect(updatedAt > 1_600_000_000)
        // 只有一条记录，且模型层读回一致
        #expect(try store.all().count == 1)
        #expect(try store.byPeerID(device.peerID)?.displayName == "dax's iPhone")
    }

    @Test("updateDisplayName：名字首尾空白被 trim 后落库")
    func trimsDisplayName() throws {
        let (store, dbQueue) = try Self.makeDeviceStore()
        let device = Self.sampleDevice()
        try store.upsert(device)

        try store.updateDisplayName(peerID: device.peerID, name: "  dax's iPhone \n")

        #expect(try Self.rawRow(dbQueue, peerID: device.peerID)["display_name"] as? String == "dax's iPhone")
    }

    @Test("updateDisplayName：peerID 不存在 → 幂等无操作，不新增行")
    func missingPeerIsNoop() throws {
        let (store, dbQueue) = try Self.makeDeviceStore()

        try store.updateDisplayName(peerID: String(repeating: "Z", count: 52), name: "不存在的设备")

        #expect(try store.all().isEmpty)
        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_device")
        }
        #expect(count == 0)
        // 幂等：再来一次也不抛
        try store.updateDisplayName(peerID: String(repeating: "Z", count: 52), name: "不存在的设备")
    }

    @Test("updateDisplayName：同名 → 不写（updated_at 保持原值）")
    func sameNameDoesNotWrite() throws {
        let (store, dbQueue) = try Self.makeDeviceStore()
        let device = Self.sampleDevice(displayName: "iPhone")
        try store.upsert(device)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_device SET updated_at = ? WHERE peer_id = ?",
                arguments: [Int64(1_600_000_000), device.peerID]
            )
        }

        try store.updateDisplayName(peerID: device.peerID, name: "iPhone")

        let row = try Self.rawRow(dbQueue, peerID: device.peerID)
        #expect(row["display_name"] as? String == "iPhone")
        #expect(row["updated_at"] as? Int64 == 1_600_000_000)
    }

    @Test("updateDisplayName：空白名视为非法（不写、不清空原值）")
    func blankNameIsRejected() throws {
        let (store, dbQueue) = try Self.makeDeviceStore()
        let device = Self.sampleDevice(displayName: "iPhone")
        try store.upsert(device)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_device SET updated_at = ? WHERE peer_id = ?",
                arguments: [Int64(1_600_000_000), device.peerID]
            )
        }

        for blank in ["", "   ", "\n"] {
            try store.updateDisplayName(peerID: device.peerID, name: blank)
        }

        let row = try Self.rawRow(dbQueue, peerID: device.peerID)
        #expect(row["display_name"] as? String == "iPhone")
        #expect(row["updated_at"] as? Int64 == 1_600_000_000)
    }
}
