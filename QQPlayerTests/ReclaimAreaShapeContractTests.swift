//
//  ReclaimAreaShapeContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-09-29 回收区管理批，fail-closed + 自证 + 反向验证）。
//
//  三条契约（任务包 §4F）：
//   1. **恢复与清空各只有一个入口** —— 全仓里「搬运回收区条目」的调用点只允许出现在
//      `ReclaimRestoreService.swift`；「删除回收区条目」只允许出现在
//      `ReclaimPurgeService.swift`。新增文件带这类调用而不登记 → 红。
//   2. **两端都装配** —— iOS 设置页与 macOS 设置页各自接上自己的视图，且两个视图
//      消费**同一套 Services**（不复制业务判定）；界面的两个破坏性动作都走二次确认。
//   3. **回收区目录不进曲库扫描** —— 行为断言：`MusicDirectoryScanner` 不收录
//      `<曲库根>/.Trash` 里的音频（否则恢复/删除的文件会被当曲目重新收录）。
//
//  口径：先剥注释与字符串字面量再匹配（与 `TrackDeletionShapeContractTests` /
//  `TrackFileRenameServiceContractTests` 同款；不剥的话注释里写一句就骗绿）。
//  白名单：`QQPlayerTests/Fixtures/reclaim-area-shape.tsv`（`路径<TAB>模式`）。
//

import Foundation
import Testing

@testable import QQPlayer

private enum ReclaimShapeContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"
    static let whitelistPath = "QQPlayerTests/Fixtures/reclaim-area-shape.tsv"

    /// 两个唯一入口文件的路径。
    static let restoreEntryPath = "QQPlayer/Services/ReclaimRestoreService.swift"
    static let purgeEntryPath = "QQPlayer/Services/ReclaimPurgeService.swift"

    /// 恢复入口必须真的复用唯一收录入口 + 规范名渲染（防第二实现）。
    static let restoreEntryRequiredMarkers = [
        "processExternalFileOutcome",
        "allowExcludedReimport: true",
        "LibraryFileNaming.canonicalFileName",
    ]
    /// 恢复入口**不得**引用标签写入服务（会重写字节 ⇒ 改 `content_hash`）。
    static let restoreEntryForbiddenMarker = "TagWriterService"
    /// 清空入口**不得**碰曲目库引用（回收区文件本来就不在库里）。
    static let purgeEntryForbiddenMarker = "deleteTrack("

    /// 两端装配：平台 → 各自入口文件 / 入口标记 / 视图文件（`@Environment(LibraryIndexer.self)`
    /// 的装配由 `EnvironmentInjectionContractTests` 兜底）。
    static let platformWiring: [(platform: String, entry: String, marker: String, view: String)] = [
        (
            "iOS",
            "QQPlayer/Views/Utility/SettingsView.swift",
            "ReclaimAreaView()",
            "QQPlayer/Views/Library/ReclaimAreaView.swift"
        ),
        (
            "macOS",
            "QQPlayer/Mac/MacLibrarySettingsView.swift",
            "MacReclaimAreaView()",
            "QQPlayer/Mac/MacReclaimAreaView.swift"
        ),
    ]

    /// 两个平台视图都必须满足的东西（**代码**域：共享同一套 Services + 破坏性动作二次确认）。
    /// ⚠️ 本地化 key 是**字符串字面量**，剥注释/字符串后就不在了 → 另用源码域判据（下方）。
    static let requiredViewCodeMarkers = [
        "ReclaimAreaCatalog",
        "ReclaimRestoreService",
        "ReclaimPurgeService",
        "role: .destructive",
    ]

    /// 源码域（含字符串）：两个破坏性动作都必须有二次确认文案入口。
    static let requiredViewSourceMarkers = [
        "reclaim_purge_confirm_message",
        "reclaim_purge_all_confirm_message",
        "reclaim_purge_all",
    ]

    enum Pattern: String, CaseIterable {
        /// 搬运回收区条目（恢复）：代码域里既出现 entry 模型，又出现文件搬迁调用。
        case reclaimRestore = "reclaim-restore"
        /// 删除回收区条目（彻底删除 / 清空）。
        case reclaimPurge = "reclaim-purge"

        func isHit(in code: String) -> Bool {
            guard code.contains("ReclaimAreaEntry") else { return false }
            switch self {
            case .reclaimRestore: return code.contains(".moveItem(")
            case .reclaimPurge: return code.contains(".removeItem(")
            }
        }
    }

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case whitelistUnreadable(String)
        case whitelistMalformed(String)
        case fileUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举目录（fail-closed）：\(path)"
            case .whitelistUnreadable(let path):
                return "契约测试读不到白名单（fail-closed）：\(path)"
            case .whitelistMalformed(let line):
                return "白名单格式错误（应为 `路径<TAB>模式`）：\(line)"
            case .fileUnreadable(let path):
                return "契约测试读不到文件（fail-closed）：\(path)"
            }
        }
    }

    /// 剥掉行注释 / 块注释 / 字符串字面量——只留**代码**参与判定。
    static func codeOnly(_ source: String) -> String {
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
                if current == "\\" { index += 2; continue }
                if current == "\"" { inString = false }
                index += 1
                continue
            }
            if current == "/" && next == "/" { inLineComment = true; index += 2; continue }
            if current == "/" && next == "*" { inBlockComment = true; index += 2; continue }
            if current == "\"" { inString = true; output.append(" "); index += 1; continue }
            output.append(current)
            index += 1
        }
        return output
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    static func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(relativeDirectory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func source(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.fileUnreadable(relativePath)
        }
        return text
    }

    /// 实际检测结果：模式 → 命中的文件（相对路径，排序）。
    static func detectedHits() throws -> [Pattern: [String]] {
        var result: [Pattern: [String]] = [:]
        let prefix = repositoryRoot.path + "/"
        for url in try swiftFiles(under: scannedDirectory) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let code = codeOnly(source)
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            for pattern in Pattern.allCases where pattern.isHit(in: code) {
                result[pattern, default: []].append(relative)
            }
        }
        return result
    }

    /// 白名单：模式 → 允许的文件集合。
    static func whitelist() throws -> [Pattern: Set<String>] {
        let url = repositoryRoot.appendingPathComponent(whitelistPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.whitelistUnreadable(whitelistPath)
        }
        var result: [Pattern: Set<String>] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { throw ContractError.whitelistMalformed(line) }
            let path = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let patterns = parts[1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for name in patterns {
                guard let pattern = Pattern(rawValue: name) else {
                    throw ContractError.whitelistMalformed(line)
                }
                result[pattern, default: []].insert(path)
            }
        }
        return result
    }
}

