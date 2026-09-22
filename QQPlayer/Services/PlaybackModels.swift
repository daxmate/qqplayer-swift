//  PlaybackModels.swift
//  QQPlayer
//
//  Playback models used by PlayerEngine: playback order modes, the fast
//  playback-position observable, and playback errors.
//
import Foundation
import Observation

/// 播放顺序四态：顺序播放 → 随机播放 → 循环列表 → 单曲循环 → 顺序播放
enum PlaybackOrderMode: Int, CaseIterable {
    case sequential = 0
    case shuffle = 1
    case repeatAll = 2
    case repeatOne = 3

    /// 播放顺序按钮图标：iOS 播放页 / CarPlay 页头 / Mac 播放条**共用唯一入口**。
    /// 各端视图不得自建映射（形状契约：PlaybackOrderIconContractTests）。
    ///
    /// 2026-09-16 统一记录：Mac 端曾在顺序态用 "arrow.right.to.line"（09-01 写的那份 switch
    /// 与 iOS 三态逐字相同、仅顺序态不同，且无注释/文档/测试记录理由）= 未记录的一次性偏差，
    /// 不是刻意保留的平台差异；经确认统一到本入口的取值。
    var systemImageName: String {
        switch self {
        case .sequential: return "arrow.clockwise"
        case .shuffle: return "shuffle"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        }
    }
}

/// Holds the fast-changing playback position so that only views showing the
/// progress bar/time labels re-render at the 10Hz timer rate. Observing
/// PlayerEngine itself must not subscribe views to these updates.
/// 2026-09-20 批 6-6：`ObservableObject` → `@Observable`（唯一属性 `playbackTime` 保持被追踪）。
/// 消费方式＝从引擎取实例后在 `body` 里读：`playerEngine.progress.playbackTime`（方案 B：
/// 进度只有一条到达路径，不再单独进环境，也没有 `@ObservedObject` 直连）。
@MainActor
@Observable
final class PlaybackProgress {
    var playbackTime: TimeInterval = 0
}

enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
    case audioEngineError
    case configurationError
}

/// 播放时间文案（mm:ss）的唯一入口：新消费点用这里，别再抄一份 `%d:%02d`。
enum PlaybackTimeFormat {
    /// 秒 → "m:ss" / "h:mm:ss"（负数归零；用于进度、时长、歌词时间轴等所有播放时间文案）
    static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// 「正在播放」标题位覆盖（车载歌词，2026-09-16）。
///
/// 由来（用户实测 + 外部取证）：CarPlay 的「正在播放」屏由系统接管，第三方 App 没有任何歌词控件
/// （iPhoneOS26.5 SDK 的 `CarPlay.framework` 全头文件 `grep -i lyric` 零命中）；QQ 音乐等 App 的
/// 做法是**把当前歌词行实时写进标题位**，系统屏上「大字=当前歌词、小字=歌手」，代价是曲名被顶掉。
///
/// 分工：**决策在车载层**（CarPlay 播放页控制器按当前句给出覆盖值，断连时清空），
/// **执行只有一处**——本文件的元数据构建（见 PlayerEngine+NowPlaying 的标题位写入）。
/// 两处各写一半字段会把封面/时长冲掉，所以覆盖值只以数据形式传，不各自改 MPNowPlayingInfoCenter。
enum NowPlayingTitleOverlay {
    /// 加锁小盒子：静态可变状态在 Swift 6 下必须显式表态（`@unchecked Sendable` + 内部加锁）
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        var title: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    private static let box = Box()

    /// 当前覆盖值（nil / 空串 = 用曲名）
    static var title: String? {
        get { box.title }
        set { box.title = newValue }
    }

    /// 标题位实际展示值：有覆盖用覆盖，否则回落曲名
    static func displayTitle(fallback: String) -> String {
        guard let override = title, !override.isEmpty else { return fallback }
        return override
    }
}

/// 异步落地前的同曲校验（纯函数，可单测）。
///
/// 背景（2026-09-12 审计 P5）：updateWidgetData 在函数入口捕获 track，中间经历
/// await 取封面 + 两次后台写盘，期间没有同曲校验 → 快速连点/自动切歌时，先发起的旧曲
/// 任务后落盘（saveCurrentTrack 同步写盘 + reloadAllTimelines），小组件显示上一首
/// 并一直保留到下次更新。入队时校验一次目标曲仍是当前曲，才允许写。
enum PlaybackTrackGate {
    static func isStillCurrent(trackId: String, currentTrackId: String?) -> Bool {
        trackId == currentTrackId
    }
}

/// 载入失败 → 用户可见文案 key（纯函数，可单测）。
///
/// 背景（2026-09-12 审计 P8）：DSD（dsf/dff）在本项目里没有任何可用引擎——native
/// `AVAudioFile` 打不开（openNativeAudioFile 对 dsf/dff 直接拒），SFB 失败时原本那条
/// "native fallback" 构造上必失败（被删，见 PlayerEngine+PlaybackControl）。原来失败全链
/// 只有 print，`playTrack` 拿到 false 就 return → 用户只看到“点了不播”。
enum PlaybackFailureMessage {
    static func messageKey(pathExtension: String) -> String {
        let ext = pathExtension.lowercased()
        if ext == "dsf" || ext == "dff" {
            return "playback_error_dsd_unsupported"
        }
        return "playback_error_generic"
    }
}

// MARK: - 载入/调度代数（2026-09-20 测试债批 ③ 抽自 PlayerEngine）

/// 载入/调度代数（纯逻辑，可单测）。
///
/// 语义（**唯一定义处**）：任何「开始新的一次异步操作」（切歌载入 / seek 重排调度 / 取消在途
/// 调度）都 `begin()` 取一个新代次；异步任务在写回前用 `canCommit(_:)` 校验 —— 代数已被后来者
/// 顶掉（`isCurrent == false`）**或**任务已取消 → 丢弃结果。
///
/// 为什么上收：原先 `loadGeneration` / `scheduleGeneration` 在 5 个文件里各自 `&+= 1` + 裸比较
/// （实测 15 处）。「切歌竞态写旧曲」（2026-09-12 审计 P4）就是漏了一处校验的形状：await 之前
/// 捕获的代，await 之后没人比对。抽成类型后代数语义只有一处实现，调用点只做 begin / canCommit，
/// 且形状契约（`PlaybackGenerationTests` 的扫描用例）禁止引擎里再出现裸自增 / 裸比较。
struct PlaybackGeneration {
    /// 当前代次（0 = 从未开始）。
    private(set) var current: UInt64 = 0

