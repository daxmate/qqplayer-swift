//
//  main.swift
//  scripts/dsq-shared/selftest
//
//  DSQShared 解析层 + 迁移器的无模拟器自检（swiftc 直编生产源码）。
//  覆盖任务要求的 5 个场景：环境变量覆盖 / 无容器回落 / dry-run 零变更 /
//  迁移幂等 / 目标非空不覆盖；额外覆盖空目标目录、同卷 move 与跨卷 copy。
//

import Darwin
import Foundation

var failures: [String] = []
var assertionCount = 0

func expect(_ condition: Bool, _ message: String) {
    assertionCount += 1
    if !condition {
        failures.append(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    assertionCount += 1
    if actual != expected {
        failures.append("\(message)：实际 \(actual)，期望 \(expected)")
    }
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("dsq-shared-selftest-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }

func path(_ url: URL) -> String {
    url.standardizedFileURL.path
}

func isSymbolicLink(_ url: URL) -> Bool {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return false }
    return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
}

func writeFile(_ url: URL, bytes: Int) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

// MARK: - 1. 环境变量覆盖

let envRoot = sandbox.appendingPathComponent("env-root", isDirectory: true)
let envLocations = DSQSharedResolver(
    environment: [DSQSharedLocations.environmentKey: envRoot.path],
    fileManager: fm,
    homeDirectory: sandbox,
    isSandboxed: false,
    containerURL: { _ in nil },
    applicationSupportDirectory: { sandbox }
).resolve()
expectEqual(envLocations.source, .environment, "环境变量分支来源")
expectEqual(path(envLocations.root), path(envRoot), "环境变量分支根路径")

// MARK: - 2. App Group 容器（沙盒）

let container = sandbox.appendingPathComponent("group-container", isDirectory: true)
let groupLocations = DSQSharedResolver(
    environment: [:],
    fileManager: fm,
    homeDirectory: sandbox,
    isSandboxed: true,
    containerURL: { identifier in
        expectEqual(identifier, DSQSharedLocations.appGroupIdentifier, "App Group identifier")
        return container
    },
    applicationSupportDirectory: { sandbox }
).resolve()
expectEqual(groupLocations.source, .appGroupContainer, "App Group 分支来源")
expectEqual(path(groupLocations.root), path(container.appendingPathComponent(DSQSharedLocations.rootDirectoryName)), "App Group 根路径")

// MARK: - 2b. 容器路径不可写（ad-hoc / 未授权）→ 回落 Application Support

let readOnlyContainer = sandbox.appendingPathComponent("readonly-container", isDirectory: true)
try fm.createDirectory(at: readOnlyContainer, withIntermediateDirectories: true)
try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyContainer.path)
let unwritableLocations = DSQSharedResolver(
    environment: [:],
    fileManager: fm,
    homeDirectory: sandbox,
    isSandboxed: true,
    containerURL: { _ in readOnlyContainer },
    applicationSupportDirectory: { sandbox }
).resolve()
// 还原权限，避免影响沙盒目录清理
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyContainer.path)
expectEqual(unwritableLocations.source, .applicationSupport, "容器不可写 → 回落 Application Support")
expect(unwritableLocations.fallbackNote != nil, "容器不可写时记录回落原因")
expect(
    unwritableLocations.fallbackNote?.contains("不可写") == true,
    "回落原因包含不可写字样"
)

// MARK: - 3. 无容器 → Application Support 兜底

let appSupport = sandbox.appendingPathComponent("app-support", isDirectory: true)
let fallbackLocations = DSQSharedResolver(
    environment: [:],
    fileManager: fm,
    homeDirectory: sandbox,
    isSandboxed: true,
    containerURL: { _ in nil },
    applicationSupportDirectory: { appSupport }
).resolve()
expectEqual(fallbackLocations.source, .applicationSupport, "兜底分支来源")
expectEqual(
    path(fallbackLocations.root),
    path(appSupport.appendingPathComponent(DSQSharedLocations.rootDirectoryName)),
    "兜底根路径"
)

// MARK: - 4. 非沙盒 + Group 容器目录已存在 → 直接用

let home = sandbox.appendingPathComponent("home", isDirectory: true)
let directGroupRoot = home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Group Containers", isDirectory: true)
    .appendingPathComponent(DSQSharedLocations.appGroupIdentifier, isDirectory: true)
    .appendingPathComponent(DSQSharedLocations.rootDirectoryName, isDirectory: true)
try fm.createDirectory(at: directGroupRoot, withIntermediateDirectories: true)
let directLocations = DSQSharedResolver(
    environment: [:],
    fileManager: fm,
    homeDirectory: home,
    isSandboxed: false,
    containerURL: { _ in nil },
    applicationSupportDirectory: { appSupport }
).resolve()
expectEqual(directLocations.source, .groupContainerDirectory, "非沙盒直连 Group 容器来源")
expectEqual(path(directLocations.root), path(directGroupRoot), "非沙盒直连 Group 容器根路径")

// 沙盒里即使目录存在也必须跳过第 3 条
let sandboxWithDirect = DSQSharedResolver(
    environment: [:],
    fileManager: fm,
    homeDirectory: home,
    isSandboxed: true,
    containerURL: { _ in nil },
    applicationSupportDirectory: { appSupport }
).resolve()
expectEqual(sandboxWithDirect.source, .applicationSupport, "沙盒跳过直连 Group 容器")

// MARK: - 5. 目录按需创建（幂等）

let ensureRoot = sandbox.appendingPathComponent("ensure", isDirectory: true)
let ensureLocations = DSQSharedLocations(root: ensureRoot, source: .environment)
try ensureLocations.ensureDirectories(fileManager: fm)
let expectedDirectories = [
    ensureLocations.root,
    ensureLocations.modelsRoot,
    ensureLocations.booksRoot,
    ensureLocations.dictionariesRoot,
    ensureLocations.audiobooksRoot,
]
for directory in expectedDirectories {
    expect(isDirectory(directory), "按需创建目录：\(directory.lastPathComponent)")
}
try ensureLocations.ensureDirectories(fileManager: fm)
expect(true, "ensureDirectories 第二次调用不抛错")

// MARK: - 迁移器 fixture

func makeMigrationFixture(_ name: String) throws -> (base: URL, source: URL, destination: URL, marker: URL) {
    let base = sandbox.appendingPathComponent(name, isDirectory: true)
    let source = base.appendingPathComponent("legacy", isDirectory: true)
    let destination = base.appendingPathComponent("newroot", isDirectory: true)
    let marker = base.appendingPathComponent(DSQSharedMigrator.markerFileName)
    try writeFile(source.appendingPathComponent("a.txt"), bytes: 3)
    try writeFile(source.appendingPathComponent("sub/b.txt"), bytes: 5)
    return (base, source, destination, marker)
}

func sourceItem(_ fixture: (base: URL, source: URL, destination: URL, marker: URL)) -> DSQSharedMigrator.Item {
    DSQSharedMigrator.Item(name: "legacy", source: fixture.source, destination: fixture.destination)
}

// MARK: - 6. dry-run 不产生任何磁盘变更

do {
    let fixture = try makeMigrationFixture("dry-run")
    let before = try DSQSharedMigrator.measure(fixture.source, fileManager: fm)
    let report = DSQSharedMigrator(fileManager: fm).run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker
    )
    expect(report.dryRun, "dry-run 报告标记")
    expect(report.succeeded, "dry-run 预检成功")
    expectEqual(report.items.first?.outcome, .planned, "dry-run 结果 = planned")
    expect(isDirectory(fixture.source), "dry-run 源目录保留")
    expect(!fm.fileExists(atPath: fixture.destination.path), "dry-run 不创建目标")
    expect(!fm.fileExists(atPath: fixture.marker.path), "dry-run 不写 marker")
    expectEqual(try DSQSharedMigrator.measure(fixture.source, fileManager: fm), before, "dry-run 源内容不变")
}

