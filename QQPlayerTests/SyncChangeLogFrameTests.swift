//
//  SyncChangeLogFrameTests.swift
//  QQPlayerTests
//
//  S2 M4-1 changeLog 帧编解码 + 会话层往返测试：
//  - SyncFrameType 新 case（changeLogPull=8 / changeLogPush=9）编解码 roundtrip
//  - SyncChangeLogPullRequest / SyncChangeLogPushPayload Codable roundtrip
//  - 会话层往返（双 ready 会话 + 各自内存 DB + SyncChangeLogPeer）：
//    host 业务写入 → client sendPull → host 自动应答 push → client 对账应用 →
//    client 本地行出现 + 游标推进到 host outbox 末尾
//
// fixture 复用 SyncPeerSessionTestSupport.swift（SessionFixture 双 ready 回环）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct SyncChangeLogFrameTests {
    // MARK: - 帧类型 + 载荷 roundtrip

    @Test("SyncFrameType 新 case：changeLogPull/changeLogPush 编解码 roundtrip")
    func frameTypeRoundtrip() throws {
        for type in [SyncFrameType.changeLogPull, SyncFrameType.changeLogPush] {
            let payload = Data("payload-\(type.rawValue)".utf8)
            let frame = SyncFrame(type: type, flags: [.encrypted], payload: payload)
            let encoded = try frame.encode()
            let (decoded, consumed) = try SyncFrame.decode(from: encoded)
            #expect(decoded == frame)
            #expect(consumed == encoded.count)
            #expect(decoded.type == type)
        }
    }

    @Test("SyncChangeLogPullRequest / SyncChangeLogPushPayload Codable roundtrip")
    func payloadRoundtrip() throws {
        let pull = SyncChangeLogPullRequest(cursor: 42)
        let pullJSON = try JSONEncoder().encode(pull)
        #expect(try JSONDecoder().decode(SyncChangeLogPullRequest.self, from: pullJSON) == pull)

        let entry = SyncChangeLogWireEntry(
            id: 7, entity: SyncChangeEntity.favorite.rawValue, rowKey: "t1",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 123, contentHash: nil,
            payloadJSON: "{\"track_stable_id\":\"t1\"}"
        )
        let push = SyncChangeLogPushPayload(entries: [entry], lastOutboxID: 7)
        let pushJSON = try JSONEncoder().encode(push)
        let decoded = try JSONDecoder().decode(SyncChangeLogPushPayload.self, from: pushJSON)
        #expect(decoded == push)
        #expect(decoded.entries[0].contentHash == nil) // M3-1 未合入，v1 恒 nil
    }

    // MARK: - 会话层往返

    /// 一套独立往返环境：双 ready 会话 + host/client 各自内存 DB + 双 SyncChangeLogPeer。
    /// ⚠️ host/client peer 都必须强持有：SyncChangeLogPeer 以 [weak self] 挂接会话
    /// onApplicationFrame，若创建后即弃（`_ =`），ARC 会释放 peer → host 永不
    /// 应答 pull，往返测试全挂（2026-09-10 CI 红修复）。
    private struct PeerHarness {
        let fixture: SessionFixture
        let hostQueue: DatabaseQueue
        let clientQueue: DatabaseQueue
        let hostStore: SyncChangeLogStore
        let clientStore: SyncChangeLogStore
        let hostPeer: SyncChangeLogPeer
        let clientPeer: SyncChangeLogPeer
    }

    private func makeHarness() throws -> PeerHarness {
        let fixture = SessionFixture.pairedHandshake()
        let hostQueue = try DatabaseQueue()
        let hostManager = DatabaseManager(dbWriter: hostQueue)
        try hostManager.createTables()
        let clientQueue = try DatabaseQueue()
        let clientManager = DatabaseManager(dbWriter: clientQueue)
        try clientManager.createTables()
        let hostStore = SyncChangeLogStore(database: hostManager)
        let clientStore = SyncChangeLogStore(database: clientManager)
        let hostPeer = SyncChangeLogPeer(
            session: fixture.hostSession,
            store: hostStore,
            applier: SyncChangeLogApplier(database: hostManager),
            peerID: fixture.clientIdentity.deviceID
        )
        let clientPeer = SyncChangeLogPeer(
            session: fixture.clientSession,
            store: clientStore,
            applier: SyncChangeLogApplier(database: clientManager),
            peerID: fixture.hostIdentity.deviceID
        )
        return PeerHarness(
            fixture: fixture, hostQueue: hostQueue, clientQueue: clientQueue,
            hostStore: hostStore, clientStore: clientStore,
            hostPeer: hostPeer, clientPeer: clientPeer
        )
    }

    @Test("会话往返：host 收藏写入 → client pull → host 应答 push → client 应用出 favorite 行 + 游标推进")
    func sessionRoundtripFavorite() throws {
        let harness = try makeHarness()

        // host 业务写入（模拟 addToFavorites 的 outbox 形态：favorite upsert）
        try harness.hostQueue.write { db in
            try SyncChangeLogStore.record(
                db,
                entity: .favorite,
                rowKey: "sync-fav",
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "sync-fav")),
                updatedAtMs: 1000
            )
        }
        #expect(try harness.hostStore.maxOutboxID() == 1)

        // client 主动 pull（带自己游标 0）。内存回环同步投递：
        // pull 帧 → host handlePull 自动应答 push → client handlePush 对账应用，sendPull 返回时已完成。
        try harness.clientPeer.sendPull()

        try harness.clientQueue.read { db in
            let count = try Favorite.filter(Column("track_stable_id") == "sync-fav").fetchCount(db)
            #expect(count == 1)
        }
        // client 游标推进到 host outbox 末尾；host 侧游标未被污染（host 只应答不消费）
        #expect(try harness.clientStore.cursor(forPeer: harness.clientPeer.peerID) == 1)
        #expect(try harness.hostStore.cursor(forPeer: harness.clientPeer.peerID) == 0)
    }

    @Test("会话往返：host 建歌单+加歌 → client pull → 本地出现歌单与 item（结构同步）")
    func sessionRoundtripPlaylist() throws {
        let harness = try makeHarness()

        let now: Int64 = 1000
        let playlistSnap = SyncPlaylistSnapshot(
            slug: "mix", title: "Mix", createdAt: now, updatedAt: now, lastPlayedAt: 0,
            folderPath: nil, isFolderSynced: false, lastFolderSync: nil, customCoverImagePath: nil
        )
        let itemSnap = SyncPlaylistItemSnapshot(playlistSlug: "mix", position: 1, trackStableId: "t1")
        try harness.hostQueue.write { db in
            try SyncChangeLogStore.record(
                db, entity: .playlist, rowKey: "mix", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(playlistSnap), updatedAtMs: now
            )
            try SyncChangeLogStore.record(
                db, entity: .playlistItem, rowKey: itemSnap.rowKey, op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(itemSnap), updatedAtMs: now
            )
        }
        #expect(try harness.hostStore.maxOutboxID() == 2)

        try harness.clientPeer.sendPull()

        try harness.clientQueue.read { db in
            let playlist = try Playlist.filter(Column("slug") == "mix").fetchOne(db)
            #expect(playlist?.title == "Mix")
            let itemCount = try PlaylistItem.fetchCount(db)
            #expect(itemCount == 1)
        }
        #expect(try harness.clientStore.cursor(forPeer: harness.clientPeer.peerID) == 2)
    }

    @Test("会话往返：LWW——client 已有更新版本的同键行，host 旧版本 push 不覆盖")
    func sessionRoundtripLWWNoDowngrade() throws {
        let harness = try makeHarness()

        // client 本地已有同 slug 歌单且 updated_at 更新（本端胜）
        let clientNow: Int64 = 5000
        try harness.clientQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO playlist (slug, title, created_at, updated_at, last_played_at, is_folder_synced)
                VALUES ('mix', 'Client Newer', 100, ?, 0, 0)
                """,
                arguments: [clientNow]
            )
            // client 自己的 outbox 代表本端事实（时间序新）
            try SyncChangeLogStore.record(
                db, entity: .playlist, rowKey: "mix", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistSnapshot(
                    slug: "mix", title: "Client Newer", createdAt: 100, updatedAt: clientNow,
                    lastPlayedAt: 0, folderPath: nil, isFolderSynced: false,
                    lastFolderSync: nil, customCoverImagePath: nil
                )),
                updatedAtMs: clientNow
            )
        }

        // host 推送旧版本（updated_at = 1000 < client 5000）
        try harness.hostQueue.write { db in
            try SyncChangeLogStore.record(
                db, entity: .playlist, rowKey: "mix", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistSnapshot(
                    slug: "mix", title: "Host Old", createdAt: 100, updatedAt: 1000,
                    lastPlayedAt: 0, folderPath: nil, isFolderSynced: false,
                    lastFolderSync: nil, customCoverImagePath: nil
                )),
                updatedAtMs: 1000
            )
        }

        try harness.clientPeer.sendPull()

        // client 本地仍是自己的新版本（未被降级覆盖）
        try harness.clientQueue.read { db in
            let playlist = try Playlist.filter(Column("slug") == "mix").fetchOne(db)
            #expect(playlist?.title == "Client Newer")
        }
    }
}
