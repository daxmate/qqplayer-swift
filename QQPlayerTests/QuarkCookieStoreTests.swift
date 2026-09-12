//
//  QuarkCookieStoreTests.swift
//  QQPlayerTests
//
//  夸克会话凭据存储（审计 2026-09-12 🟡-5）防回归：
//  旧版把会话 cookie 明文写 Application Support/QQPlayerMac/quark_cookies.json；
//  现改为系统钥匙串（QuarkKeychainCookieStore），并一次性迁移旧明文文件。
//
//  覆盖：
//  ① QuarkCookieStoring 协议实现：文件后端（测试注入）round-trip / 缺失返回 nil /
//     0600 权限 / 删除幂等
//  ② QuarkCookieMigration.Outcome 全分支：无旧文件 / 成功迁移（旧文件被安全删除）/
//     钥匙串已有凭据（清理残留明文）/ 旧文件空或损坏 / 写入失败（保留明文降级可读）
//  ③ 安全删除：明文文件内容被覆盖后移除，磁盘上不再有原凭据
//  ④ 钥匙串条目常量（service/account）锁定——防止后续改动悄悄换键
//
//  隔离说明：不触碰真实钥匙串（Security 框架真实 IO 由真机验收覆盖，与
//  SyncIdentityTests 同一约定）；文件后端只写临时目录。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 测试用存储后端

/// 内存后端（模拟钥匙串条目），可注入故障。
private final class MemoryCookieStore: QuarkCookieStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?
    var failSave = false
    var failLoad = false

    init(initial: Data? = nil) {
        storage = initial
    }

    var current: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func loadCookiesData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if failLoad { throw QuarkClientError.invalidResponse }
        return storage
    }

    func saveCookiesData(_ data: Data) throws {
        if failSave { throw QuarkClientError.invalidResponse }
        lock.lock()
        defer { lock.unlock() }
        storage = data
    }

    func deleteCookies() throws {
        lock.lock()
        defer { lock.unlock() }
        storage = nil
    }
}

// MARK: - 用例

@Suite(.serialized)
struct QuarkCookieStoreTests {
    // MARK: - 临时目录基建

