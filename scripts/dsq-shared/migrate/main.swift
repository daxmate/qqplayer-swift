//
//  main.swift
//  scripts/dsq-shared/migrate
//
//  共享资源目录迁移 CLI（默认 dry-run）。
//
//  用法：
//    bash scripts/dsq-shared-migrate.sh --dry-run   # 只看计划，不动盘
//    bash scripts/dsq-shared-migrate.sh --apply     # 显式执行
//

import Darwin
import Foundation

func usage() -> String {
    """
    用法：bash scripts/dsq-shared-migrate.sh [--dry-run | --apply]

      --dry-run   默认；只打印计划，不做任何磁盘变更
      --apply     显式执行迁移（move / copy → 校验 → 删源）
      --help      显示本帮助
    """
}

var apply = false
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--apply":
        apply = true
    case "--dry-run":
        apply = false
    case "--help", "-h":
        print(usage())
        exit(0)
    default:
        fputs("未知参数：\(argument)\n\n\(usage())\n", stderr)
        exit(2)
    }
}

let fileManager = FileManager.default
let home = UserHomeDirectory.realHomeURL
let locations = DSQSharedResolver().resolve()
let markerURL = locations.root.appendingPathComponent(DSQSharedMigrator.markerFileName)

let applicationSupport = home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Application Support", isDirectory: true)
let legacyResources = DSQSharedLegacyPaths.resourcesRoot(applicationSupport: applicationSupport)
let legacyModelsRoot = DSQSharedLegacyPaths.recommendationModelsRoot(applicationSupport: applicationSupport)

var items: [DSQSharedMigrator.Item] = [
    .init(name: "public-resources", source: legacyResources, destination: locations.root),
]

if fileManager.fileExists(atPath: legacyModelsRoot.path) {
    let children = (try? fileManager.contentsOfDirectory(
        at: legacyModelsRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            continue
        }
        let destination = locations.modelDirectory(
            kind: DSQSharedModelCatalog.recommendationKind,
            modelID: child.lastPathComponent,
            version: DSQSharedModelCatalog.currentVersion
        )
        items.append(.init(name: "model:\(child.lastPathComponent)", source: child, destination: destination))
    }
}

print("共享资源根：\(locations.root.path)")
print("解析来源：\(locations.source.rawValue)")
print("模式：\(apply ? "apply（会改盘）" : "dry-run（不改盘）")")
print("marker：\(markerURL.path)")
print("")

let report = DSQSharedMigrator(fileManager: fileManager).run(
    items: items,
    markerURL: markerURL,
    options: .init(dryRun: !apply)
)

for item in report.items {
    print("[\(item.outcome.rawValue)] \(item.name)")
    print("    \(item.source.path)")
    print(" →  \(item.destination.path)")
    print("    \(item.message)")
}
for warning in report.warnings {
    print("⚠️ \(warning)")
}
print("")
print(report.succeeded ? "结论：成功" : "结论：失败（未写 marker）")
exit(report.succeeded ? 0 : 1)
