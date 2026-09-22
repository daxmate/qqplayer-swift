//
//  SyncConnectDiagTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  同步诊断落盘（`SyncConnectDiag`）的落点解析 + 环形截断行为（2026-09-20 补，测试债批 ①）。
//
//  为什么补（审计结论原文）：这是「有意留白」里唯一**能靠加缝解掉**的一项——
//  `log()` 的落点写死在 App 容器 `Documents/sync-diag.log`，全进程共享单文件，
//  测试内无法确定性观察环形截断（尝试过 `hasSuffix` 与 `.serialized` 两种写法都偶发红）。
//  2026-09-20 给生产加了最小缝（`logFileURLOverride` + 把落点解析/追加拆成可同步调用的
//  `logFileURL()` / `append(_:to:)`），**行为零变化**，本文件锁住这两件行为：
//    (a) 落点解析：override 生效；未设时落在 App 容器 `Documents/sync-diag.log`；
//    (b) 环形截断：超 256KB 只留尾部 64KB，且本次新写的一行**完整**落在文件尾。
//
//  为什么这条重要：真机「发现不到桌面端 / 连上别的主机」这类问题只能靠这份日志取证
//  （真机 `print` 取不到，见 ios-device-forensics）。截断写坏 = 取证时读到半行时间戳，
//  而这类缺陷在真机上只表现为「日志看着不太对」，没有任何门禁会红。
//
//  口径：只测**同步**实现与落点解析，不测 `log()` 的异步派发（那是 DispatchQueue 的事）；
//  涉及静态 override 的用例串行执行（Swift Testing 默认并行）。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("SyncConnectDiag 落盘：落点解析 + 环形截断", .serialized)
struct SyncConnectDiagTests {
    // MARK: - 夹具

    private static let truncateThreshold = 256_000
    private static let tailKeepBytes = 64_000

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    private static func fill(_ byte: UInt8, count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    // MARK: - (a) 落点解析

    @Test("落点 override：设了就落到 override 指定的路径")
    func overrideWinsForLogFileURL() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sync-diag.log")

        SyncConnectDiag.logFileURLOverride = url
        defer { SyncConnectDiag.logFileURLOverride = nil }

        #expect(SyncConnectDiag.logFileURL() == url)
    }

    @Test("落点默认：未设 override 时落在 App 容器 Documents/Logs/sync-diag.log")
    func defaultLogFileURLIsAppContainerDocuments() {
        SyncConnectDiag.logFileURLOverride = nil

        let resolved = SyncConnectDiag.logFileURL()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        // 2026-09-22 曲库文件夹化：日志统一收进 `Documents/Logs/`（口径变了，断言跟着走）。
        // 落点经 `LibraryRoot` 常量拼出——不在测试里写死字面量，目录名只有一份事实源。
        #expect(resolved == documents?
            .appendingPathComponent(LibraryRoot.logsDirectoryName, isDirectory: true)
            .appendingPathComponent("sync-diag.log"))
        // 反例对照：默认落点**不是**临时目录（防止"缝"把生产落点也改了）
        #expect(resolved?.path.hasPrefix(FileManager.default.temporaryDirectory.path) == false)
    }

    // MARK: - (b) 环形截断

    @Test("落点不存在：新建文件并写入完整一行（含换行）")
    func appendCreatesFileWithWholeLine() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sync-diag.log")
        let line = "[2026-09-20T10:00:00Z] browse failed\n"

        SyncConnectDiag.append(line, to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == line)
        #expect(text.hasSuffix("\n"))
    }

    @Test("未超阈值：不截断，历史内容原样保留 + 追加一行")
    func belowThresholdKeepsFullHistory() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sync-diag.log")
        let history = Self.fill(UInt8(ascii: "A"), count: 1000)
        try Self.write(history, to: url)
        let line = "[t] joined host\n"

        SyncConnectDiag.append(line, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.count == history.count + Data(line.utf8).count)
        #expect(data.prefix(history.count) == history)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasSuffix(line))
    }

    @Test("恰好等于阈值（256KB）：不触发截断（边界不早切）")
    func exactlyAtThresholdDoesNotTruncate() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sync-diag.log")
        let history = Self.fill(UInt8(ascii: "A"), count: Self.truncateThreshold)
        try Self.write(history, to: url)
        let line = "[t] boundary\n"

        SyncConnectDiag.append(line, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.count == Self.truncateThreshold + Data(line.utf8).count)
        #expect(data.prefix(1) == Data([UInt8(ascii: "A")]))
    }

    @Test("超阈值：只留尾部 64KB（头部内容丢弃）+ 本次一行完整落在文件尾")
    func aboveThresholdKeepsTailOnlyAndAppendsWholeLine() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sync-diag.log")
        // 前 236KB 用 A（应被丢弃），后 64KB 用 B（应保留）—— 判定「留的是尾部」而不是「留的是任意 64KB」。
        try Self.write(Self.fill(UInt8(ascii: "A"), count: 236_000), to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { _ = try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Self.fill(UInt8(ascii: "B"), count: 64_000))
        let line = "[2026-09-20T10:00:00Z] session closed: peer timeout\n"

        SyncConnectDiag.append(line, to: url)

        let data = try Data(contentsOf: url)
        let text = try #require(String(data: data, encoding: .utf8))

        // 总量 = 保留的尾部 64KB + 本次一行（不多不少：截断后没有重复追加，也没有丢掉本次这一行）
        #expect(data.count == Self.tailKeepBytes + Data(line.utf8).count)
        // 留的是尾部：丢弃区的 A 一个不剩
        #expect(!text.contains("A"))
        #expect(text.hasPrefix(String(repeating: "B", count: 64)))
        // 本次写入的一行完整（不会出现半行时间戳——那正是取证时最难查的形状）
        #expect(text.hasSuffix(line))
    }

    @Test("落点目录不存在：静默失败，不抛错也不建半个文件（诊断失败不影响同步主流程）")
    func appendToMissingDirectoryIsSilent() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("no-such-dir").appendingPathComponent("sync-diag.log")

        SyncConnectDiag.append("[t] iCloud folder vanished\n", to: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
