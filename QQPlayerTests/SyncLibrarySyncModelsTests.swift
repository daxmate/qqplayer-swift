//
//  SyncLibrarySyncModelsTests.swift
//  QQPlayerTests
//
//  S2 M3-3b 文件同步「按路径拉取」协议载荷纯逻辑：
//  - SyncFetchRequest / SyncFileFetchFailure / SyncFetchResult Codable roundtrip
//  - SyncFrameType 新 case（syncFetchRequest=12 / syncFetchResult=13）编解码
//  - 请求列表规范化（拒空/绝对/`..` / 去重 / 升序）+ **解码不静默丢弃**（非法路径
//    要能如实进 failed，而非被 normalize 吃掉）
//  - SyncFetchResult 构造确定性（排序去重）+ SyncLibraryPathResolver 解析语义
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncLibrarySyncModelsTests {
    // MARK: - 模型编解码

    @Test("SyncFetchRequest / 失败记录 / 结果 Codable roundtrip")
    func payloadRoundtrip() throws {
        let request = SyncFetchRequest(
            collection: .tracks(["s1", "s2"]),
            relativePaths: ["Album/01 Song.flac", "Album/02 Song.flac"]
        )
        let requestData = try SyncFetchCodec.encode(request)
        let decodedRequest = try SyncFetchCodec.decode(SyncFetchRequest.self, from: requestData)
        #expect(decodedRequest == request)
        #expect(decodedRequest.relativePaths == ["Album/01 Song.flac", "Album/02 Song.flac"])

        let result = SyncFetchResult(
            completed: ["Album/01 Song.flac"],
            failed: [SyncFileFetchFailure(relativePath: "Album/02 Song.flac", reason: SyncFetchFailureReason.notFound)]
        )
        let resultData = try SyncFetchCodec.encode(result)
        let decodedResult = try SyncFetchCodec.decode(SyncFetchResult.self, from: resultData)
        #expect(decodedResult == result)
        #expect(!decodedResult.isFullSuccess)
    }

    @Test("结果构造确定性：completed 排序去重、failed 按路径排序")
    func resultDeterminism() {
        let result = SyncFetchResult(
            completed: ["b.flac", "a.flac", "b.flac"],
            failed: [
                SyncFileFetchFailure(relativePath: "z.flac", reason: SyncFetchFailureReason.notFound),
                SyncFileFetchFailure(relativePath: "c.flac", reason: SyncFetchFailureReason.invalidPath),
            ]
        )
        #expect(result.completed == ["a.flac", "b.flac"])
        #expect(result.failed.map(\.relativePath) == ["c.flac", "z.flac"])

        let empty = SyncFetchResult(completed: [], failed: [])
        #expect(empty.isFullSuccess)
    }

    @Test("帧 12/13 编解码 + 类型表不冲突")
    func frameTypeRoundtrip() throws {
        #expect(SyncFrameType.syncFetchRequest.rawValue == 12)
        #expect(SyncFrameType.syncFetchResult.rawValue == 13)
        // 既有类型值不被新 case 挪动（线上兼容）
        #expect(SyncFrameType.manifestRequest.rawValue == 10)
        #expect(SyncFrameType.manifestResponse.rawValue == 11)

        let payload = try SyncFetchCodec.encode(SyncFetchRequest(relativePaths: ["a.flac"]))
        let frame = SyncFrame(type: .syncFetchRequest, flags: .encrypted, payload: payload)
        let bytes = try frame.encode()
        let (decoded, consumed) = try SyncFrame.decode(from: bytes)
        #expect(consumed == bytes.count)
        #expect(decoded.type == .syncFetchRequest)
        #expect(decoded.payload == payload)

        let resultFrame = SyncFrame(
            type: .syncFetchResult,
            payload: try SyncFetchCodec.encode(SyncFetchResult(completed: ["a.flac"], failed: []))
        )
        let (decodedResult, _) = try SyncFrame.decode(from: try resultFrame.encode())
        #expect(decodedResult.type == .syncFetchResult)
    }

    // MARK: - 请求列表规范化

    @Test("请求列表规范化：拒非法路径 / 去重 / 升序（与 manifest 同口径）")
    func requestNormalize() {
        let raw = [
            "Album/01 Song.flac",
            "/etc/passwd", // 绝对路径 → 拒
            "../escape.flac", // `..` 逃逸 → 拒
            "Album/../secret", // `..` 逃逸 → 拒
            "", // 空 → 拒
            "   ", // 空白 → 拒
            "./Album/01 Song.flac", // `./` 前缀 → 归一后与首条重复 → 去重
            "Album/02 Song.flac",
        ]
        #expect(SyncFetchRequest.normalize(raw) == ["Album/01 Song.flac", "Album/02 Song.flac"])
    }

    @Test("解码保留原始字符串：非法路径不被静默丢弃（要能进 failed）")
    func decodeKeepsRawPaths() throws {
        let json = #"{"collection":{"kind":"all","ids":[]},"relativePaths":["../escape.flac","ok.flac"]}"#
        let request = try SyncFetchCodec.decode(SyncFetchRequest.self, from: Data(json.utf8))
        #expect(request.relativePaths == ["../escape.flac", "ok.flac"])
    }

    // MARK: - 路径解析

    @Test("路径解析：根内路径解析为绝对 URL")
    func resolverAcceptsInsidePath() {
        let root = URL(fileURLWithPath: "/tmp/qqp-sync-root", isDirectory: true)
        let resolution = SyncLibraryPathResolver.resolve(relativePath: "Album/./01 Song.flac", root: root)
        #expect(resolution == .resolved(root.appendingPathComponent("Album/01 Song.flac")))
    }

    @Test("路径解析：非法路径一律拒绝并给出原因")
    func resolverRejectsInvalidPaths() {
        let root = URL(fileURLWithPath: "/tmp/qqp-sync-root", isDirectory: true)
        let cases: [(String, String)] = [
            ("/etc/passwd", SyncFetchFailureReason.invalidPath),
            ("../escape.flac", SyncFetchFailureReason.invalidPath),
            ("Album/../../escape.flac", SyncFetchFailureReason.invalidPath),
            ("", SyncFetchFailureReason.invalidPath),
            (".", SyncFetchFailureReason.invalidPath),
            ("..", SyncFetchFailureReason.invalidPath),
        ]
        for (path, reason) in cases {
            #expect(SyncLibraryPathResolver.resolve(relativePath: path, root: root) == .rejected(reason))
        }
    }
}