// MARK: - 7. apply（同卷 move）+ 校验 + marker + symlink

do {
    let fixture = try makeMigrationFixture("apply-move")
    let report = DSQSharedMigrator(fileManager: fm).run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker,
        options: .init(dryRun: false)
    )
    expect(report.succeeded, "apply 成功")
    expectEqual(report.items.first?.outcome, .moved, "同卷结果 = moved")
    expect(isSymbolicLink(fixture.source), "旧路径替换为 symlink")
    expect(isDirectory(fixture.destination), "目标目录存在")
    expectEqual(
        try DSQSharedMigrator.measure(fixture.destination, fileManager: fm),
        DSQSharedMigrator.Measurement(files: 2, bytes: 8),
        "迁移后文件数 / 字节数"
    )
    expect(fm.fileExists(atPath: fixture.marker.path), "marker 已写入")
    if let link = try? fm.destinationOfSymbolicLink(atPath: fixture.source.path) {
        expectEqual(path(URL(fileURLWithPath: link)), path(fixture.destination), "symlink 指向新根")
    } else {
        expect(false, "symlink 可读取")
    }
}

// MARK: - 8. 幂等：第二次为空操作

do {
    let fixture = try makeMigrationFixture("idempotent")
    let migrator = DSQSharedMigrator(fileManager: fm)
    _ = migrator.run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker,
        options: .init(dryRun: false)
    )
    let destinationMeasurement = try DSQSharedMigrator.measure(fixture.destination, fileManager: fm)
    let second = migrator.run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker,
        options: .init(dryRun: false)
    )
    expect(second.succeeded, "第二次运行成功")
    expectEqual(second.items.first?.outcome, .alreadyMigrated, "第二次结果 = alreadyMigrated")
    expectEqual(try DSQSharedMigrator.measure(fixture.destination, fileManager: fm), destinationMeasurement, "第二次不改目标")
}

