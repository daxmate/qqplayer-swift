//
//  TrackStoredPathGuardTests.swift
//  QQPlayerTests
//
//  **长期防复发守卫（2026-11-19）**：iOS 侧 `track.path` 是「存储形态」——
//  曲库内文件存相对 `Documents/Music` 的相对路径，只有曲库外文件才存绝对路径。
//  因此「文件是否存在 / 文件 URL」一律必须经 `LibraryRoot.absoluteURL(forStoredPath:)`
//  / `absolutePath(forStoredPath:)` 解析。裸用 `track.path` 去 `fileExists` 或
//  `URL(fileURLWithPath:)`，相对路径会被当成「相对当前工作目录」→ 恒判文件不存在。
//
//  血例（1.8.2 之前）：iOS 歌词时间轴对齐入口的可见性判据与开跑前守卫都裸用了
//  `track.path` → 入口被整项隐藏（Mac 存绝对路径，故只在 iOS 复现）。
//  行为测试只能证「今天这版对」，挡不住下一个人再抄一遍；共享语义的防复发靠形状守卫。
//
//  守卫口径（fail-closed）：
//    ① 源码根读不到、扫描文件数异常偏少 = 红，绝不静默通过；
//    ② 白名单文件消失 = 红（豁免清单必须与代码同步，不许悄悄过期）；
//    ③ 命中禁用模式 = 红，逐条打印 `文件:行`。
//
//  扫描范围：只扫 App 源码（`QQPlayer/`），不扫测试（测试里会出现反例写法字符串）。
//

import Foundation
import Testing

struct TrackStoredPathGuardTests {
    /// 仓库根：本文件位于 `<repo>/QQPlayerTests/` 下 → 上两级。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 扫描根（相对仓库根）：只扫 App 源码。
    static let appSourceDirectory = "QQPlayer"

    /// 扫描下限：`QQPlayer/` 下现有 400+ 个 .swift，低于此值说明扫描逻辑坏了。
    static let minimumScannedFiles = 300

    /// 禁用模式：裸 `track.path` 直接做存在性判断 / 构造文件 URL。
    static let forbiddenPatterns = [
        "fileExists(atPath: track.path",
        "URL(fileURLWithPath: track.path",
        "fileURLWithPath: currentTrack.path",
    ]

    /// 豁免清单（仓库相对路径）：**macOS 专属**视图/工具里按「绝对路径」语义使用
    /// `track.path` 的既有调用点（1.8.2 的修复范围只收口 iOS 侧的歌词对齐链路，
    /// 不顺手改 Mac 的改名 / 刮削逻辑）。谁要新增豁免，必须在本文件写明理由。
    static let allowedNakedPathFiles: Set<String> = [
        "QQPlayer/Mac/MacScrapeSettingsView.swift",
        "QQPlayer/Mac/MacSyncLocalContentProvider.swift",
        "QQPlayer/Mac/MacTagEditorView+RenameSave.swift",
        "QQPlayer/Mac/MacTagEditorView.swift",
    ]

    @Test("App 源码不得裸用 track.path 做文件存在性判断或构造文件 URL")
    func noNakedTrackPathForFileAccess() throws {
        let files = try Self.scannableSwiftFiles()
        #expect(
            files.count >= Self.minimumScannedFiles,
            "扫描到的源文件数异常偏少（\(files.count) < \(Self.minimumScannedFiles)），守卫可能已失效"
        )

        var violations: [String] = []
        for url in files {
            let relativePath = Self.relativePath(of: url)
            guard !Self.allowedNakedPathFiles.contains(relativePath) else { continue }

            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                for pattern in Self.forbiddenPatterns where line.contains(pattern) {
                    violations.append("\(relativePath):\(index + 1): \(pattern)")
                }
            }
        }

        let detail = "track.path 是存储形态（相对 Documents/Music），必须经 LibraryRoot 解析：\n"
            + violations.joined(separator: "\n")
        #expect(violations.isEmpty, Comment(rawValue: detail))
    }

    @Test("豁免清单里的文件必须真实存在（清单不许过期）")
    func allowlistEntriesStillExist() {
        for relativePath in Self.allowedNakedPathFiles.sorted() {
            let url = Self.repoRoot.appendingPathComponent(relativePath)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "豁免清单条目已不存在，请从 TrackStoredPathGuardTests.allowedNakedPathFiles 移除：\(relativePath)"
            )
        }
    }

    // MARK: - 扫描

    private static func scannableSwiftFiles() throws -> [URL] {
        let fileManager = FileManager.default
        let root = repoRoot.appendingPathComponent(appSourceDirectory, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GuardError.sourceRootMissing(root.path)
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw GuardError.sourceRootUnreadable(root.path)
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// 报错用的仓库相对路径（`QQPlayer/.../Foo.swift`）。
    private static func relativePath(of url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    private enum GuardError: Error {
        case sourceRootMissing(String)
        case sourceRootUnreadable(String)
    }
}
