//
//  QuarkCookieStore.swift
//  QQPlayer
//
//  会话 cookie 持久化后端（系统钥匙串 / 明文文件测试后端）与旧版明文文件一次性迁移。
//  原 QuarkClient.swift「Cookie 持久化后端 / 明文文件迁移」段，纯移动：类型/函数/访问级别逐字未改。
//  安全性要点：凭据成功写入钥匙串后旧明文文件立即安全删除；写入失败保留旧文件降级可读。
//

import Foundation

/// 旧版明文 cookie 文件 → 系统安全存储的一次性迁移（与 QuarkClient 解耦，便于单测）。
/// 安全性要点：凭据一旦成功写入钥匙串，旧明文文件立即安全删除；
/// 写入失败时**保留**旧文件（降级可读，不静默丢登录态），错误描述带回给调用方记日志。
enum QuarkCookieMigration {
    enum Outcome: Equatable {
        /// 旧文件不存在，无需迁移
        case noLegacyFile
        /// 已迁入安全存储并删除明文文件（迁移项数）
        case migrated(Int)
        /// 安全存储已有凭据：仅清理残留明文文件
        case alreadyInStore
        /// 旧文件空/损坏：无凭据可迁，直接删除
        case discardedEmptyLegacy
        /// 写入安全存储失败：**保留**明文文件，带上错误描述
        case failed(String)
    }

    static func migrateIfNeeded(
        store: any QuarkCookieStoring,
        legacyFileURL: URL
    ) -> Outcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyFileURL.path) else { return .noLegacyFile }
        guard let data = try? Data(contentsOf: legacyFileURL),
              let jar = QuarkLogic.cookies(from: data), !jar.isEmpty else {
            // 旧文件为空/损坏：无凭据可迁
            removeFileSecurely(legacyFileURL)
            return .discardedEmptyLegacy
        }
        if (try? store.loadCookiesData()) != nil {
            // 安全存储已有凭据：旧明文文件已无用（残留 = 历史遗留）
            removeFileSecurely(legacyFileURL)
            return .alreadyInStore
        }
        guard let json = QuarkLogic.cookiesData(jar) else {
            return .failed("cookie 序列化失败")
        }
        do {
            try store.saveCookiesData(json)
            removeFileSecurely(legacyFileURL)
            return .migrated(jar.count)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// 安全删除明文文件：先用随机字节覆盖原长度（best-effort——APFS 写时复制下
    /// 不保证物理归零），再删除。任意步骤失败都只忽略，不影响主流程。
    static func removeFileSecurely(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
           let handle = try? FileHandle(forWritingTo: url) {
            var noise = Data(count: size)
            noise.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    _ = SecRandomCopyBytes(kSecRandomDefault, size, base)
                }
            }
            do {
                try handle.write(contentsOf: noise)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
        try? fileManager.removeItem(at: url)
    }
}

// MARK: - Cookie 持久化后端（明文文件 → 系统安全存储）

/// 会话 cookie 持久化抽象。生产走系统钥匙串（QuarkKeychainCookieStore）；
/// 测试注入文件后端（QuarkFileCookieStore）或故障桩，避免测试触碰真实钥匙串。
protocol QuarkCookieStoring: AnyObject {
    /// 读原始 cookie JSON；无条目返回 nil。抛错 = 系统异常（非「找不到」）。
    func loadCookiesData() throws -> Data?
    /// 写原始 cookie JSON（upsert 语义：已存在则整体替换）。
    func saveCookiesData(_ data: Data) throws
    /// 删条目；不存在视为成功（幂等）。
    func deleteCookies() throws
}

/// 钥匙串实现：复用同步身份同一套 Security 封装（SystemKeychainStore），
/// 条目 service "com.daxmate.qqplayer.quark" / account "cookies"。
/// 夸克会话 cookie 可读取用户网盘文件，与同步私钥同属凭据，一律不落明文盘。
final class QuarkKeychainCookieStore: QuarkCookieStoring {
    static let service = "com.daxmate.qqplayer.quark"
    static let account = "cookies"

    private let keychain: SystemKeychainStore

    init(keychain: SystemKeychainStore = SystemKeychainStore()) {
        self.keychain = keychain
    }

    func loadCookiesData() throws -> Data? {
        try keychain.loadData(service: Self.service, account: Self.account)
    }

    func saveCookiesData(_ data: Data) throws {
        try keychain.saveData(data, service: Self.service, account: Self.account)
    }

    func deleteCookies() throws {
        try keychain.deleteData(service: Self.service, account: Self.account)
    }
}

/// 文件实现：**仅供测试注入**（生产不再写明文 cookie 文件）。
/// 写入语义与旧行为一致（0600 + .tmp 原子替换），保证既有回归用例语义不变。
final class QuarkFileCookieStore: QuarkCookieStoring {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadCookiesData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func saveCookiesData(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // 旧实现：写同目录 .tmp → chmod 0600 → replace/move
        let tmpURL = directory.appendingPathComponent("quark_cookies.json.tmp")
        try data.write(to: tmpURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tmpURL.path
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tmpURL)
        } else {
            try fileManager.moveItem(at: tmpURL, to: fileURL)
        }
    }

    func deleteCookies() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
