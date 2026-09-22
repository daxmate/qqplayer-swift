//
//  TrackDeletionReclaimAreaTests.swift
//  QQPlayerTests
//
//  批 E-2（2026-09-21）：iOS「只从曲库移除」的**落点变更** —— 库内文件移入应用回收区
//  （`<曲库根>/.Trash/<contentHash>.<ext>`），不再留在曲库根里。
//
//  为什么（背景）：iOS 用户删歌（设置 `deleteFromLibraryOnly` **默认 true**）时旧语义把文件
//  留在 `Documents/` 里 → 对端（Mac）manifest 仍按「文件在 + 指纹来自文件回落」把该文件当
//  「对端已有」→ 差集判「已一致」→ 该删的歌永远传不过去，UI 秒报完成而用户以为删掉了。
//  用户拍板：保留文件改为移入应用回收区（**不永久删除**，原件仍可恢复）。
//
//  本文件锁的事（全部 fail-closed：红=语义被改回去）：
//   1. 库内文件 + `libraryOnly == true` → 曲库根内该文件不存在、回收区有 `<contentHash>.<ext>`
//      且内容一致、DB 引用已删、计数正确（`movedToReclaim` / `excludedFromLibrary`）；
//   2. 库外文件 + `libraryOnly == true` → **原地不动**（旧语义回归保护：保护用户原件）；
//   3. `libraryOnly == false`（iOS 默认）→ **永久删除**（既有行为零变化）；
//   4. 同名冲突 → 追加 `-1` 后缀，两份都在回收区、内容各自一致；
//   5. 回收区文件**不进清单**：`SyncLocalLibraryScanner.sourceFiles`（manifest 输入）不含它
//      —— 靠「`.Trash` 是隐藏目录 + 扫描口径 `.skipsHiddenFiles`」，同时锁口径层
//      `MusicDirectoryScanner.audioFilesSync`；
//   6. `.Trash` 字面量只准出现在唯一入口文件（回收区路径的单一事实源）。
//
//  真实文件系统用例用**生产同款** `Environment.live`（真实 FileManager + 真实回收区移动
//  `DeleteReclaimArea.move`），只把「排除标记 / DB 引用删除」换成假实现（不碰
//  `DeleteSettings` / `DatabaseManager.shared` 的副作用）。指纹一律走既有入口
//  `DatabaseManager.contentHashIfFilePresent`——本文件不新写哈希实现。
//

import Foundation
import GRDB

import Testing

@testable import QQPlayer

// MARK: - 夹具

/// 假账本：只替换「排除标记 / DB 引用删除」两个副作用出口，其余（含真实回收区移动）走生产实现。
private final class ReclaimLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var excluded: [String] = []
    private var deleted: [String] = []
    private var logs: [String] = []

    /// 抛出错误的 stableId（DB 删除阶段）
    var deleteErrorStableIds: Set<String> = []

    func environment(libraryRoot: URL) -> TrackDeletionService.Environment {
        var environment = TrackDeletionService.Environment.live(log: { [self] message in
            lock.lock()
            logs.append(message)
            lock.unlock()
        }, libraryRoot: libraryRoot)
        environment.excludeFromLibrary = { [self] stableId in
            lock.lock()
            excluded.append(stableId)
            lock.unlock()
        }
        environment.deleteReference = { [self] stableId in
            lock.lock()
            let shouldThrow = deleteErrorStableIds.contains(stableId)
            if !shouldThrow { deleted.append(stableId) }
            lock.unlock()
            if shouldThrow { throw LedgerError.deleteFailed(stableId) }
        }
        return environment
    }

    var excludedIds: [String] { lock.lock(); defer { lock.unlock() }; return excluded }
    var deletedStableIds: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
    var logMessages: [String] { lock.lock(); defer { lock.unlock() }; return logs }

    enum LedgerError: Error { case deleteFailed(String) }
}

/// 临时曲库根（`root`）+ 回收区（`trash` = `DeleteReclaimArea.url(inLibraryRoot:)`）。
private struct ReclaimFixture {
    let root: URL
    let trash: URL

    init(tag: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-e2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url
        trash = DeleteReclaimArea.url(inLibraryRoot: url)
    }

    func write(_ relativePath: String, payload: Data) throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: file)
        return file
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 测试载荷（非空且可区分，防「空壳也算成功」的假绿）。
    static func payload(_ seed: UInt8) -> Data {
        Data((0 ..< 4096).map { UInt8(($0 &+ Int(seed)) % 251) })
    }
}

