//
//  TrackIdentityTableContractTests.swift
//  QQPlayerTests
//
//  反屎山计划第④条：数据层「带身份列的表集合」契约（审计 2026-09-12 B2 遗留，此前 0 条）。
//
//  问题：`track.stable_id`（身份列）被重命名时，**所有引用 `track_stable_id` 的表都必须
//  跟着迁移**；但「哪些表算引用表」过去只隐含在 `TrackIdentityMigration` 的 SQL 里，
//  没有任何测试把它和**真实 schema** 对齐。后果：以后新增一张带 `track_stable_id` 的表
//  会**静默漏迁**（2026-09-14 手机真库定位事故就是这个形状：没人保证表集合本身没漂移）。
//
//  四条契约（全部 fail-closed：读不到源码 / 建不出库 = 红，不许静默通过）：
//   (a) schema 对齐：真实建库后「含身份列的表集合」== `TrackIdentityMigration.identityCoupledTables`
//   (b) 迁移覆盖：迁移源码里名单每张表都出现在「含身份列的 UPDATE/DELETE」中（白名单为空）
//   (c) 名单唯一：`identityCoupledTables` 全仓只 1 处定义 + 白名单不腐烂 + 无第二份名单
//   (d) 合成自证：临时库手动多建一张带身份列的表 → 提取函数必须捞出来、且 (a) 的等式变红
//
//  建库惯例同 DataIntegrityMigrationTests：`DatabaseQueue()` + `DatabaseManager(dbWriter:)`
//  + `createTables()`；无模拟器、无 UI。
//  注意（两条都踩过）：`#expect` 宏体不接受 `try`；宏体里也不要塞复杂表达式
//  （`let isBlock = a + 2 < chars.count && chars[a+1] == ...` 会触发
//   "unable to type-check this expression in reasonable time"）——先算到局部变量再断言。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 契约校验原语（纯函数，可喂合成输入自证）

private enum IdentityTableContract {
    /// 身份列名的**测试侧字面量**（独立于生产常量：生产常量改错时这里能抓住）。
    static let identityColumnLiteral: String = "track_stable_id"