// MARK: - 9. 目标非空不覆盖

do {
    let fixture = try makeMigrationFixture("non-empty-destination")
    try writeFile(fixture.destination.appendingPathComponent("existing.txt"), bytes: 2)
    let before = try DSQSharedMigrator.measure(fixture.source, fileManager: fm)
    let report = DSQSharedMigrator(fileManager: fm).run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker,
        options: .init(dryRun: false)
    )
    expect(!report.succeeded, "目标非空 → 失败")
    expectEqual(report.items.first?.outcome, .destinationNotEmpty, "目标非空结果")
    expect(!isSymbolicLink(fixture.source), "失败时源保持原样")
    expectEqual(try DSQSharedMigrator.measure(fixture.source, fileManager: fm), before, "失败时源内容不变")
    expect(fm.fileExists(atPath: fixture.destination.appendingPathComponent("existing.txt").path), "目标既有文件保留")
    expect(!fm.fileExists(atPath: fixture.marker.path), "失败不写 marker")
}

// MARK: - 9b. 目标已存在但为空 → 正常迁移（本机容器空目录场景）

do {
    let fixture = try makeMigrationFixture("empty-destination")
    try fm.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
    let report = DSQSharedMigrator(fileManager: fm).run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker,
        options: .init(dryRun: false)
    )
    expect(report.succeeded, "空目标目录 → 成功")
    expectEqual(report.items.first?.outcome, .moved, "空目标目录结果 = moved")
    expectEqual(
        try DSQSharedMigrator.measure(fixture.destination, fileManager: fm),
        DSQSharedMigrator.Measurement(files: 2, bytes: 8),
        "空目标目录迁移后文件数 / 字节数"
    )
    expect(isSymbolicLink(fixture.source), "空目标目录迁移后旧路径 symlink")
    expect(fm.fileExists(atPath: fixture.marker.path), "空目标目录迁移写 marker")
}

// MARK: - 10. 跨卷：copy → 校验 → 删源

do {
    let fixture = try makeMigrationFixture("cross-volume")
    let report = DSQSharedMigrator(fileManager: fm).run(
        items: [sourceItem(fixture)],
        markerURL: fixture.marker,
        options: .init(dryRun: false, sameVolume: { _, _ in false })
    )
    expect(report.succeeded, "跨卷成功")
    expectEqual(report.items.first?.outcome, .copied, "跨卷结果 = copied")
    expect(isSymbolicLink(fixture.source), "跨卷后旧路径 symlink")
    expectEqual(
        try DSQSharedMigrator.measure(fixture.destination, fileManager: fm),
        DSQSharedMigrator.Measurement(files: 2, bytes: 8),
        "跨卷后文件数 / 字节数"
    )
}

// MARK: - 结果

if failures.isEmpty {
    print("✅ DSQShared 自检通过：\(assertionCount) 条断言")
    exit(0)
} else {
    for failure in failures {
        print("❌ \(failure)")
    }
    print("❌ DSQShared 自检失败：\(failures.count)/\(assertionCount) 条断言")
    exit(1)
}