@Suite("回收区管理形状契约（恢复/清空唯一入口 + 两端装配 + 扫描排除）")
struct ReclaimAreaShapeContractTests {
    @Test("(1) 恢复与清空的文件动作只允许出现在各自唯一入口文件里")
    func fileActionsAreConfinedToTheirSingleEntries() throws {
        let hits = try ReclaimShapeContract.detectedHits()
        let allowed = try ReclaimShapeContract.whitelist()

        var violations: [String] = []
        for pattern in ReclaimShapeContract.Pattern.allCases {
            let permitted = allowed[pattern] ?? []
            for file in hits[pattern] ?? [] where !permitted.contains(file) {
                violations.append("\(pattern.rawValue): \(file)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            出现了第二份「回收区恢复/清空」实现（必须只走 ReclaimRestoreService / \
            ReclaimPurgeService，见 QQPlayer/Services/Reclaim*.swift）：\(violations)
            """
        )

        // 入口必须在位（否则上面的「无违规」是空转绿）
        #expect(
            (hits[.reclaimRestore] ?? []).contains(ReclaimShapeContract.restoreEntryPath),
            "恢复唯一入口没被扫描到命中（扫描范围/剥注释逻辑坏了 = 契约静默失效）"
        )
        #expect(
            (hits[.reclaimPurge] ?? []).contains(ReclaimShapeContract.purgeEntryPath),
            "清空唯一入口没被扫描到命中（契约静默失效）"
        )
    }

    @Test("(1c) 白名单不空转也不腐烂")
    func whitelistIsRealAndNotStale() throws {
        let hits = try ReclaimShapeContract.detectedHits()
        let allowed = try ReclaimShapeContract.whitelist()

        #expect(!allowed.isEmpty, "白名单读成空表（fail-closed）：\(ReclaimShapeContract.whitelistPath)")

        for pattern in ReclaimShapeContract.Pattern.allCases {
            let permitted = allowed[pattern] ?? []
            #expect(!permitted.isEmpty, "模式 \(pattern.rawValue) 在白名单里没有任何允许项")
            for file in permitted.sorted() {
                let url = ReclaimShapeContract.repositoryRoot.appendingPathComponent(file)
                #expect(
                    FileManager.default.fileExists(atPath: url.path),
                    "白名单里的文件不存在，请删行/改名：\(file)"
                )
                #expect(
                    (hits[pattern] ?? []).contains(file),
                    "白名单里的 \(file) 已不再命中 \(pattern.rawValue)，请删行（名单不许空转）"
                )
            }
        }
    }

    @Test("(1d) 恢复入口复用唯一收录入口与规范名渲染；不得引用标签写入；清空不碰 DB 引用")
    func entriesReuseTheSingleSourcesOfTruth() throws {
        let restoreCode = ReclaimShapeContract.codeOnly(
            try ReclaimShapeContract.source(ReclaimShapeContract.restoreEntryPath)
        )
        for marker in ReclaimShapeContract.restoreEntryRequiredMarkers {
            #expect(
                restoreCode.contains(marker),
                "恢复入口必须复用唯一入口/规范名渲染（缺 `\(marker)`）"
            )
        }
        #expect(
            !restoreCode.contains(ReclaimShapeContract.restoreEntryForbiddenMarker),
            "恢复入口不得引用 \(ReclaimShapeContract.restoreEntryForbiddenMarker)（会重写标签字节 ⇒ 改 content_hash）"
        )

        let purgeCode = ReclaimShapeContract.codeOnly(
            try ReclaimShapeContract.source(ReclaimShapeContract.purgeEntryPath)
        )
        #expect(
            !purgeCode.contains(ReclaimShapeContract.purgeEntryForbiddenMarker),
            "清空入口不得删除曲目库引用（回收区文件不在库里）"
        )
    }

    @Test("(2) 两端都装配：各自设置页接上自己的视图，视图共享同一套 Services + 二次确认")
    func bothPlatformsAreWired() throws {
        for wiring in ReclaimShapeContract.platformWiring {
            let entrySource = try ReclaimShapeContract.source(wiring.entry)
            #expect(
                ReclaimShapeContract.codeOnly(entrySource).contains(wiring.marker),
                "\(wiring.platform) 设置页没有接上回收区界面（缺 `\(wiring.marker)`）：\(wiring.entry)"
            )
            let viewSource = try ReclaimShapeContract.source(wiring.view)
            let viewCode = ReclaimShapeContract.codeOnly(viewSource)
            for marker in ReclaimShapeContract.requiredViewCodeMarkers {
                #expect(
                    viewCode.contains(marker),
                    "\(wiring.platform) 视图缺 `\(marker)`（共享同一套 Services / 破坏性动作）：\(wiring.view)"
                )
            }
            for marker in ReclaimShapeContract.requiredViewSourceMarkers {
                #expect(
                    viewSource.contains(marker),
                    "\(wiring.platform) 视图缺二次确认文案入口 `\(marker)`：\(wiring.view)"
                )
            }
        }
    }

    @Test("(3) 回收区目录不进曲库扫描（含正向对照，防空转绿）")
    func reclaimDirectoryIsNotScanned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 正常曲目（正向对照：扫描器必须能看到它，否则下面的断言空转）
        let visible = root.appendingPathComponent("song.mp3", isDirectory: false)
        try Data("a".utf8).write(to: visible)

        // 回收区里的音频（必须不被收录）
        let area = DeleteReclaimArea.url(inLibraryRoot: root)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let trashed = area.appendingPathComponent("deadbeef.mp3", isDirectory: false)
        try Data("b".utf8).write(to: trashed)

        let enabled = LibraryAudioFormats.defaultEnabled
        let scanned = try MusicDirectoryScanner.audioFilesSync(
            in: root,
            enabledExtensions: enabled,
            recursive: true
        )
        let names = scanned.map(\.lastPathComponent)
        #expect(names.contains("song.mp3"), "正向对照失败：扫描器连正常曲目都没收录（判据坏了）")
        #expect(!names.contains("deadbeef.mp3"), "回收区（`.Trash`）里的音频不得进曲库扫描")

        // 单层扫描（iOS 曲库根口径）同样不得收录
        let shallow = try MusicDirectoryScanner.audioFilesSync(
            in: root,
            enabledExtensions: enabled,
            recursive: false
        )
        #expect(!shallow.map(\.lastPathComponent).contains("deadbeef.mp3"))
    }

    @Test("自证：剥注释/字符串后，注释里的「第二实现」不算数")
    func detectionRuleSelfTest() {
        let commented = """
        import Foundation
        // 曾经：try FileManager.default.moveItem(at: entry.url, to: target) // ReclaimAreaEntry
        /* try FileManager.default.removeItem(at: entry.url) */
        enum Legacy { static let note = "ReclaimAreaEntry moveItem( 已移除" }
        """
        let code = ReclaimShapeContract.codeOnly(commented)
        #expect(!ReclaimShapeContract.Pattern.reclaimRestore.isHit(in: code))
        #expect(!ReclaimShapeContract.Pattern.reclaimPurge.isHit(in: code))

        let secondImplementation = """
        import Foundation
        enum SneakyReclaim {
            static func move(entry: ReclaimAreaEntry, to target: URL) throws {
                try FileManager.default.moveItem(at: entry.url, to: target)
            }
        }
        """
        let sneaky = ReclaimShapeContract.codeOnly(secondImplementation)
        #expect(ReclaimShapeContract.Pattern.reclaimRestore.isHit(in: sneaky))
        #expect(!ReclaimShapeContract.Pattern.reclaimPurge.isHit(in: sneaky))

        // `.removeItem(` 里**不得**把 `.moveItem(` 判成命中（子串陷阱）
        let purgeOnly = """
        import Foundation
        enum PurgeOnly {
            static func wipe(_ entry: ReclaimAreaEntry) throws {
                try FileManager.default.removeItem(at: entry.url)
            }
        }
        """
        let purgeCode = ReclaimShapeContract.codeOnly(purgeOnly)
        #expect(ReclaimShapeContract.Pattern.reclaimPurge.isHit(in: purgeCode))
        #expect(!ReclaimShapeContract.Pattern.reclaimRestore.isHit(in: purgeCode), "`.removeItem(` 不得误命中 restore")

        // 只删缓存、不碰回收区条目的清理不该被误判
        let unrelated = """
        import Foundation
        enum CacheCleaner { static func purge(_ url: URL) { try? FileManager.default.removeItem(at: url) } }
        """
        #expect(!ReclaimShapeContract.Pattern.reclaimPurge.isHit(in: ReclaimShapeContract.codeOnly(unrelated)))
    }
}