    /// 测试侧认定的「身份列引用表」全量名（第二份名单检测用，独立于生产名单）。
    static let referenceTableNames: [String] = ["favorite", "play_history", "playlist_item", "track_artist"]

    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 迁移实现（唯一名单 + SQL 的事实源）。
    static let migrationSourcePath: String = "QQPlayer/Services/TrackIdentityMigration.swift"

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path): return "契约测试无法枚举目录（fail-closed）：\(path)"
            }
        }
    }

    /// 迁移源码文本。文件不存在 → throw（红），绝不静默通过。
    static func migrationSource() throws -> String {
        let url: URL = repositoryRoot.appendingPathComponent(migrationSourcePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 真实 schema：所有含身份列的表。
    /// 表名取自 `sqlite_master`，列来自 `PRAGMA table_info`（GRDB `columns(in:)`）。
    static func schemaTablesWithIdentityColumn(_ db: Database) throws -> Set<String> {
        let tableNames: [String] = try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """
        )
        var tables: Set<String> = []
        for tableName in tableNames {
            let columns: [ColumnInfo] = try db.columns(in: tableName)
            for column in columns where column.name == identityColumnLiteral {
                tables.insert(tableName)
            }
        }
        return tables
    }

    // MARK: Swift 源码原语

    /// 从 `start`（指向 `"`）解析一个字符串字面量 → (内容, 下一个字符下标)。
    /// 支持 `"""…"""` 块与 `"…"` 单行串（反斜杠转义按字面还原）。
    static func stringLiteralSpan(_ characters: [Character], from start: Int) -> (body: String, next: Int) {
        let total: Int = characters.count
        let quote: Character = "\""
        let backslash: Character = "\\"

        var isBlock: Bool = false
        if start + 2 < total {
            if characters[start + 1] == quote, characters[start + 2] == quote {
                isBlock = true
            }
        }

        var index: Int = start + (isBlock ? 3 : 1)
        var body: String = ""
        while index < total {
            let character: Character = characters[index]
            if isBlock {
                var closes: Bool = false
                if index + 2 < total {
                    if characters[index + 1] == quote, characters[index + 2] == quote {
                        closes = true
                    }
                }
                if closes, character == quote {
                    return (body, index + 3)
                }
            } else if character == quote {
                return (body, index + 1)
            } else if character == backslash, index + 1 < total {
                body.append(characters[index + 1])
                index += 2
                continue
            }
            body.append(character)
            index += 1
        }
        return (body, total)
    }

    /// 把源码里的字符串字面量与注释整体替换成空格（换行保留 → 行号不变）。
    /// 用途：扫「某个标识符是否被声明」时，只有**代码**算数——字符串里的字面、注释里的讨论
    /// 都不算定义。
    /// 为什么必须有：契约测试自己就要把 `let identityCoupledTables` 写进字符串（当扫描针）
    /// 和注释（解释为什么这么扫）——不剥离就会自匹配，把自己报成「第二处定义」。
    static func strippingLiteralsAndComments(_ source: String) -> String {
        let characters: [Character] = Array(source)
        let total: Int = characters.count
        var result: [Character] = []
        var index: Int = 0
        while index < total {
            let character: Character = characters[index]
            if character == "\"" {
                let span: (body: String, next: Int) = stringLiteralSpan(characters, from: index)
                let next: Int = span.next > index ? span.next : index + 1
                blank(characters, from: index, to: next, into: &result)
                index = next
                continue
            }
            if character == "/", index + 1 < total {
                let follower: Character = characters[index + 1]
                if follower == "/" {
                    var next: Int = index
                    while next < total, characters[next] != "\n" { next += 1 }
                    blank(characters, from: index, to: next, into: &result)
                    index = next
                    continue
                }
                if follower == "*" {
                    var next: Int = index + 2
                    while next + 1 < total {
                        if characters[next] == "*", characters[next + 1] == "/" {
                            next += 2
                            break
                        }
                        next += 1
                    }
                    blank(characters, from: index, to: min(next, total), into: &result)
                    index = min(next, total)
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return String(result)
    }

    /// 把 `[from, to)` 区间的字符以空格写进 `result`（换行原样保留 → 行号不变）。
    private static func blank(
        _ characters: [Character],
        from: Int,
        to: Int,
        into result: inout [Character]
    ) {
        for inner in from ..< min(to, characters.count) {
            let innerCharacter: Character = characters[inner]
            let replacement: Character = innerCharacter == "\n" ? "\n" : " "
            result.append(replacement)
        }
    }

    /// Swift 源码里的所有字符串字面量内容。
    static func stringLiterals(in source: String) -> [String] {
        let characters: [Character] = Array(source)
        let total: Int = characters.count
        var literals: [String] = []
        var index: Int = 0
        while index < total {
            let character: Character = characters[index]
            if character == "\"" {
                let span: (body: String, next: Int) = stringLiteralSpan(characters, from: index)
                literals.append(span.body)
                index = span.next > index ? span.next : index + 1
            } else {
                index += 1
            }
        }
        return literals
    }

    /// 从 `offset` 起第一个 `[` 开始的配对区间文本（跳过字符串字面量里的 `[`）。
    static func bracketedLiteral(in source: String, from offset: Int) -> String? {
        let characters: [Character] = Array(source)
        let total: Int = characters.count
        guard offset <= total else { return nil }

        var index: Int = offset
        var start: Int = -1
        while index < total {
            let character: Character = characters[index]
            if character == "\"" {
                index = stringLiteralSpan(characters, from: index).next
                continue
            }
            if character == "[" {
                start = index
                break
            }
            index += 1
        }
        guard start >= 0 else { return nil }

        var depth: Int = 0
        while index < total {
            let character: Character = characters[index]
            if character == "\"" {
                index = stringLiteralSpan(characters, from: index).next
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 {
                    let slice: ArraySlice<Character> = characters[start ... index]
                    return String(slice)
                }
            }
            index += 1
        }
        return nil
    }

    /// 源码里 `let/var x: Set<String> | [String] | Array<String> = [...]` 形式的声明。
    static func stringCollectionDeclarations(in source: String) -> [(name: String, literal: String, line: Int)] {
        let pattern: String = #"(?:let|var)\s+(\w+)\s*:\s*(?:Set<String>|\[String\]|Array<String>)\s*="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource: NSString = source as NSString
        let fullRange: NSRange = NSRange(location: 0, length: nsSource.length)

        var declarations: [(name: String, literal: String, line: Int)] = []
        for match in regex.matches(in: source, range: fullRange) {
            let nameRange: NSRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let literalStart: Int = match.range.location + match.range.length
            guard let literal = bracketedLiteral(in: source, from: literalStart) else { continue }
            let prefix: String = nsSource.substring(to: match.range.location)
            let line: Int = prefix.reduce(1) { (count: Int, character: Character) -> Int in
                character == "\n" ? count + 1 : count
            }
            let name: String = nsSource.substring(with: nameRange)
            declarations.append((name, literal, line))
        }
        return declarations
    }

    // MARK: SQL 语句扫描（同步 UPDATE/DELETE）

    /// 迁移 SQL 扫描结果。
    struct MigrationSqlScan {
        /// 表名 → 覆盖它的「含身份列的 UPDATE/DELETE」语句。
        var identityStatementsByTable: [String: [String]] = [:]
        /// 表名 → 被 UPDATE/DELETE 但语句里没有身份列（自证扫描器不是「见名就算」）。
        var unrelatedStatementsByTable: [String: [String]] = [:]

        var identityTables: Set<String> { Set(identityStatementsByTable.keys) }
    }

    /// 扫描源码里所有字符串语句，按「是否含身份列」归类到表名。
    static func scanMigrationSql(in source: String) -> MigrationSqlScan {
        var scan: MigrationSqlScan = MigrationSqlScan()
        let literals: [String] = stringLiterals(in: source)
        for literal in literals {
            let tables: Set<String> = tablesMutated(by: literal)
            for table in tables {
                if literal.contains(identityColumnLiteral) {
                    scan.identityStatementsByTable[table, default: []].append(literal)
                } else {
                    scan.unrelatedStatementsByTable[table, default: []].append(literal)
                }
            }
        }
        return scan
    }

    /// 一条 SQL 语句里被 UPDATE / DELETE 的表名。
    static func tablesMutated(by statement: String) -> Set<String> {
        let separator: (Character) -> Bool = { character in
            !character.isLetter && !character.isNumber && character != "_"
        }
        let tokens: [String] = statement.split(whereSeparator: separator).map { String($0) }
        var tables: Set<String> = []
        var index: Int = 0
        while index < tokens.count {
            let keyword: String = tokens[index].uppercased()
            if keyword == "UPDATE" {
                var cursor: Int = index + 1
                while cursor < tokens.count {
                    let modifier: String = tokens[cursor].uppercased()
                    if !updateModifiers.contains(modifier) { break }
                    cursor += 1
                }
                if cursor < tokens.count { tables.insert(tokens[cursor]) }
            } else if keyword == "DELETE" {
                var cursor: Int = index + 1
                if cursor < tokens.count, tokens[cursor].uppercased() == "FROM" {
                    cursor += 1
                    if cursor < tokens.count { tables.insert(tokens[cursor]) }
                }
            }
            index += 1
        }
        return tables
    }

    /// `UPDATE OR IGNORE|ROLLBACK|ABORT|REPLACE|FAIL <table>` 的修饰词。
    static let updateModifiers: Set<String> = ["OR", "IGNORE", "ROLLBACK", "ABORT", "REPLACE", "FAIL"]

    // MARK: 枚举仓库源码

    /// 指定目录下所有 .swift（相对仓库根的路径 + URL）；目录读不出来 → throw（fail-closed）。
    static func swiftFiles(under relativeDirectories: [String]) throws -> [(relativePath: String, url: URL)] {
        var files: [(relativePath: String, url: URL)] = []
        for directory in relativeDirectories {
            let base: URL = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                throw ContractError.directoryUnreadable(directory)
            }
            let prefix: String = repositoryRoot.path + "/"
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath: String = url.path.replacingOccurrences(of: prefix, with: "")
                files.append((relativePath, url))
            }
        }
        return files.sorted { (lhs, rhs) in lhs.relativePath < rhs.relativePath }
    }
}

// MARK: - Fixture

private enum IdentityTableFixture {
    /// 真实建库（与 DataIntegrityMigrationTests 同一惯例：内存库 + createTables，无 UI/模拟器）。
    static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }
}

// MARK: - (a) schema 对齐

@Suite("身份列引用表契约 · (a) schema 对齐")
struct IdentityTableSchemaAlignmentTests {
    @Test("(a) 真实 schema 含身份列的表集合 与 identityCoupledTables 双向相等（多一张 / 少一张都红）")
    func schemaMatchesDeclaredList() throws {
        let (_, dbQueue) = try IdentityTableFixture.makeManager()
        let schemaTables: Set<String> = try dbQueue.read { db in
            try IdentityTableContract.schemaTablesWithIdentityColumn(db)
        }
        let declaredTables: Set<String> = TrackIdentityMigration.identityCoupledTables

        let missingFromList: [String] = schemaTables.subtracting(declaredTables).sorted()
        let missingFromSchema: [String] = declaredTables.subtracting(schemaTables).sorted()
        let schemaList: [String] = schemaTables.sorted()
        let declaredList: [String] = declaredTables.sorted()
        let column: String = IdentityTableContract.identityColumnLiteral

        let message: String = """
        ❌ 身份列引用表契约破裂（反屎山第④条）
          真实 schema 含 \(column) 的表：\(schemaList)
          迁移名单 identityCoupledTables：\(declaredList)
          schema 有、名单漏（新增引用表：加进 identityCoupledTables + 补迁移 SQL）：\(missingFromList)
          名单有、schema 无（表已删/改名，名单陈旧）：\(missingFromSchema)
        """
        #expect(schemaTables == declaredTables, "\(message)")
    }

    @Test("(a2) 身份列名常量与 schema 事实一致（名单与列名不许互相漂移）")
    func identityColumnConstantMatchesSchema() {
        let production: String = TrackIdentityMigration.identityColumn
        let testSide: String = IdentityTableContract.identityColumnLiteral
        #expect(production == testSide, "身份列名常量漂移：生产=\(production) 测试=\(testSide)")
    }

    @Test("(a3) 名单非空（防止「两边都空」造成的假绿）")
    func declaredListIsNotEmpty() {
        #expect(!TrackIdentityMigration.identityCoupledTables.isEmpty)
    }
}

// MARK: - (b) 迁移真的覆盖

@Suite("身份列引用表契约 · (b) 迁移覆盖")
struct IdentityTableMigrationCoverageTests {
    @Test("(b) 名单每张表都出现在迁移源码含身份列的 UPDATE/DELETE 中（双向、白名单为空）")
    func everyDeclaredTableIsMigrated() throws {
        let source: String = try IdentityTableContract.migrationSource()
        let scan: IdentityTableContract.MigrationSqlScan = IdentityTableContract.scanMigrationSql(in: source)
        let migratedTables: Set<String> = scan.identityTables
        let declaredTables: Set<String> = TrackIdentityMigration.identityCoupledTables

        let column: String = IdentityTableContract.identityColumnLiteral
        let migratedList: [String] = migratedTables.sorted()
        let declaredList: [String] = declaredTables.sorted()
        let notMigrated: [String] = declaredTables.subtracting(migratedTables).sorted()
        let migratedButUndeclared: [String] = migratedTables.subtracting(declaredTables).sorted()

        #expect(
            !migratedTables.isEmpty,
            "迁移源码里没扫出任何含 \(column) 的 UPDATE/DELETE —— 扫描器失效或迁移被删"
        )

        let missingMessage: String = """
        ❌ 名单里的表没有出现在含 \(column) 的 UPDATE/DELETE 中（重命名身份列时会静默漏迁）：
          \(notMigrated)
          名单：\(declaredList)   迁移实际覆盖：\(migratedList)
        """
        #expect(notMigrated.isEmpty, "\(missingMessage)")

        let extraMessage: String = """
        ❌ 迁移源码 UPDATE/DELETE 了名单外的表（白名单为空，fail-closed）：
          \(migratedButUndeclared)
          该表要么引用身份列 → 加进 identityCoupledTables；要么不引用 → 从迁移里去掉。
        """
        #expect(migratedButUndeclared.isEmpty, "\(extraMessage)")
    }

    @Test("(b2) 自证：不含身份列的 UPDATE/DELETE 不算覆盖（扫描器不是「见名就算」）")
    func scannerIgnoresStatementsWithoutIdentityColumn() {
        let syntheticWithout: String = """
        try db.execute(sql: "UPDATE OR IGNORE favorite SET position = ? WHERE position = ?")
        try db.execute(sql: "DELETE FROM playlist_item WHERE position = 0")
        """
        let negativeScan: IdentityTableContract.MigrationSqlScan = IdentityTableContract.scanMigrationSql(in: syntheticWithout)
        let negativeTables: [String] = negativeScan.identityTables.sorted()
        #expect(negativeScan.identityTables.isEmpty, "不含身份列的语句不得算覆盖：\(negativeTables)")
        #expect(negativeScan.unrelatedStatementsByTable["favorite"] != nil)
        #expect(negativeScan.unrelatedStatementsByTable["playlist_item"] != nil)

        // 正对照：同样的写法，一旦带上身份列就得被扫出来
        let syntheticWith: String = """
        try db.execute(sql: "UPDATE play_history SET track_stable_id = ? WHERE track_stable_id = ?")
        """
        let positiveScan: IdentityTableContract.MigrationSqlScan = IdentityTableContract.scanMigrationSql(in: syntheticWith)
        let positiveTables: [String] = positiveScan.identityTables.sorted()
        #expect(positiveTables == ["play_history"], "带身份列的 UPDATE 必须被扫出来，实际：\(positiveTables)")
    }
}

// MARK: - (c) 名单唯一

@Suite("身份列引用表契约 · (c) 名单唯一")
struct IdentityTableListUniquenessTests {
    /// 允许「拥有身份列引用表名单」的文件白名单（**只允许迁移文件一处**）。
    /// 两处用途：① `identityCoupledTables` 的声明处；② 含 ≥2 张引用表名的集合字面量。
    /// 白名单腐烂检测：每个条目必须真实存在、且确实含声明，否则红。
    static let listOwnerWhitelist: [String] = [IdentityTableContract.migrationSourcePath]

    @Test("(c) identityCoupledTables 全仓只 1 处定义，且声明文件与白名单双向一致")
    func declarationAppearsExactlyOnce() throws {
        let swiftFiles: [(relativePath: String, url: URL)] = try IdentityTableContract.swiftFiles(
            under: ["QQPlayer", "QQPlayerTests"]
        )
        #expect(!swiftFiles.isEmpty, "扫不到任何 Swift 源文件 —— 仓库根路径推导失效（fail-closed）")

        var declarations: [String] = []
        for file in swiftFiles {
            let text: String = try String(contentsOf: file.url, encoding: .utf8)
            // 只看代码：字符串字面量里的同名字样不是「定义」
            // （本文件自己就把它当扫描针写在字符串里，不剥离 = 自匹配）。
            let code: String = IdentityTableContract.strippingLiteralsAndComments(text)
            let lines: [String] = code.components(separatedBy: .newlines)
            for (lineIndex, line) in lines.enumerated() {
                let declares: Bool = line.contains("let identityCoupledTables") || line.contains("var identityCoupledTables")
                if declares {
                    declarations.append("\(file.relativePath):\(lineIndex + 1)")
                }
            }
        }

        var declaringFiles: Set<String> = []
        for entry in declarations {
            let path: String = String(entry.prefix(while: { (character: Character) in character != ":" }))
            declaringFiles.insert(path)
        }
        let whitelist: Set<String> = Set(Self.listOwnerWhitelist)

        let countMessage: String = """
        ❌ identityCoupledTables 必须全仓只有 1 处定义，实际 \(declarations.count) 处：
          \(declarations.sorted())
        """
        #expect(declarations.count == 1, "\(countMessage)")

        let mismatchMessage: String = """
        ❌ 名单声明文件与白名单不一致（第二份名单 = 红）：
          实际声明文件：\(declaringFiles.sorted())
          白名单：\(whitelist.sorted())
        """
        #expect(declaringFiles == whitelist, "\(mismatchMessage)")

        // 白名单腐烂检测：白名单条目必须真实存在且确实含声明
        for path in Self.listOwnerWhitelist {
            let url: URL = IdentityTableContract.repositoryRoot.appendingPathComponent(path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "❌ 白名单腐烂：\(path) 已不存在（改名/删除后必须同步更新白名单）"
            )
            let text: String = try String(contentsOf: url, encoding: .utf8)
            let code: String = IdentityTableContract.strippingLiteralsAndComments(text)
            #expect(
                code.contains("let identityCoupledTables"),
                "❌ 白名单腐烂：\(path) 里已找不到 identityCoupledTables 声明"
            )
        }
    }

    @Test("(c2) 生产代码不得出现第二份「引用表集合」（集合字面量里含 ≥2 张引用表名）")
    func noSecondReferenceTableList() throws {
        // 只扫生产代码：测试里引用表名做断言是正当的，生产里第二份名单才是问题。
        let swiftFiles: [(relativePath: String, url: URL)] = try IdentityTableContract.swiftFiles(under: ["QQPlayer"])
        var offenders: [String] = []
        for file in swiftFiles {
            if Self.listOwnerWhitelist.contains(file.relativePath) { continue }
            let text: String = try String(contentsOf: file.url, encoding: .utf8)
            let declarations: [(name: String, literal: String, line: Int)] = IdentityTableContract
                .stringCollectionDeclarations(in: text)
            for declaration in declarations {
                let hits: [String] = IdentityTableContract.referenceTableNames.filter { name in
                    declaration.literal.contains("\"\(name)\"")
                }
                if hits.count >= 2 {
                    offenders.append("\(file.relativePath):\(declaration.line) \(declaration.name) → \(hits.sorted())")
                }
            }
        }

        let message: String = """
        ❌ 出现了第二份「身份列引用表」名单（共享语义只允许 1 处表达）：
          \(offenders.sorted())
          请改读 TrackIdentityMigration.identityCoupledTables，不要各写一份。
        """
        #expect(offenders.isEmpty, "\(message)")
    }

    @Test("(c4) 自证：字符串字面量里的同名字样不算定义，真声明才算（防扫描器自匹配）")
    func literalMentionsAreNotDeclarations() {
        // 本用例防的正是 (c) 第一次跑出来的红：扫描针自身被当成了声明。
        let mentionInLiteral: String = """
        let needle: String = "let identityCoupledTables"
        """
        let strippedMention: String = IdentityTableContract.strippingLiteralsAndComments(mentionInLiteral)
        #expect(
            !strippedMention.contains("let identityCoupledTables"),
            "字符串字面量里的字样不该算定义：\(strippedMention)"
        )

        let realDeclaration: String = """
        enum Foo {
            static let identityCoupledTables: Set<String> = ["favorite"]
        }
        """
        let strippedDeclaration: String = IdentityTableContract.strippingLiteralsAndComments(realDeclaration)
        #expect(
            strippedDeclaration.contains("let identityCoupledTables"),
            "真声明必须被保留：\(strippedDeclaration)"
        )
        #expect(strippedDeclaration.contains("enum Foo {"), "非字符串代码必须原样保留")
    }

    @Test("(c3) 自证：第二份名单的合成写法必须被抓到，单张表名不算")
    func secondListDetectorIsProven() {
        let duplicated: String = """
        enum Foo {
            static let identityTables: Set<String> = ["favorite", "playlist_item"]
        }
        """
        let declarations: [(name: String, literal: String, line: Int)] = IdentityTableContract
            .stringCollectionDeclarations(in: duplicated)
        #expect(declarations.count == 1, "合成第二份名单没解析出来：\(declarations.map(\.name))")
        #expect(declarations.first?.name == "identityTables")
        let duplicatedHits: Int = declarations.first.map { declaration in
            IdentityTableContract.referenceTableNames.filter { name in
                declaration.literal.contains("\"\(name)\"")
            }.count
        } ?? 0
        #expect(duplicatedHits == 2, "应命中 2 张引用表名，实际：\(duplicatedHits)")

        let single: String = """
        enum Foo {
            static let tables: [String] = ["favorite"]
        }
        """
        let singleDeclarations: [(name: String, literal: String, line: Int)] = IdentityTableContract
            .stringCollectionDeclarations(in: single)
        #expect(singleDeclarations.count == 1)
        let singleHits: Int = singleDeclarations.first.map { declaration in
            IdentityTableContract.referenceTableNames.filter { name in
                declaration.literal.contains("\"\(name)\"")
            }.count
        } ?? 0
        #expect(singleHits == 1, "单张表名不该算「一份名单」：\(singleHits)")
    }
}

// MARK: - (d) 合成自证（证明 (a) 真会红）

@Suite("身份列引用表契约 · (d) 合成自证")
struct IdentityTableContractSelfProofTests {
    @Test("(d) 临时库多建一张带身份列的表 → 提取函数捞得到，且 schema 集合 ≠ 名单")
    func syntheticExtraTableBreaksAlignment() throws {
        let (_, dbQueue) = try IdentityTableFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS synthetic_identity_probe (
                id INTEGER PRIMARY KEY,
                track_stable_id TEXT NOT NULL
            )
            """)
        }

        let schemaTables: Set<String> = try dbQueue.read { db in
            try IdentityTableContract.schemaTablesWithIdentityColumn(db)
        }
        let declaredTables: Set<String> = TrackIdentityMigration.identityCoupledTables
        let extra: [String] = schemaTables.subtracting(declaredTables).sorted()
        let schemaList: [String] = schemaTables.sorted()

        #expect(
            schemaTables.contains("synthetic_identity_probe"),
            "(a) 的提取函数必须把新增引用表捞出来，否则 (a) 是假绿：\(schemaList)"
        )
        #expect(
            schemaTables != declaredTables,
            "多出一张引用表后 schema 集合必须 ≠ 名单（否则 (a) 的等式断言形同虚设）"
        )
        #expect(
            extra == ["synthetic_identity_probe"],
            "多出来的应当恰好是 synthetic_identity_probe，实际：\(extra)"
        )
        #expect(
            schemaTables.count == declaredTables.count + 1,
            "schema 集合应恰好多 1 张：\(schemaTables.count) vs \(declaredTables.count)"
        )
        // 对照组：不带身份列的表不得被捞出来（提取函数不是「返回全部表」）
        #expect(
            !schemaTables.contains("playlist"),
            "playlist 没有身份列，不该出现在结果里：\(schemaList)"
        )
    }

    @Test("(d2) 同名不同列：只有真带身份列的表算数（对照组合法性）")
    func similarlyNamedTableWithoutColumnIsNotCounted() throws {
        let (_, dbQueue) = try IdentityTableFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS synthetic_identity_probe_sibling (
                id INTEGER PRIMARY KEY,
                stable_id TEXT NOT NULL
            )
            """)
        }
        let schemaTables: Set<String> = try dbQueue.read { db in
            try IdentityTableContract.schemaTablesWithIdentityColumn(db)
        }
        let declaredTables: Set<String> = TrackIdentityMigration.identityCoupledTables
        let schemaList: [String] = schemaTables.sorted()

        #expect(!schemaTables.contains("synthetic_identity_probe_sibling"), "不该被捞出来：\(schemaList)")
        #expect(schemaTables == declaredTables, "对照库应当与名单相等，实际：\(schemaList)")
    }
}