private func item(_ stableId: String, path: String) -> TrackDeletionService.Item {
    TrackDeletionService.Item(stableId: stableId, title: stableId, path: path)
}

// MARK: - 回收区落点（纯函数）

@Suite("应用回收区 · 落点与命名（纯函数）")
struct DeleteReclaimAreaPureTests {
    @Test("回收区 = 曲库根 + 隐藏目录名（目录名以 . 开头 = 扫描口径天然跳过它的根据）")
    func reclaimAreaDerivesFromLibraryRoot() {
        let root = URL(fileURLWithPath: "/library")
        let trash = DeleteReclaimArea.url(inLibraryRoot: root)

        #expect(trash.path == root.path + "/" + DeleteReclaimArea.directoryName)
        #expect(trash.lastPathComponent == DeleteReclaimArea.directoryName)
        #expect(trash.lastPathComponent.hasPrefix("."), "回收区必须是隐藏目录（否则会被扫回曲库）")
    }

    @Test("命名 = <contentHash>.<ext>（沿用容器既有口径 Documents/.Trash/<hex>.mp3）")
    func destinationUsesContentHashAndExtension() throws {
        let trash = DeleteReclaimArea.url(inLibraryRoot: URL(fileURLWithPath: "/library"))
        let destination = try DeleteReclaimArea.destinationURL(
            in: trash,
            contentHash: "abc123",
            pathExtension: "mp3",
            isTaken: { _ in false }
        )

        #expect(destination.lastPathComponent == "abc123.mp3")
        #expect(destination.deletingLastPathComponent().path == trash.path)
    }

    @Test("同名冲突 → 追加 -1 / -2 后缀（已占两个就落到第三个）")
    func destinationAppendsSuffixOnConflict() throws {
        let trash = DeleteReclaimArea.url(inLibraryRoot: URL(fileURLWithPath: "/library"))
        var taken: Set<String> = []
        func next() throws -> String {
            let url = try DeleteReclaimArea.destinationURL(
                in: trash,
                contentHash: "abc123",
                pathExtension: "mp3",
                isTaken: { taken.contains($0) }
            )
            taken.insert(url.path)
            return url.lastPathComponent
        }

        #expect(try next() == "abc123.mp3")
        #expect(try next() == "abc123-1.mp3")
        #expect(try next() == "abc123-2.mp3")
    }

    @Test("后缀用尽 → 抛错（不许静默覆盖已有文件）")
    func destinationFailsClosedWhenSuffixesExhausted() {
        let trash = DeleteReclaimArea.url(inLibraryRoot: URL(fileURLWithPath: "/library"))

        #expect(throws: DeleteReclaimArea.ReclaimError.self) {
            _ = try DeleteReclaimArea.destinationURL(
                in: trash,
                contentHash: "abc123",
                pathExtension: "mp3",
                isTaken: { _ in true }
            )
        }
    }

    @Test("在根内判定：根内 true / 根外 false / 恰为根本身 false")
    func containmentUsesSharedRelativePathEntry() {
        let root = URL(fileURLWithPath: "/library")

        #expect(DeleteReclaimArea.isInsideLibraryRoot("/library/song.mp3", libraryRoot: root))
        #expect(DeleteReclaimArea.isInsideLibraryRoot("/library/sub/dir/song.mp3", libraryRoot: root))
        #expect(!DeleteReclaimArea.isInsideLibraryRoot("/external/song.mp3", libraryRoot: root))
        #expect(!DeleteReclaimArea.isInsideLibraryRoot("/library-other/song.mp3", libraryRoot: root))
        #expect(!DeleteReclaimArea.isInsideLibraryRoot("/library", libraryRoot: root))
    }
}

// MARK: - 回收区落点（真实文件系统）

