//
//  SyncManifestTests.swift
//  QQPlayerTests
//
//  S2 M3-3a 文件 manifest 模型 / 生成器 / 集合过滤纯逻辑：
//  - ManifestEntry / SyncManifestRequest / SyncManifestResponse Codable roundtrip
//  - SyncFrameType 新 case（manifestRequest=10 / manifestResponse=11）编解码
//  - SyncManifestGenerator：路径规范化（非法路径丢弃）/ 哈希映射覆盖 / 去重 /
//    排序确定性 / 相对路径基准
//  - SyncCollection：.all / .playlists / .tracks 过滤语义 + 空选择
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncManifestTests {
    // MARK: - 模型编解码

    @Test("ManifestEntry / 请求 / 响应 Codable roundtrip")
    func payloadRoundtrip() throws {
        let entry = ManifestEntry(
            relativePath: "Album/01 Song.flac",
            size: 12_345,
            mtimeMs: 1_700_000_000_000,
            contentHash: "abc123",
            stableId: "stable-1"
        )
        let request = SyncManifestRequest(collection: .playlists(["mix"]), knownHashes: ["a": "b"])
        let response = SyncManifestResponse(entries: [entry], rootName: "QQPlayer")

        let requestData = try SyncManifestCodec.encode(request)
        #expect(try SyncManifestCodec.decode(SyncManifestRequest.self, from: requestData) == request)

        let responseData = try SyncManifestCodec.encode(response)
        let decoded = try SyncManifestCodec.decode(SyncManifestResponse.self, from: responseData)
        #expect(decoded == response)
        #expect(decoded.entries[0].contentHash == "abc123")
    }

    @Test("缺省字段可解码：老版本载荷（无 contentHash/stableId/knownHashes）不炸")
    func decodingWithoutOptionalFields() throws {
        // 手写 JSON：模拟"更早的发送方没带可选字段"
        let json = Data("""
        {"collection":{"kind":"all","ids":[]}}
        """.utf8)
        let request = try SyncManifestCodec.decode(SyncManifestRequest.self, from: json)
        #expect(request.collection == .all)
        #expect(request.knownHashes == nil)

        let entryJSON = Data("""
        {"relativePath":"a.flac","size":10,"mtimeMs":20}
        """.utf8)
        let entry = try SyncManifestCodec.decode(ManifestEntry.self, from: entryJSON)
        #expect(entry.contentHash == nil)
        #expect(entry.stableId == nil)
    }

    @Test("SyncFrameType 新 case：manifestRequest/manifestResponse 编解码 roundtrip")
    func frameTypeRoundtrip() throws {
        for type in [SyncFrameType.manifestRequest, SyncFrameType.manifestResponse] {
            #expect(type.rawValue >= 10) // 增量追加，不与既有 0-9 冲突
            let frame = SyncFrame(type: type, flags: [.encrypted], payload: Data("p-\(type.rawValue)".utf8))
            let encoded = try frame.encode()
            let (decoded, consumed) = try SyncFrame.decode(from: encoded)
            #expect(decoded == frame)
            #expect(consumed == encoded.count)
            #expect(decoded.type == type)
        }
    }

    @Test("既有帧类型值不因新增而漂移（线上兼容）")
    func existingFrameValuesStable() {
        #expect(SyncFrameType.handshake.rawValue == 0)
        #expect(SyncFrameType.pairRequest.rawValue == 1)
        #expect(SyncFrameType.pairResponse.rawValue == 2)
        #expect(SyncFrameType.ping.rawValue == 3)
        #expect(SyncFrameType.fileMeta.rawValue == 4)
        #expect(SyncFrameType.fileChunk.rawValue == 5)
        #expect(SyncFrameType.fileAck.rawValue == 6)
        #expect(SyncFrameType.bye.rawValue == 7)
        #expect(SyncFrameType.changeLogPull.rawValue == 8)
        #expect(SyncFrameType.changeLogPush.rawValue == 9)
    }

    // MARK: - 生成器

    @Test("生成器：输出按路径升序、字段原样保留（确定性）")
    func generateSortsAndPreserves() {
        let files = [
            SyncManifestSourceFile(relativePath: "b.flac", size: 2, mtimeMs: 20, contentHash: "h-b", stableId: "s-b"),
            SyncManifestSourceFile(relativePath: "a/1.flac", size: 1, mtimeMs: 10, contentHash: "h-1", stableId: "s-1"),
        ]
        let entries = SyncManifestGenerator.generate(files: files)
        #expect(entries.map(\.relativePath) == ["a/1.flac", "b.flac"])
        #expect(entries[0].size == 1)
        #expect(entries[0].mtimeMs == 10)
        #expect(entries[0].contentHash == "h-1")
        #expect(entries[0].stableId == "s-1")
    }

    @Test("生成器：contentHashes 映射覆盖 source 自带哈希（指纹是权威事实）")
    func generateOverridesHashFromMap() {
        let files = [SyncManifestSourceFile(relativePath: "a.flac", size: 1, contentHash: "stale")]
        let entries = SyncManifestGenerator.generate(files: files, contentHashes: ["a.flac": "fresh"])
        #expect(entries[0].contentHash == "fresh")
    }

    @Test("生成器：非法路径丢弃（绝对路径 / .. 逃逸 / 空），不做顺手修正")
    func generateDropsInvalidPaths() {
        let files = [
            SyncManifestSourceFile(relativePath: "/etc/passwd", size: 1),
            SyncManifestSourceFile(relativePath: "../escape.flac", size: 1),
            SyncManifestSourceFile(relativePath: "ok/../../escape2.flac", size: 1),
            SyncManifestSourceFile(relativePath: "   ", size: 1),
            SyncManifestSourceFile(relativePath: "", size: 1),
            SyncManifestSourceFile(relativePath: "ok.flac", size: 1),
        ]
        let entries = SyncManifestGenerator.generate(files: files)
        #expect(entries.map(\.relativePath) == ["ok.flac"])
    }

    @Test("生成器：路径规范化（./ 前缀 / 重复斜杠 / 反斜杠）+ 同路径去重 later wins")
    func generateNormalizesAndDedupes() {
        let files = [
            SyncManifestSourceFile(relativePath: "./Album//01.flac", size: 1, contentHash: "old"),
            SyncManifestSourceFile(relativePath: "Album/01.flac", size: 2, contentHash: "new"),
            SyncManifestSourceFile(relativePath: "Album\\02.flac", size: 3),
        ]
        let entries = SyncManifestGenerator.generate(files: files)
        #expect(entries.map(\.relativePath) == ["Album/01.flac", "Album/02.flac"])
        #expect(entries[0].size == 2)
        #expect(entries[0].contentHash == "new")
    }

    @Test("生成器：相对路径基准（曲库根内出路径，根外/根本身 → nil）")
    func relativePathAgainstBaseDirectory() {
        let base = URL(fileURLWithPath: "/Users/x/Music/QQPlayer")
        #expect(
            SyncManifestGenerator.relativePath(
                of: URL(fileURLWithPath: "/Users/x/Music/QQPlayer/A/1.flac"),
                baseDirectory: base
            ) == "A/1.flac"
        )
        // 尾斜杠基准等价
        #expect(
            SyncManifestGenerator.relativePath(
                of: URL(fileURLWithPath: "/Users/x/Music/QQPlayer/A/1.flac"),
                baseDirectory: URL(fileURLWithPath: "/Users/x/Music/QQPlayer/")
            ) == "A/1.flac"
        )
        #expect(
            SyncManifestGenerator.relativePath(
                of: URL(fileURLWithPath: "/Users/x/Music/Other/1.flac"),
                baseDirectory: base
            ) == nil
        )
        #expect(
            SyncManifestGenerator.relativePath(of: base, baseDirectory: base) == nil
        )
    }

    // MARK: - 集合过滤

    private func entries() -> [ManifestEntry] {
        [
            ManifestEntry(relativePath: "a.flac", size: 1, mtimeMs: 0, contentHash: "h-a", stableId: "s-a"),
            ManifestEntry(relativePath: "b.flac", size: 1, mtimeMs: 0, contentHash: "h-b", stableId: "s-b"),
            ManifestEntry(relativePath: "c.flac", size: 1, mtimeMs: 0, contentHash: "h-c", stableId: "s-c"),
            ManifestEntry(relativePath: "orphan.flac", size: 1, mtimeMs: 0, contentHash: "h-o", stableId: nil),
        ]
    }

    @Test("集合 .all：全部条目（含未映射 stableId 的孤儿文件）")
    func collectionAll() {
        let filtered = SyncCollection.all.filter(entries())
        #expect(filtered.map(\.relativePath) == ["a.flac", "b.flac", "c.flac", "orphan.flac"])
        #expect(SyncCollection.all.selectedStableIds(members: SyncCollectionMembers()) == nil)
    }

    @Test("集合 .tracks：只留勾选歌曲；未映射条目被排除")
    func collectionTracks() {
        let filtered = SyncCollection.tracks(["s-a", "s-c"]).filter(entries())
        #expect(filtered.map(\.relativePath) == ["a.flac", "c.flac"])
    }

    @Test("集合 .playlists：取歌单成员并集；未知歌单 → 空集（宁少不误删）")
    func collectionPlaylists() {
        let members = SyncCollectionMembers(stableIdsByPlaylist: ["mix": ["s-a", "s-b"], "live": ["s-c"]])
        #expect(
            SyncCollection.playlists(["mix", "live"]).filter(entries(), members: members)
                .map(\.relativePath) == ["a.flac", "b.flac", "c.flac"]
        )
        #expect(SyncCollection.playlists(["ghost"]).filter(entries(), members: members) == [])
        #expect(SyncCollection.playlists(["mix"]).filter(entries()) == [])
    }

    @Test("集合空选择：.playlists([]) / .tracks([]) 与 .all 语义相反")
    func collectionEmptySelection() {
        #expect(SyncCollection.all.isEmptySelection == false)
        #expect(SyncCollection.playlists([]).isEmptySelection)
        #expect(SyncCollection.tracks([]).isEmptySelection)
        #expect(SyncCollection.playlists([]).filter(entries()) == [])
    }

    @Test("集合 Codable：kind + ids 往返（跨端载荷形态锁定）")
    func collectionCodable() throws {
        for collection in [SyncCollection.all, .playlists(["p1", "p2"]), .tracks(["t1"])] {
            let data = try SyncManifestCodec.encode(collection)
            #expect(try SyncManifestCodec.decode(SyncCollection.self, from: data) == collection)
        }
        let json = try SyncManifestCodec.encode(SyncCollection.tracks(["t1"]))
        let text = try #require(String(data: json, encoding: .utf8))
        #expect(text.contains("\"kind\":\"tracks\""))
        #expect(text.contains("\"ids\":[\"t1\"]"))
    }
}
