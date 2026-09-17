//
//  LibraryImportOutcomeTests.swift
//  QQPlayerTests
//
//  反屎山 B1：导入结果语义（`ExternalImportOutcome`）单测。
//
//  背景：`processExternalFile -> Bool` 把 4 条不同路径压成同一个 `false`
//  （已在库 / 被排除 / 解析落库出错 / 指纹变了重解析），导入面板只能把 `false`
//  一律说成「already in library」——面板主动说谎，用户不会去重试。
//
//  这里逐条锁死真实分支的判定：
//    imported / updatedExisting / alreadyPresent / excluded /
//    failed(.unsupportedLocation) / failed(.processing)
//  并锁住旧 Bool 视图 = 「只有 .imported 才 true」（其余调用点行为零变化）。
//
//  库走 `DatabaseManager(dbWriter: try DatabaseQueue())` 内存库（`LibraryIndexer` 注入缝），
//  不碰真机 app 库；音频走 TestAudioFixtures 内嵌 fixture，无需资源打包。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct LibraryImportOutcomeTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 内存库 + 注入的 indexer（不碰 DatabaseManager.shared）。
    static func makeIndexer() throws -> (indexer: LibraryIndexer, manager: DatabaseManager) {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return (LibraryIndexer(databaseManager: manager), manager)
    }

    /// 临时目录里的真实 mp3 fixture（0.3s 静音，可被解析器读）。
    static func makeAudioFile(_ name: String) throws -> URL {
        try TestAudioFixtures.writeFixture(name, base64: TestAudioFixtures.mp3Empty, ext: "mp3")
    }

    /// 临时目录里的任意内容文件（造「假音频」用）。
    static func writeTempFile(_ name: String, ext: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryImportOutcomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(ext)")
        try data.write(to: url)
        return url
    }

    static func removeFixtureDir(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 去掉注释行后的「代码文本」：形状断言只看代码，不看注释里引用的旧文案。
    static func codeOnly(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func trackCount(_ manager: DatabaseManager) throws -> Int {
        try manager.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") } ?? -1
    }

    // MARK: - 四条真实路径

    @Test("新文件 → .imported，且真的落库（历史唯一返回 true 的路径）")
    func newFileIsImported() async throws {
        let (indexer, manager) = try Self.makeIndexer()
        let url = try Self.makeAudioFile("outcome-new")
        defer { Self.removeFixtureDir(of: url) }

        let outcome = await indexer.processExternalFileOutcome(url)
        #expect(outcome == .imported)
        #expect(await indexer.processExternalFile(url) == false) // 第二次进来就不是新入库了

        let stableId = try indexer.generateStableId(for: url)
        let stored = try manager.getTrack(byStableId: stableId)
        #expect(stored?.path == url.path)
    }

    @Test("已在库且元数据最新 → .alreadyPresent，且不重复入库")
    func alreadyPresentIsNotAReparse() async throws {
        let (indexer, manager) = try Self.makeIndexer()
        let url = try Self.makeAudioFile("outcome-present")
        defer { Self.removeFixtureDir(of: url) }

        #expect(await indexer.processExternalFileOutcome(url) == .imported)
        #expect(await indexer.processExternalFileOutcome(url) == .alreadyPresent)
        #expect(try Self.trackCount(manager) == 1)
    }

    @Test("指纹变了的老行重解析成功 → .updatedExisting（旧 Bool 也是 false，但它不是「已在库」）")
    func changedFileBecomesUpdatedExisting() async throws {
        let (indexer, manager) = try Self.makeIndexer()
        let url = try Self.makeAudioFile("outcome-updated")
        defer { Self.removeFixtureDir(of: url) }

        #expect(await indexer.processExternalFileOutcome(url) == .imported)
        // 抹掉指纹 = 「文件变了 / 老行没有指纹」，逼出重解析分支（同时避开封面刷新）
        try manager.write { db in
            try db.execute(sql: "UPDATE track SET modification_date = NULL")
        }

        #expect(await indexer.processExternalFileOutcome(url) == .updatedExisting)
        #expect(await indexer.processExternalFile(url) == false)
        #expect(try Self.trackCount(manager) == 1)
    }

    @Test("排除后未要求重导 → .excluded；allowExcludedReimport: true → .imported 并清排除")
    func excludedTrackIsReportedAsExcluded() async throws {
        let (indexer, manager) = try Self.makeIndexer()
        let url = try Self.makeAudioFile("outcome-excluded")
        defer { Self.removeFixtureDir(of: url) }

        let stableId = try indexer.generateStableId(for: url)
        #expect(await indexer.processExternalFileOutcome(url) == .imported)

        // 「仅从库中移除」的生产形状：删行 + 记排除
        try manager.write { db in
            try db.execute(sql: "DELETE FROM track WHERE stable_id = ?", arguments: [stableId])
        }
        DeleteSettings.addExcludedTrack(stableId)
        defer { DeleteSettings.removeExcludedTrack(stableId) }

        #expect(await indexer.processExternalFileOutcome(url) == .excluded)
        #expect(DeleteSettings.isTrackExcluded(stableId))
        #expect(await indexer.processExternalFile(url) == false)

        #expect(await indexer.processExternalFileOutcome(url, allowExcludedReimport: true) == .imported)
        #expect(DeleteSettings.isTrackExcluded(stableId) == false)
    }

    // MARK: - 失败（旧实现里和「已在库」共用同一个 false）

    @Test("网络 URL → .failed(.unsupportedLocation)，根本不进解析")
    func networkURLIsUnsupportedLocation() async throws {
        let (indexer, manager) = try Self.makeIndexer()
        let url = try #require(URL(string: "https://example.com/remote.mp3"))

        #expect(await indexer.processExternalFileOutcome(url) == .failed(.unsupportedLocation))
        #expect(await indexer.processExternalFile(url) == false)
        #expect(try Self.trackCount(manager) == 0)
    }

    @Test("解析/落库出错 → .failed(.processing)，且不落库")
    func parseFailureIsReportedAsFailed() async throws {
        let (indexer, manager) = try Self.makeIndexer()

        // ① 解析器不认的格式：AudioMetadataParser 对未知扩展名直接 throw
        //    （注意不能用「文本改名为 .mp3」——AVFoundation 对垃圾内容不报错，会当成空元数据收下）
        let unsupported = try Self.writeTempFile("notes", ext: "txt", data: Data("普通文本".utf8))
        defer { Self.removeFixtureDir(of: unsupported) }
        #expect(await indexer.processExternalFileOutcome(unsupported) == .failed(.processing))

        // ② 文件不存在 → 读指纹就抛错，同样归 .processing
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mp3")
        #expect(await indexer.processExternalFileOutcome(missing) == .failed(.processing))

        // 两种「失败」都不许写进曲库
        #expect(try Self.trackCount(manager) == 0)
    }

    // MARK: - 形状契约（防「第二处判定」）

    @Test("形状：Bool 视图是薄包装，判定只有一处（唯一入口）")
    func boolViewIsThinWrapper() throws {
        let url = Self.repoRoot.appendingPathComponent("QQPlayer/Services/LibraryIndexer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.components(separatedBy: "func processExternalFileOutcome(").count - 1 == 1)
        #expect(source.components(separatedBy: "func processExternalFile(").count - 1 == 1)

        // 包装体内不许再长出分支（一旦复述判定逻辑，这里先红）
        let start = try #require(source.range(of: "func processExternalFile(_ fileURL"))
        let wrapperBody = Self.codeOnly(String(source[start.upperBound...].prefix(400)))
        #expect(wrapperBody.contains("processExternalFileOutcome("))
        #expect(!wrapperBody.contains("return true"))
        #expect(!wrapperBody.contains("return false"))
    }

    @Test("形状：导入面板消费唯一入口，不再有硬编码英文 toast")
    func panelConsumesOutcomeEntryPoint() throws {
        let url = Self.repoRoot.appendingPathComponent("QQPlayer/Views/Library/LibraryView.swift")
        let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))

        #expect(code.contains("processExternalFileOutcome("))
        #expect(!code.contains("already in library"))
        #expect(!code.contains("songs imported"))
    }
}
