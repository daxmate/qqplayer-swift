//
//  SyncIdentityTests.swift
//  QQPlayerTests
//
//  本端身份（S2, M1）逻辑防回归：Ed25519 密钥对生成/加载/删除 + 可注入
//  Keychain 抽象（SyncKeychainStoring）。Keychain 真实 IO（Security 框架）不在此测
//  ——用内存 mock 锁逻辑：首次生成并持久化、二次加载同一身份、损坏数据报错
//  不静默换身份、Keychain 错误透传、签名密钥可用性（sign/verify 自检）。
//

import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

// MARK: - 内存 Keychain mock（协议层注入）

private final class MockKeychainStore: SyncKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var failLoad = false
    var failSave = false
    var failDelete = false

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    func loadData(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if failLoad { throw SyncKeychainError.status(errSecNotAvailable) }
        return storage[key(service: service, account: account)]
    }

    func saveData(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failSave { throw SyncKeychainError.status(errSecNotAvailable) }
        storage[key(service: service, account: account)] = data
    }

    func deleteData(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failDelete { throw SyncKeychainError.status(errSecNotAvailable) }
        storage[key(service: service, account: account)] = nil
    }

    /// 测试观察：当前是否已存身份（含 service/account 契约断言）
    func hasIdentity(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(service: service, account: account)] != nil
    }
}

struct SyncIdentityTests {
    // MARK: - 首次生成 + 持久化

    @Test("首次 loadOrCreate：生成密钥并持久化，服务/账户常量正确")
    func firstLoadCreatesAndPersists() throws {
        let keychain = MockKeychainStore()
        let store = SyncIdentityStore(keychain: keychain)

        let identity = try store.loadOrCreateIdentity()

        #expect(identity.privateKeyRaw.count == 32)
        #expect(identity.publicKeyRaw.count == 32)
        #expect(identity.deviceID.count == DeviceID.fullLength)
        #expect(DeviceID.isValid(identity.deviceID))
        #expect(keychain.hasIdentity(
            service: SyncIdentityStore.keychainService,
            account: SyncIdentityStore.keychainAccount
        ))
        // 公钥指纹 == deviceID（跨层一致性）
        #expect(DeviceID.fingerprintMatches(deviceID: identity.deviceID, publicKeyData: identity.publicKeyRaw))
    }

    @Test("二次 loadOrCreate：从 Keychain 加载同一身份（稳定 Device ID）")
    func secondLoadReturnsSameIdentity() throws {
        let keychain = MockKeychainStore()
        let store = SyncIdentityStore(keychain: keychain)

        let first = try store.loadOrCreateIdentity()
        let second = try store.loadOrCreateIdentity()

        #expect(second == first)
        #expect(second.deviceID == first.deviceID)
    }

    @Test("两台独立设备（独立 Keychain）生成不同身份")
    func distinctStoresGenerateDistinctIdentities() throws {
        let identityA = try SyncIdentityStore(keychain: MockKeychainStore()).loadOrCreateIdentity()
        let identityB = try SyncIdentityStore(keychain: MockKeychainStore()).loadOrCreateIdentity()
        #expect(identityA != identityB)
        #expect(identityA.deviceID != identityB.deviceID)
    }

    // MARK: - 删除 / 重建

    @Test("deleteIdentity 后 loadOrCreate 重新生成（换机/重置语义）")
    func deleteThenRegenerate() throws {
        let keychain = MockKeychainStore()
        let store = SyncIdentityStore(keychain: keychain)
        let first = try store.loadOrCreateIdentity()

        try store.deleteIdentity()
        #expect(!keychain.hasIdentity(
            service: SyncIdentityStore.keychainService,
            account: SyncIdentityStore.keychainAccount
        ))

        let regenerated = try store.loadOrCreateIdentity()
        #expect(regenerated != first)
    }

    @Test("deleteIdentity 幂等：无条目也成功")
    func deleteMissingIsIdempotent() throws {
        let store = SyncIdentityStore(keychain: MockKeychainStore())
        try store.deleteIdentity() // 不应抛
    }

    // MARK: - 错误路径

    @Test("Keychain 数据损坏 → invalidStoredKey（不静默换身份）")
    func corruptDataThrows() throws {
        let keychain = MockKeychainStore()
        try keychain.saveData(
            Data([1, 2, 3]),
            service: SyncIdentityStore.keychainService,
            account: SyncIdentityStore.keychainAccount
        )
        let store = SyncIdentityStore(keychain: keychain)

        #expect(throws: SyncIdentityError.invalidStoredKey) {
            _ = try store.loadOrCreateIdentity()
        }
        // 损坏数据未被静默覆盖
        #expect(keychain.hasIdentity(
            service: SyncIdentityStore.keychainService,
            account: SyncIdentityStore.keychainAccount
        ))
    }

    @Test("Keychain 读失败 → 错误透传为 SyncIdentityError.keychain")
    func loadFailurePropagates() throws {
        let keychain = MockKeychainStore()
        keychain.failLoad = true
        let store = SyncIdentityStore(keychain: keychain)

        #expect(throws: SyncIdentityError.keychain(.status(errSecNotAvailable))) {
            _ = try store.loadOrCreateIdentity()
        }
    }

    @Test("Keychain 写失败 → 错误透传（生成后落盘失败必须暴露）")
    func saveFailurePropagates() throws {
        let keychain = MockKeychainStore()
        keychain.failSave = true
        let store = SyncIdentityStore(keychain: keychain)

        #expect(throws: SyncIdentityError.keychain(.status(errSecNotAvailable))) {
            _ = try store.loadOrCreateIdentity()
        }
    }

    // MARK: - 密钥可用性

    @Test("签名密钥可用：privateKeyRaw 还原后 sign/verify 自检通过")
    func signingKeyRoundtripAndVerify() throws {
        let identity = try SyncIdentityStore(keychain: MockKeychainStore()).loadOrCreateIdentity()

        let signingKey = try identity.signingKey()
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKeyRaw)
        let message = Data("pairing-handshake".utf8)
        let signature = try signingKey.signature(for: message)

        #expect(publicKey.isValidSignature(signature, for: message))
        // 篡改消息必须验签失败
        let tampered = Data("pairing-handshak!".utf8)
        #expect(!publicKey.isValidSignature(signature, for: tampered))
    }

    @Test("持久化原始数据直接还原私钥（32B raw 语义）")
    func rawRepresentationRoundtrip() throws {
        let identity = SyncIdentity.generate()
        let restored = try SyncIdentity(privateKeyRaw: identity.privateKeyRaw)
        #expect(restored == identity)
        #expect(restored.publicKeyRaw == identity.publicKeyRaw)
    }

    @Test("非法私钥数据构造 SyncIdentity → invalidStoredKey")
    func invalidRawDataThrows() {
        #expect(throws: SyncIdentityError.invalidStoredKey) {
            _ = try SyncIdentity(privateKeyRaw: Data(repeating: 1, count: 16))
        }
        #expect(throws: SyncIdentityError.invalidStoredKey) {
            _ = try SyncIdentity(privateKeyRaw: Data())
        }
    }
}