@Suite("应用回收区 · 真实文件系统上的删除落点")
struct TrackDeletionReclaimAreaTests {
    @Test("库内文件 + libraryOnly=true → 曲库根内不再有它、回收区有 <hash>.mp3 且内容一致")
    func libraryOnlyMovesLibraryFileIntoReclaimArea() throws {
        let fixture = try ReclaimFixture(tag: "reclaim-basic")
        defer { fixture.cleanUp() }

        let payload = ReclaimFixture.payload(7)
        let source = try fixture.write("song.mp3", payload: payload)
        // 期望文件名里的指纹 = 既有入口算出的同一个值（禁新写哈希实现）
        let expectedHash = try #require(DatabaseManager.contentHashIfFilePresent(atPath: source.path))

        let ledger = ReclaimLedger()
        let outcome = TrackDeletionService.delete(
            items: [item("stable-1", path: source.path)],
            policy: TrackDeletionService.Policy.ios(libraryOnly: true),
            environment: ledger.environment(libraryRoot: fixture.root)
        )

        #expect(outcome.deleted == 1)
        #expect(outcome.excludedFromLibrary == 1)
        #expect(outcome.movedToReclaim == 1)
        #expect(outcome.failed == 0)
        #expect(outcome.fileRemovalFailed == 0)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: source.path), "移走后曲库根内不得再留着它（对端差集才看得见）")
        let reclaimed = fixture.trash.appendingPathComponent("\(expectedHash).mp3")
        #expect(fm.fileExists(atPath: reclaimed.path), "回收区应有 <contentHash>.mp3：\(reclaimed.path)")
        #expect(try Data(contentsOf: reclaimed) == payload, "回收区文件内容必须与原件一致（不是空壳）")
        #expect(ledger.excludedIds == ["stable-1"])
        #expect(ledger.deletedStableIds == ["stable-1"])
    }