    private static func makeTempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-store-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func writeLegacyFile(_ url: URL, cookies: [String: String]) throws {
        guard let data = QuarkLogic.cookiesData(cookies) else {
            throw QuarkClientError.invalidResponse
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    // MARK: - ① 文件后端（测试注入）语义与旧实现一致

    @Test("QuarkFileCookieStore：round-trip；缺失返回 nil；删除幂等")
    func fileStoreRoundTrip() throws {
        let dir = Self.makeTempDir("roundtrip")
        let url = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuarkFileCookieStore(fileURL: url)

        #expect(try store.loadCookiesData() == nil, "文件不存在 → nil")

        let cookies = ["pan_us": "abc", "__puus": "xyz"]
        try store.saveCookiesData(try #require(QuarkLogic.cookiesData(cookies)))

        let loaded = try #require(try store.loadCookiesData())
        #expect(QuarkLogic.cookies(from: loaded) == cookies)

        // 0600：凭据不回落到组/其他可读
        let perms = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(perms.intValue == 0o600, "明文文件也必须是 0600")

        try store.deleteCookies()
        #expect(try store.loadCookiesData() == nil)
        try store.deleteCookies() // 幂等：不存在不抛
    }

    @Test("QuarkFileCookieStore：原子写不留 .tmp 残留")
    func fileStoreLeavesNoTmp() throws {
        let dir = Self.makeTempDir("notmp")
        let url = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuarkFileCookieStore(fileURL: url)

        try store.saveCookiesData(try #require(QuarkLogic.cookiesData(["a": "1"])))
        try store.saveCookiesData(try #require(QuarkLogic.cookiesData(["a": "2"])))

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!left.contains("quark_cookies.json.tmp"), "不应残留 tmp 文件")
        let loaded = try #require(try store.loadCookiesData())
        #expect(QuarkLogic.cookies(from: loaded) == ["a": "2"], "后写覆盖前写")
    }

    // MARK: - ② 迁移全分支

    @Test("迁移：无旧明文文件 → noLegacyFile，不碰存储")
    func migrationNoLegacyFile() {
        let dir = Self.makeTempDir("nolegacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryCookieStore()

        let outcome = QuarkCookieMigration.migrateIfNeeded(
            store: store, legacyFileURL: dir.appendingPathComponent("quark_cookies.json")
        )
        #expect(outcome == .noLegacyFile)
        #expect(store.current == nil)
    }

    @Test("迁移：旧明文文件 → 写入钥匙串后端 + 删除明文文件（凭据不再落盘）")
    func migrationMovesCredentialsToStore() throws {
        let dir = Self.makeTempDir("migrate")
        let legacy = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cookies = ["pan_us": "abc123", "__puus": "puus-value"]
        try Self.writeLegacyFile(legacy, cookies: cookies)
        let store = MemoryCookieStore()

        let outcome = QuarkCookieMigration.migrateIfNeeded(store: store, legacyFileURL: legacy)

        #expect(outcome == .migrated(cookies.count))
        let stored = try #require(store.current)
        #expect(QuarkLogic.cookies(from: stored) == cookies, "凭据完整迁入")
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "明文文件必须被删掉")
    }

    @Test("迁移：钥匙串已有凭据 → 仅清理残留明文，不覆盖新凭据")
    func migrationKeepsStoreWhenAlreadyPresent() throws {
        let dir = Self.makeTempDir("already")
        let legacy = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeLegacyFile(legacy, cookies: ["old": "stale"])
        let fresh = try #require(QuarkLogic.cookiesData(["new": "value"]))
        let store = MemoryCookieStore(initial: fresh)

        let outcome = QuarkCookieMigration.migrateIfNeeded(store: store, legacyFileURL: legacy)

        #expect(outcome == .alreadyInStore)
        #expect(QuarkLogic.cookies(from: try #require(store.current)) == ["new": "value"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "残留明文必须清掉")
    }

    @Test("迁移：旧文件损坏/空 → 无可迁移凭据，直接删除")
    func migrationDiscardsCorruptLegacy() throws {
        let dir = Self.makeTempDir("corrupt")
        let legacy = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{{{{ not json".utf8).write(to: legacy)
        let store = MemoryCookieStore()

        let outcome = QuarkCookieMigration.migrateIfNeeded(store: store, legacyFileURL: legacy)
        #expect(outcome == .discardedEmptyLegacy)
        #expect(store.current == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("迁移：钥匙串写入失败 → failed + 明文文件保留（降级可读，不丢登录态）")
    func migrationKeepsLegacyFileWhenStoreFails() throws {
        let dir = Self.makeTempDir("fail")
        let legacy = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cookies = ["pan_us": "abc123"]
        try Self.writeLegacyFile(legacy, cookies: cookies)
        let store = MemoryCookieStore()
        store.failSave = true

        let outcome = QuarkCookieMigration.migrateIfNeeded(store: store, legacyFileURL: legacy)

        guard case .failed = outcome else {
            Issue.record("期望 .failed，实际 \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: legacy.path), "写入失败必须保留明文文件")
        let raw = try Data(contentsOf: legacy)
        #expect(QuarkLogic.cookies(from: raw) == cookies, "保留文件内容仍可用（降级可读）")
    }

    // MARK: - ③ 安全删除

    @Test("removeFileSecurely：覆盖后删除，磁盘不再有原凭据")
    func secureRemoveWipesContent() throws {
        let dir = Self.makeTempDir("secure")
        let legacy = dir.appendingPathComponent("quark_cookies.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeLegacyFile(legacy, cookies: ["pan_us": "secret-value"])

        QuarkCookieMigration.removeFileSecurely(legacy)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // 删除后再读必然失败；且不留 .tmp/备份副本
        #expect((try? Data(contentsOf: legacy)) == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty, "临时目录不应残留任何副本，实际：\(left)")
    }

    @Test("removeFileSecurely：文件不存在时幂等不抛")
    func secureRemoveMissingIsNoop() {
        let dir = Self.makeTempDir("secure-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        QuarkCookieMigration.removeFileSecurely(dir.appendingPathComponent("nope.json"))
    }

    // MARK: - ④ 钥匙串条目常量锁定

    @Test("钥匙串条目常量：service/account 与实现约定一致（改动需同步迁移）")
    func keychainConstantsAreStable() {
        #expect(QuarkKeychainCookieStore.service == "com.daxmate.qqplayer.quark")
        #expect(QuarkKeychainCookieStore.account == "cookies")
        // 与同步身份私钥同属凭据，但键空间必须相互独立（不得复用 identity 条目）
        #expect(QuarkKeychainCookieStore.account != "identity")
    }
}
