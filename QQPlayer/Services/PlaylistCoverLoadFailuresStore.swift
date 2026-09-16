//
//  PlaylistCoverLoadFailuresStore.swift
//  QQPlayer
//
//  自定义封面**读取失败**的登记处（INV-22 另一半：定位不到必须计数，不许静默）。
//
//  形状（与 `SyncWiringFactsStore` / `MacLyricsResendFactsStore` 同族）：
//  - **写入方** = 封面解析入口的消费点（`PlaylistCoverResolver` 的调用点）：
//    读到 `.unavailable` / 解码失败 → `record`；读到（或该歌单已无自定义封面）→ `clear`；
//  - **去重粒度 = 歌单**（同一个歌单被渲染多少次都只算一个失败；这里数的是
//    「多少个歌单的封面出了问题」，不是「失败了多少次」——后者只会随滚动增长，没意义）；
//  - **读方** = 面板：行文案与格式由唯一投影 `SyncEntityOutcomeDisclosure.coverRows` 给，
//    界面层不得自己算（同一纪律见歌词的 `lyricsRows`）。
//
//  ⚠️ 只许解析消费点写入（谁解析谁申报）；UI 不得在这里补算任何事实。
//
// target: ios-only（消费点都在 iOS UI：歌单卡片 / 详情 / CarPlay / 设置页；Mac 侧没有歌单自定义封面消费点）
//

import Combine
import Foundation

@MainActor
final class PlaylistCoverLoadFailuresStore: ObservableObject {
    static let shared = PlaylistCoverLoadFailuresStore()

    /// 一个歌单的自定义封面读不到（按歌单去重）。
    struct Failure: Equatable, Identifiable {
        /// 歌单登记键（`PlaylistCoverResolver.playlistKey(id:slug:)`）
        var playlistKey: String
        /// DB 里存的自定义封面路径（设备本地相对路径，诊断用）
        var path: String
        /// 原因码（`PlaylistCoverResolver.Reason` 取值）
        var reason: String

        var id: String { playlistKey }
    }

    /// 失败清单（按歌单键升序；同一歌单只占一条）。
    @Published private(set) var failures: [Failure] = []

    private init() {}

    /// 出问题的歌单数（面板数字的唯一来源）。
    var count: Int { failures.count }

    /// 申报一次读取失败（同一歌单重复申报 = 覆盖，**不累加**；幂等）。
    func record(playlistKey: String, path: String, reason: String) {
        guard !playlistKey.isEmpty else { return }
        let failure = Failure(playlistKey: playlistKey, path: path, reason: reason)
        if let index = failures.firstIndex(where: { $0.playlistKey == playlistKey }) {
            guard failures[index] != failure else { return } // 无变化不发布（避免无谓刷新）
            failures[index] = failure
        } else {
            failures.append(failure)
            failures.sort { $0.playlistKey < $1.playlistKey }
        }
    }

    /// 读到封面（或该歌单已没有自定义封面）→ 清掉它的失败登记。
    func clear(playlistKey: String) {
        guard let index = failures.firstIndex(where: { $0.playlistKey == playlistKey }) else { return }
        failures.remove(at: index)
    }

    /// 全清（测试夹具 / 会话重置用）。
    func reset() {
        failures = []
    }
}