    /// 开始新代次并返回它（**唯一**递增入口）。
    /// 保持原 `&+= 1` 的回绕语义 —— 回绕属既有行为，本批**刻意不改**。
    @discardableResult
    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    /// 该代次是否仍是当前代（= 期间没有更新的操作）。
    func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }

    /// 异步结果能否写回：代数仍是当前 **且** 任务未取消。
    /// - Parameter isCancelled: 默认取当前任务的取消态（调用点即 `Task.isCancelled`）；测试可注入。
    func canCommit(_ generation: UInt64, isCancelled: Bool = Task.isCancelled) -> Bool {
        isCurrent(generation) && !isCancelled
    }
}

/// 队列归一：空队列 / 当前曲不在队列 / 下标越界时的收敛决策（纯函数，可单测）。
///
/// 2026-09-20 抽自 `PlayerEngine.normalizeIndexAndTrack`（测试债批 ③）：它有 **9 个调用点**
/// （队列整体替换 / 重排 / 删除 / 恢复 / 清空 / 恢复原始队列 / Mac 两处），是本仓最热的
/// 「队列被异步替换之后修索引」入口，却一条测试都没有。
enum PlaybackQueueSelection {
    /// 归一结果：`trackId == nil` 表示「清空当前曲」（仅空队列时会出现）。
    struct Result: Equatable {
        var index: Int
        var trackId: String?
    }

    /// 规则（逐条对应原实现）：
    /// - 空队列 → `(0, nil)`：索引归 0、当前曲清空
    /// - 当前曲仍在队列里 → 取它**现在**的下标（队列被整体替换后原下标会陈旧）
    /// - 当前曲不在队列里（或本来就没有当前曲）→ 下标夹到 `[0, count-1]`，并取该位置的曲目
    static func normalized(queueTrackIds: [String], currentTrackId: String?, currentIndex: Int) -> Result {
        guard !queueTrackIds.isEmpty else { return Result(index: 0, trackId: nil) }
        if let currentTrackId, let index = queueTrackIds.firstIndex(of: currentTrackId) {
            return Result(index: index, trackId: currentTrackId)
        }
        let clamped = max(0, min(currentIndex, queueTrackIds.count - 1))
        return Result(index: clamped, trackId: queueTrackIds[clamped])
    }
}

/// 无缝衔接的格式兼容判定（纯函数，可单测）。
///
/// 2026-09-20 抽自 `PlayerEngine+AudioScheduling.canGaplesslySchedule`（测试债批 ③）：原实现直接
/// 比较 `AVAudioFile.processingFormat`，而 `AVAudioFormat` 要真实音频文件才能构造 ⇒「什么时候能
/// 无缝、什么时候必须走普通预载」这条决策在测试里一点也碰不到。抽成「四个字段的取值结构」后判定
/// 可单测，引擎只负责把 `AVAudioFormat` 映射成这个结构。
enum GaplessFormatCompatibility {
    /// 判定所需的格式取值（`commonFormatRawValue` = `AVAudioCommonFormat.rawValue`，
    /// 避免本文件依赖 AVFoundation —— 映射在引擎侧）。
    struct Traits: Equatable {
        var sampleRate: Double
        var channelCount: UInt32
        var commonFormatRawValue: UInt
        var isInterleaved: Bool
    }

    /// 无缝衔接要求（与原实现逐条一致）：
    /// 采样率差 < 0.1、声道数 / 通用格式 / 交错布局全等。
    static func canSchedule(current: Traits, next: Traits) -> Bool {
        abs(current.sampleRate - next.sampleRate) < 0.1
            && current.channelCount == next.channelCount
            && current.commonFormatRawValue == next.commonFormatRawValue
            && current.isInterleaved == next.isInterleaved
    }
}