    @Test("库外文件 + libraryOnly=true → 原地不动、回收区都不建（旧语义回归保护）")
    func libraryOnlyLeavesOutsideFilesUntouched() throws {
        let fixture = try ReclaimFixture(tag: "reclaim-outside")
        defer { fixture.cleanUp() }
        // 库外目录（模拟设置页添加的外部文件夹 / 用户原件）
        let externalRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("qqp-e2-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let payload = ReclaimFixture.payload(11)
        let external = externalRoot.appendingPathComponent("outside.mp3")
        try payload.write(to: external)

        let ledger = ReclaimLedger()
        let outcome = TrackDeletionService.delete(
            items: [item("stable-out", path: external.path)],
            policy: TrackDeletionService.Policy.ios(libraryOnly: true),
            environment: ledger.environment(libraryRoot: fixture.root)
        )

        #expect(outcome.deleted == 1)
        #expect(outcome.excludedFromLibrary == 1)
        #expect(outcome.movedToReclaim == 0)
        #expect(outcome.failed == 0)
        #expect(FileManager.default.fileExists(atPath: external.path), "库外文件是用户原件，必须原地不动")
        #expect(!FileManager.default.fileExists(atPath: fixture.trash.path), "库外文件不该催生回收区目录")
        #expect(ledger.deletedStableIds == ["stable-out"])
    }

    @Test("libraryOnly=false（iOS 默认）→ 永久删除，且不产生回收区（既有行为零变化）")
    func libraryOnlyOffStillDeletesPermanently() throws {
        let fixture = try ReclaimFixture(tag: "reclaim-off")
        defer { fixture.cleanUp() }

        let source = try fixture.write("song.mp3", payload: ReclaimFixture.payload(13))
        let ledger = ReclaimLedger()
        let outcome = TrackDeletionService.delete(
            items: [item("stable-2", path: source.path)],
            policy: TrackDeletionService.Policy.ios(libraryOnly: false),
            environment: ledger.environment(libraryRoot: fixture.root)
        )

        #expect(outcome.deleted == 1)
        #expect(outcome.excludedFromLibrary == 0)
        #expect(outcome.movedToReclaim == 0)
        #expect(outcome.failed == 0)
        #expect(!FileManager.default.fileExists(atPath: source.path), "关闭开关 = 永久删除（旧行为）")
        #expect(!FileManager.default.fileExists(atPath: fixture.trash.path), "旧行为不产生回收区")
        #expect(ledger.deletedStableIds == ["stable-2"])
    }

    @Test("内容相同（指纹相同）→ 两份都进回收区：第二份追加 -1，内容各自一致")
    func sameHashFilesGetSuffixedNames() throws {
        let fixture = try ReclaimFixture(tag: "reclaim-conflict")
        defer { fixture.cleanUp() }

        let payload = ReclaimFixture.payload(17)
        let first = try fixture.write("a.mp3", payload: payload)
        let second = try fixture.write("b.mp3", payload: payload)
        let hash = try #require(DatabaseManager.contentHashIfFilePresent(atPath: first.path))
        let hashOfSecond = try #require(DatabaseManager.contentHashIfFilePresent(atPath: second.path))
        #expect(hash == hashOfSecond, "两份内容相同 → 指纹必须相同（否则本用例没锁到冲突路径）")

        let ledger = ReclaimLedger()
        let outcome = TrackDeletionService.delete(
            items: [item("stable-a", path: first.path), item("stable-b", path: second.path)],
            policy: TrackDeletionService.Policy.ios(libraryOnly: true),
            environment: ledger.environment(libraryRoot: fixture.root)
        )

        #expect(outcome.movedToReclaim == 2)
        #expect(outcome.deleted == 2)
        #expect(outcome.failed == 0)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: first.path))
        #expect(!fm.fileExists(atPath: second.path))
        let firstReclaim = fixture.trash.appendingPathComponent("\(hash).mp3")
        let secondReclaim = fixture.trash.appendingPathComponent("\(hash)-1.mp3")
        #expect(fm.fileExists(atPath: firstReclaim.path), "第一份应落在 <hash>.mp3")
        #expect(fm.fileExists(atPath: secondReclaim.path), "第二份应落在 <hash>-1.mp3（不许覆盖）")
        #expect(try Data(contentsOf: firstReclaim) == payload)
        #expect(try Data(contentsOf: secondReclaim) == payload)
    }

    @Test("DB 引用删除失败 → 文件已进回收区、曲目计入 failed（既有失败口径不变）")
    func referenceFailureStillCountsAsFailed() throws {
        let fixture = try ReclaimFixture(tag: "reclaim-dbfail")
        defer { fixture.cleanUp() }

        let source = try fixture.write("song.mp3", payload: ReclaimFixture.payload(19))
        let ledger = ReclaimLedger()
        ledger.deleteErrorStableIds = ["stable-3"]
        let outcome = TrackDeletionService.delete(
            items: [item("stable-3", path: source.path)],
            policy: TrackDeletionService.Policy.ios(libraryOnly: true),
            environment: ledger.environment(libraryRoot: fixture.root)
        )

        #expect(outcome.deleted == 0)
        #expect(outcome.failed == 1)
        #expect(outcome.fileRemovalFailed == 0, "这是 DB 失败，不是文件动作失败")
        #expect(outcome.excludedFromLibrary == 1)
        #expect(outcome.movedToReclaim == 1)
        #expect(ledger.deletedStableIds.isEmpty)
    }
}

// MARK: - 回收区不进清单

@Suite("应用回收区 · 回收区文件不进曲库/清单")
struct ReclaimAreaInvisibilityTests {
    @Test("合成曲库根（可见真文件 + 回收区内文件）→ 清单与扫描口径都不含回收区路径")
    func reclaimAreaFilesAreNotListed() throws {
        let fixture = try ReclaimFixture(tag: "reclaim-scan")
        defer { fixture.cleanUp() }

        let visible = try fixture.write("visible.mp3", payload: ReclaimFixture.payload(23))
        try FileManager.default.createDirectory(at: fixture.trash, withIntermediateDirectories: true)
        let reclaimed = fixture.trash.appendingPathComponent("deadbeef.mp3")
        try ReclaimFixture.payload(29).write(to: reclaimed)

        // ① 扫描口径层（扩展名显式给出，不受设置影响）：只该看到可见真文件
        let enumerated = try MusicDirectoryScanner.audioFilesSync(
            in: fixture.root,
            enabledExtensions: ["mp3"]
        ).map(\.lastPathComponent)
        #expect(enumerated == ["visible.mp3"], "回收区文件必须被跳过（否则会重新入库）")

        // ② manifest 输入层（与对端对账同一入口）
        let files = SyncLocalLibraryScanner.sourceFiles(
            in: fixture.root,
            database: DatabaseManager(dbWriter: try DatabaseQueue())
        )
        let relativePaths = files.map(\.relativePath)
        #expect(
            !relativePaths.contains { $0.contains(DeleteReclaimArea.directoryName) },
            "回收区路径不得进清单：\(relativePaths)"
        )
        if MusicDirectoryScanner.enabledExtensions(from: DeleteSettings.load()).contains("mp3") {
            #expect(
                relativePaths.contains("visible.mp3"),
                "可见真文件应在清单里（防本用例空转）：\(relativePaths)"
            )
        }
        #expect(FileManager.default.fileExists(atPath: visible.path))
        #expect(FileManager.default.fileExists(atPath: reclaimed.path), "回收区文件仍在磁盘（不是被删掉）")
    }
}

// MARK: - 唯一入口（回收区路径的单一事实源）

