//
//  SyncIdentity.swift
//  QQPlayer
//
//  局域网同步（S2, M1）本端长期身份：Ed25519 密钥对（CryptoKit
//  Curve25519.Signing.PrivateKey）+ Keychain 持久化（kSecClassGenericPassword）。
//
//  - 首次调用生成密钥对并写入 Keychain，之后加载（重装/换机 = 新身份）
//  - Device ID = 公钥指纹（DeviceID.make）；私钥永不出设备
//  - Keychain 操作走可注入协议 SyncKeychainStoring：逻辑与系统 IO 解耦，
//    单测用内存 mock 覆盖（Keychain 真机行为由 M6 真机验收覆盖）
//
//  Keychain 条目：service "com.daxmate.qqplayer.sync" / account "identity"，
//  存 Curve25519 私钥 raw（32B，CryptoKit rawRepresentation）。
//

import CryptoKit
import Foundation
import Security

// MARK: - Keychain 抽象（可注入）

/// Keychain 底层读写抽象（kSecClassGenericPassword 封装）。
/// 协议可注入：生产用 SystemKeychainStore（Security 框架），测试用内存 mock。
protocol SyncKeychainStoring: Sendable {
    /// 读条目；不存在返回 nil。抛错 = 系统异常（非"找不到"）。
    func loadData(service: String, account: String) throws -> Data?
    /// 写条目（upsert 语义：已存在则覆盖）。
    func saveData(_ data: Data, service: String, account: String) throws
    /// 删条目；不存在视为成功（幂等）。
    func deleteData(service: String, account: String) throws
}

/// Security 框架实现。错误以 OSStatus 透传（errSecItemNotFound 由
/// loadData 转译为 nil、deleteData 转译为幂等成功）。
struct SystemKeychainStore: SyncKeychainStoring {
    func loadData(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SyncKeychainError.status(status)
        }
    }

    func saveData(_ data: Data, service: String, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // upsert：先删后加（keychain 无原子 upsert；两步均幂等）
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SyncKeychainError.status(status)
        }
    }

    func deleteData(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncKeychainError.status(status)
        }
    }
}

/// Keychain 层错误（OSStatus 透传；见 SystemKeychainStore）
enum SyncKeychainError: Error, Equatable {
    case status(OSStatus)
}

// MARK: - 身份（密钥对值类型 + 存取）

/// 本端长期身份错误。
enum SyncIdentityError: Error, Equatable {
    /// Keychain 数据损坏/非法（无法构成 Ed25519 私钥）。不静默重建：
    /// 换身份 = 换 Device ID，必须显式处理（删除后重建）。
    case invalidStoredKey
    /// Keychain 读写失败（透传底层错误）。
    case keychain(SyncKeychainError)
}

/// 本端身份密钥对（值类型，可相等比较/跨线程传递）。
struct SyncIdentity: Equatable, Sendable {
    /// Ed25519 私钥 raw（32B，CryptoKit rawRepresentation；持久化形态）
    let privateKeyRaw: Data
    /// 派生公钥 raw（32B；缓存避免每次构造 CryptoKit 对象）
    let publicKeyRaw: Data

    /// 由持久化私钥 raw 还原身份；数据非法抛 invalidStoredKey。
    init(privateKeyRaw: Data) throws {
        guard privateKeyRaw.count == 32 else {
            throw SyncIdentityError.invalidStoredKey
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        self.privateKeyRaw = privateKeyRaw
        publicKeyRaw = key.publicKey.rawRepresentation
    }

    /// 生成全新密钥对（首次启动路径）。
    static func generate() -> SyncIdentity {
        // 32B raw 恒合法，init 不可能抛
        // swiftlint:disable:next force_try
        try! SyncIdentity(privateKeyRaw: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    /// 签名用私钥（M2 对 sessionNonce 签名 / TLS 身份用）。
    func signingKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    }

    /// 本端 Device ID（全量；公钥恒 32B，make 不可能失败）。
    var deviceID: String {
        DeviceID.make(fromPublicKeyData: publicKeyRaw)!
    }
}

/// 身份存取（加载/生成/持久化/删除）。
final class SyncIdentityStore: Sendable {
    /// Keychain service（条目分组标识）
    static let keychainService = "com.daxmate.qqplayer.sync"
    /// Keychain account（身份条目名；未来更多同步密钥可并列存于此 service 下）
    static let keychainAccount = "identity"

    private let keychain: any SyncKeychainStoring

    init(keychain: any SyncKeychainStoring = SystemKeychainStore()) {
        self.keychain = keychain
    }

    /// 加载现有身份；无则生成并持久化。数据损坏抛 invalidStoredKey
    /// （调用方决定删除重建，避免静默换 ID 造成已配对端失配）。
    func loadOrCreateIdentity() throws -> SyncIdentity {
        let stored = try loadStoredData()
        if let stored {
            return try SyncIdentity(privateKeyRaw: stored)
        }
        let identity = SyncIdentity.generate()
        do {
            try keychain.saveData(
                identity.privateKeyRaw,
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch let error as SyncKeychainError {
            throw SyncIdentityError.keychain(error)
        }
        return identity
    }

    /// 删除本端身份（测试/重置/换身份用）。不存在视为成功。
    func deleteIdentity() throws {
        do {
            try keychain.deleteData(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch let error as SyncKeychainError {
            throw SyncIdentityError.keychain(error)
        }
    }

    private func loadStoredData() throws -> Data? {
        do {
            return try keychain.loadData(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch let error as SyncKeychainError {
            throw SyncIdentityError.keychain(error)
        }
    }
}
