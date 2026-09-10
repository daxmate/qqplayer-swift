//
//  SyncManifestReconcileTests.swift
//  QQPlayerTests
//
//  S2 M3-3a 对账纯逻辑 + manifest 帧会话往返：
//  - SyncManifestReconciler：缺失 / 内容差异 / 远端删除 / 私有区豁免 / 集合外忽略 /
//    幂等重跑 / 未指纹保守判拉取
//  - SyncDeleteScope + deleteScope(collection:...) 桥接（集合 → 删除范围）
//  - SyncManifestPeer：会话往返（client 请求 → host 提供者应答 → client 收到）、
//    请求集合透传、提供者未接线不应答（防空 manifest 误删）
//
//  fixture 复用 SyncPeerSessionTestSupport.swift（SessionFixture 双 ready 回环）。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncManifestReconcileTests {
    // MARK: - 工具

    private func entry(
        _ path: String,
        hash: String?,
        size: Int64 = 100,
        stableId: String? = nil
    ) -> ManifestEntry {
        ManifestEntry(relativePath: path, size: size, mtimeMs: 0, contentHash: hash, stableId: stableId)
    }

    // MARK: - 对账

    @Test("对账：本地缺失 → toFetch；内容相同 → unchanged")
    func reconcileMissingAndUnchanged() {
        let remote = [entry("a.flac", hash: "h-a"), entry("b.flac", hash: "h-b")]
        let local = [entry("a.flac", hash: "h-a")]
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local)
        #expect(result.toFetch.map(\.relativePath) == ["b.flac"])
        #expect(result.unchanged.map(\.relativePath) == ["a.flac"])
        #expect(result.toDelete.isEmpty)
        #expect(result.protectedSkipped.isEmpty)
    }

    @Test("对账：同路径内容不同 → toFetch（不沿用本地文件）")
    func reconcileContentMismatch() {
        let remote = [entry("a.flac", hash: "h-new")]
        let local = [entry("a.flac", hash: "h-old")]
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local)
        #expect(result.toFetch.map(\.relativePath) == ["a.flac"])
        #expect(result.unchanged.isEmpty)
        #expect(result.toDelete.isEmpty)
    }

    @Test("对账：任一侧未指纹（nil hash）→ 保守判 toFetch")
    func reconcileUnknownHashFetches() {
        let remote = [entry("a.flac", hash: nil), entry("b.flac", hash: "h-b")]
        let local = [entry("a.flac", hash: "h-a"), entry("b.flac", hash: nil)]
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local)
        #expect(result.toFetch.map(\.relativePath) == ["a.flac", "b.flac"])
        #expect(result.unchanged.isEmpty)
    }

    @Test("对账：远端消失的本地条目 → toDelete（全库镜像范围）")
    func reconcileRemoteDeletion() {
        let remote = [entry("keep.flac", hash: "h-k")]
        let local = [entry("keep.flac", hash: "h-k"), entry("gone.flac", hash: "h-g")]
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local)
        #expect(result.toDelete.map(\.relativePath) == ["gone.flac"])
        #expect(result.toFetch.isEmpty)
        #expect(result.unchanged.map(\.relativePath) == ["keep.flac"])
    }

    @Test("★私有区保护：远端没有的本地私有条目永不进 toDelete（逐个豁免可观测）")
    func reconcilePrivateZoneProtected() {
        let remote: [ManifestEntry] = []
        let local = [
            entry("synced.flac", hash: "h-1"),
            entry("Imported/manual.m4a", hash: "h-2"),
            entry("UnpairedSong.flac", hash: "h-3"),
        ]
        let scope = SyncDeleteScope(
            managedRelativePaths: nil,
            protectedRelativePaths: ["Imported/manual.m4a", "UnpairedSong.flac"]
        )
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local, deleteScope: scope)
        #expect(result.toDelete.map(\.relativePath) == ["synced.flac"])
        #expect(result.protectedSkipped.map(\.relativePath) == ["Imported/manual.m4a", "UnpairedSong.flac"])
        // 私有区条目绝不出现在任何删除列表
        for skipped in result.protectedSkipped {
            #expect(!result.toDelete.contains(skipped))
        }
    }

    @Test("对账：不在同步集合内的本地条目既不删也不豁免（同步不越界）")
    func reconcileOutOfCollectionIgnored() {
        let remote: [ManifestEntry] = []
        let local = [entry("inMix.flac", hash: "h-1", stableId: "s-1"), entry("other.flac", hash: "h-2", stableId: "s-9")]
        let scope = SyncDeleteScope(managedRelativePaths: ["inMix.flac"], protectedRelativePaths: [])
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local, deleteScope: scope)
        #expect(result.toDelete.map(\.relativePath) == ["inMix.flac"])
        #expect(result.protectedSkipped.isEmpty)
        #expect(result.toFetch.isEmpty)
        #expect(result.unchanged.isEmpty)
    }

    @Test("对账幂等：远端 == 本地 重跑无 fetch/无 delete（isEmpty）")
    func reconcileIdempotent() {
        let manifest = [
            entry("a.flac", hash: "h-a"),
            entry("dir/b.flac", hash: "h-b"),
            entry("dir/c.flac", hash: "h-c"),
        ]
        let first = SyncManifestReconciler.reconcile(remote: manifest, local: manifest)
        #expect(first.isEmpty)
        #expect(first.unchanged.count == 3)
        // 用首次结果再跑一遍（幂等：状态不因重复对账漂移）
        let second = SyncManifestReconciler.reconcile(remote: manifest, local: manifest)
        #expect(second == first)
    }

    @Test("对账：重复路径 later wins（调用方给的是最终快照）")
    func reconcileDuplicatesLastWins() {
        let remote = [entry("a.flac", hash: "h-old"), entry("a.flac", hash: "h-new")]
        let local = [entry("a.flac", hash: "h-new")]
        let result = SyncManifestReconciler.reconcile(remote: remote, local: local)
        #expect(result.toFetch.isEmpty)
        #expect(result.unchanged.map(\.relativePath) == ["a.flac"])
    }

    @Test("删除范围桥接：集合过滤后的本地条目 = managed；私有区并集豁免")
    func deleteScopeFromCollection() {
        let local = [
            entry("a.flac", hash: "h-a", stableId: "s-a"),
            entry("b.flac", hash: "h-b", stableId: "s-b"),
            entry("private.m4a", hash: "h-p", stableId: nil),
        ]
        let members = SyncCollectionMembers(stableIdsByPlaylist: ["mix": ["s-a"]])
        let scope = SyncManifestReconciler.deleteScope(
            collection: .playlists(["mix"]),
            members: members,
            localEntries: local,
            protectedRelativePaths: ["private.m4a"]
        )
        #expect(scope.managedRelativePaths == ["a.flac"])
        #expect(scope.manages("a.flac"))
        #expect(!scope.manages("b.flac")) // 集合外
        #expect(!scope.manages("private.m4a")) // 私有区优先

        // 端到端：远端空（歌单被清空）→ 仅集合内条目待删，私有区豁免
        let result = SyncManifestReconciler.reconcile(remote: [], local: local, deleteScope: scope)
        #expect(result.toDelete.map(\.relativePath) == ["a.flac"])
        #expect(result.protectedSkipped.map(\.relativePath) == ["private.m4a"])
    }

    @Test("删除范围：.all + 无豁免 = 全库镜像（mirrorAll 等价）")
    func deleteScopeMirrorAll() {
        let local = [entry("a.flac", hash: "h-a"), entry("b.flac", hash: "h-b")]
        let scope = SyncManifestReconciler.deleteScope(collection: .all, localEntries: local)
        #expect(scope == SyncDeleteScope.mirrorAll)
        #expect(scope.manages("a.flac"))
        #expect(!scope.isProtected("a.flac"))
    }

    @Test("contentMatches 独立可测：双侧非空且相等才一致")
    func contentMatchRule() {
        #expect(SyncManifestReconciler.contentMatches(local: entry("a", hash: "h"), remote: entry("a", hash: "h")))
        #expect(!SyncManifestReconciler.contentMatches(local: entry("a", hash: "h"), remote: entry("a", hash: "x")))
        #expect(!SyncManifestReconciler.contentMatches(local: entry("a", hash: nil), remote: entry("a", hash: "h")))
        #expect(!SyncManifestReconciler.contentMatches(local: entry("a", hash: "h"), remote: entry("a", hash: nil)))
        #expect(!SyncManifestReconciler.contentMatches(local: entry("a", hash: nil), remote: entry("a", hash: nil)))
    }

    // MARK: - 会话往返（分发钩子）

    /// 双 ready 会话 + 双端 SyncManifestPeer。⚠️ peer 必须强持有：SyncManifestPeer
    /// 以 [weak self] 挂接会话 onApplicationFrame，创建后即弃会被 ARC 释放 → 永不
    /// 应答（同 SyncChangeLogFrameTests 的 CI 教训）。
    private struct PeerHarness {
        let fixture: SessionFixture
        let hostPeer: SyncManifestPeer
        let clientPeer: SyncManifestPeer
    }

    private func makeHarness() -> PeerHarness {
        let fixture = SessionFixture.pairedHandshake()
        return PeerHarness(
            fixture: fixture,
            hostPeer: SyncManifestPeer(session: fixture.hostSession),
            clientPeer: SyncManifestPeer(session: fixture.clientSession)
        )
    }

    @Test("会话往返：client 请求 manifest → host 提供者应答 → client 收到条目 + 根名")
    func peerRoundtrip() throws {
        let harness = makeHarness()
        let hostEntries = [
            entry("a.flac", hash: "h-a", stableId: "s-a"),
            entry("dir/b.flac", hash: "h-b", stableId: "s-b"),
        ]
        var requestedCollections: [SyncCollection] = []
        harness.hostPeer.localManifestProvider = { collection in
            requestedCollections.append(collection)
            return hostEntries
        }
        harness.hostPeer.localRootName = { "Mac 曲库" }

        var received: [SyncManifestResponse] = []
        harness.clientPeer.onManifestReceived = { received.append($0) }

        try harness.clientPeer.requestManifest(collection: .tracks(["s-a"]))

        #expect(requestedCollections == [.tracks(["s-a"])]) // 集合参数透传
        #expect(received.count == 1)
        #expect(received[0].entries == hostEntries)
        #expect(received[0].rootName == "Mac 曲库")
    }

    @Test("会话往返：反向（host 请求 client 曲库 manifest）也通")
    func peerRoundtripReverse() throws {
        let harness = makeHarness()
        harness.clientPeer.localManifestProvider = { _ in [self.entry("phone.flac", hash: "h-p")] }
        var received: [SyncManifestResponse] = []
        harness.hostPeer.onManifestReceived = { received.append($0) }

        try harness.hostPeer.requestManifest()

        #expect(received.first?.entries.map(\.relativePath) == ["phone.flac"])
        #expect(received.first?.rootName == nil)
    }

    @Test("★安全：host 提供者未接线 → 不应答（不回空 manifest 免对端误删）")
    func peerUnavailableProviderDoesNotRespond() throws {
        let harness = makeHarness()
        var unavailableCount = 0
        harness.hostPeer.onProviderUnavailable = { unavailableCount += 1 }
        var received: [SyncManifestResponse] = []
        harness.clientPeer.onManifestReceived = { received.append($0) }

        try harness.clientPeer.requestManifest()

        #expect(unavailableCount == 1)
        #expect(received.isEmpty)
    }

    @Test("会话往返：对账闭环——远端 manifest 到本地后直接出 toFetch 决策")
    func peerRoundtripFeedsReconcile() throws {
        let harness = makeHarness()
        harness.hostPeer.localManifestProvider = { _ in
            [
                self.entry("same.flac", hash: "h-s"),
                self.entry("new.flac", hash: "h-n"),
            ]
        }
        let local = [self.entry("same.flac", hash: "h-s")]
        var reconciliation: SyncManifestReconciliation?
        harness.clientPeer.onManifestReceived = { response in
            reconciliation = SyncManifestReconciler.reconcile(remote: response.entries, local: local)
        }

        try harness.clientPeer.requestManifest()

        #expect(reconciliation?.toFetch.map(\.relativePath) == ["new.flac"])
        #expect(reconciliation?.unchanged.map(\.relativePath) == ["same.flac"])
    }
}