private enum ReclaimPathContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"
    /// 唯一允许出现回收区目录名字面量的文件（回收区路径的单一事实源）。
    ///
    /// 定案（maintainer 2026-09-22）：目录名的**唯一常量入口是 `LibraryRoot`**
    /// （`LibraryRoot.trashDirectoryName`，其文件头自写「目录名（唯一常量；别处不得再写字面量）」、
    /// 只依赖 Foundation、在小组件共享名单里），`DeleteReclaimArea.directoryName` 亦是**引用**它。
    /// 契约本意是「字面量只有一处」，不是「必须写在删除服务里」⇒ 白名单随之搬家。
    static let allowedPaths: Set<String> = ["QQPlayer/Services/LibraryRoot.swift"]
    /// 目标字面量（**由常量拼出**，本测试文件自己不留字面量）。
    static let literal = "\"" + DeleteReclaimArea.directoryName + "\""

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path): return "契约测试无法枚举目录（fail-closed）：\(path)"
            }
        }
    }

    /// 剥掉注释，**保留字符串字面量**（本契约判的正是字面量）。
    static func strippingComments(_ source: String) -> String {
        var output = ""
        let characters = Array(source)
        var index = 0
        var inLineComment = false
        var inBlockComment = false
        var inString = false

        while index < characters.count {
            let current = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if current == "\n" { inLineComment = false; output.append(current) }
                index += 1
                continue
            }
            if inBlockComment {
                if current == "*" && next == "/" { inBlockComment = false; index += 2; continue }
                index += 1
                continue
            }
            if inString {
                if current == "\\" {
                    if index + 1 < characters.count { output.append(characters[index + 1]) }
                    index += 2
                    continue
                }
                if current == "\"" { inString = false }
                output.append(current)
                index += 1
                continue
            }
            if current == "/" && next == "/" { inLineComment = true; index += 2; continue }
            if current == "/" && next == "*" { inBlockComment = true; index += 2; continue }
            if current == "\"" { inString = true; output.append(current); index += 1; continue }
            output.append(current)
            index += 1
        }
        return output
    }

    /// 出现回收区目录名字面量的生产文件（白名单之外 = 第二份落点实现）。
    static func offenders() throws -> [String] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        let prefix = repositoryRoot.path + "/"
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            guard !allowedPaths.contains(relative) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if strippingComments(source).contains(literal) {
                result.append(relative)
            }
        }
        return result.sorted()
    }
}

@Suite("应用回收区 · 路径唯一入口（形状契约）")
struct DeleteReclaimAreaShapeContractTests {
    @Test("回收区目录名字面量只准出现在唯一入口文件；白名单不许空转")
    func reclaimPathLiteralLivesInOnePlace() throws {
        let offenders = try ReclaimPathContract.offenders()
        #expect(
            offenders.isEmpty,
            """
            出现了第二处回收区落点（回收区路径必须只由 \
            DeleteReclaimArea.url(inLibraryRoot:) 派生）：\(offenders)
            """
        )

        // 白名单不空转：唯一入口必须真的是那个字面量的持有者（否则本契约在空跑）
        let entry = ReclaimPathContract.repositoryRoot
            .appendingPathComponent("QQPlayer/Services/LibraryRoot.swift")
        let entrySource = try String(contentsOf: entry, encoding: .utf8)
        #expect(
            ReclaimPathContract.strippingComments(entrySource).contains(ReclaimPathContract.literal),
            "唯一入口里找不到回收区目录名字面量（契约在空跑）"
        )
    }

    @Test("自证：剥注释后字面量仍被抓住，注释里的提及不算数")
    func detectionRuleSelfTest() {
        let literal = ReclaimPathContract.literal
        let codeUse = "static let directoryName = \(literal)"
        let commentUse = "// 曾经手拼过 \(literal) 路径\ndoThings()"
        let blockCommentUse = "/* \(literal) */\ndoThings()"

        let strippedCode = ReclaimPathContract.strippingComments(codeUse)
        let strippedComment = ReclaimPathContract.strippingComments(commentUse)
        let strippedBlockComment = ReclaimPathContract.strippingComments(blockCommentUse)

        #expect(strippedCode.contains(literal), "代码里的字面量必须被抓住")
        #expect(!strippedComment.contains(literal), "行注释里的提及不该算数")
        #expect(!strippedBlockComment.contains(literal), "块注释里的提及不该算数")
    }
}
