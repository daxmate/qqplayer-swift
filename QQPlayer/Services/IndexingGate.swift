//  IndexingGate.swift
//  QQPlayer
//
//  等待曲库索引结束的**唯一实现**（审计 B5 · 🟡-2 / 🟡-3）。
//
//  修前两套机制并存：
//   - ContentView.performManualSync / performRefresh：`while isIndexing { sleep(0.1s) }` 忙等轮询
//   - LibraryView.runSync：裸 continuation，仅靠 onChange(isIndexing) 唤醒
//  两套都在等同一件事；且裸 continuation 若在挂起期间视图销毁 / isIndexing 因索引异常
//  不再回落，就永不 resume → isRefreshing 永久 true、同步按钮永久禁用、下拉刷新被挡。
//
//  收敛后：订阅 isIndexing（无忙等、可取消）+ 超时兜底（到期放行，用户不会被永久卡住）。
//  决策下沉为纯逻辑 IndexingWaitPolicy；等待本身可注入状态源，均可单测。
//
//  2026-09-19 追加注入点 `IndexingWaitSleeping`（唯一生产实现 `TaskSleepSleeper`）：
//  超时兜底原先直接 `Task.sleep`，导致唯一能证明「超时真的会放行」的用例只能断言墙钟
//  ——而 CI 模拟器把 MainActor 定时器唤醒放大 60x~345x（0.2s 策略实测 12.2s / 69.0s，
//  run 34702157359 / 35334674871），墙钟上界两次放宽到 60s 后仍被击穿。
//  把「睡」抽成 seam 后，超时路径与正常放行路径都能确定性验证，与 runner 饿不饿无关。
//
//  2026-09-15 追加**第二件事**（同一文件的同一个语义家族：索引状态 → 能不能继续）：
//  `IndexingGate.isReadyForChangeLogSync` = changeLog 同步的**唯一前置门**（本端曲库
//  索引未到终态 → 不装配数据同步端）。它是那个判定的唯一实现；"等"（waitUntilIdle）
//  与"能不能同步"（isReadyForChangeLogSync）在这里收在一处，别处不再各写一份。

import Combine
import Foundation

/// 索引状态来源。生产实现是 `LibraryIndexer`；测试注入假实现，
/// 避免测试触碰 DatabaseManager 单例。
@MainActor
protocol IndexingStateProviding: AnyObject {
    var isIndexing: Bool { get }
    var isIndexingPublisher: AnyPublisher<Bool, Never> { get }
    /// **曲库索引是否已到达终态**（= 曲库行已由一次完整主扫建立）。
    /// changeLog 同步前置门 `IndexingGate.isReadyForChangeLogSync` 的唯一事实位；
    /// **fail-closed**：拿不准就是 false（生产实现见 `LibraryIndexer`）。
    var hasReachedIndexingTerminalState: Bool { get }
    /// 终态事实**发生变化**的信号（不携带值）：订阅方收到后重新走唯一判定入口。
    /// 为什么是信号而不是值：事实由多个来源合成（本启动 latch + 曲库已有行），
    /// 在这里只声明「变了」，判定只有一处（不在这里复述）。
    var indexingTerminalStatePublisher: AnyPublisher<Void, Never> { get }
}

extension LibraryIndexer: IndexingStateProviding {
    var isIndexingPublisher: AnyPublisher<Bool, Never> {
        $isIndexing.eraseToAnyPublisher()
    }
}

/// 等待索引结束的时长策略（纯逻辑，可单测）。
struct IndexingWaitPolicy: Equatable {
    /// 最长等待时长（秒）。到期不再等待：放行后续同步流程，但绝不假装索引已完成。
    let timeout: TimeInterval

    /// 默认 300s：正常扫描（数千曲目）是分钟级，超过即视为索引异常，放行兜底。
    static let standard = IndexingWaitPolicy(timeout: 300)

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// 已等待 `elapsed` 秒时是否应停止等待（true = 放行兜底）。
    func shouldStopWaiting(elapsed: TimeInterval) -> Bool {
        elapsed >= timeout
    }

    /// Task.sleep 所需纳秒数（负值/零按 0 处理）。
    var timeoutNanoseconds: UInt64 {
        guard timeout > 0 else { return 0 }
        return UInt64(timeout * 1_000_000_000)
    }
}

/// 等待结束的方式。
enum IndexingWaitOutcome: Equatable {
    /// 调用时索引本来就没在跑。
    case alreadyIdle
    /// 索引正常结束。
    case finished
    /// 超过 policy.timeout：放行（用户不被永久阻塞），索引可能仍在后台跑。
    case timedOut
}

/// 「睡一觉」的唯一入口：超时兜底的计时经由这里，不在别处直接 `Task.sleep`。
///
/// 之所以是协议而不是可选闭包：这是**测试 seam**（生产唯一实现是 `TaskSleepSleeper`），
/// 调用方不传就必须走生产实现，不存在第二份计时。
protocol IndexingWaitSleeping: Sendable {
    func sleep(nanoseconds: UInt64) async
}

/// 生产实现（唯一）：真睡。
struct TaskSleepSleeper: IndexingWaitSleeping {
    func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
enum IndexingGate {
    // MARK: - changeLog 同步前置门（唯一实现）

    /// **曲库索引未到终态 → 不得发起 / 应答 changeLog 同步**（帧 8/9）——本判定的
    /// 唯一实现；别处不得再写一份（形状契约见 `SyncIndexingPreconditionContractTests`）。
    ///
    /// 为什么需要这道门（2026-09-15 真机取证）：每次安装后**第一次冷启动**，曲库行
    /// 由主扫重新建立之前 `track` 表是空的（业务表仍在：play_history 492 / favorite 1 /
    /// playlist_item 193 都指着它）。此时若同步跑起来：
    /// ① 出站补发对账把「track 表查不到」当成**本地悬空**→ 把 outbox 行清掉且不补发
    ///    （真值静默从同步层消失）；② 应答拉取 / 推增量的行全部拿不到 `content_hash`
    ///    与相对路径 → 对端整批判「未定位」，面板一片橙而数据其实没坏。
    /// 修法是**本端整体不接**：曲库索引未到终态就不装配数据同步端（不发起、不应答、
    /// 不补发对账），等终态到了再补装——不是「UI 上提示一下」。
    ///
    /// fail-closed：`hasReachedIndexingTerminalState` 为 false（拿不准/从没跑过主扫）
    /// 一律不放行；索引在跑（含重扫）也不放行。
    static func isReadyForChangeLogSync(_ source: IndexingStateProviding) -> Bool {
        source.hasReachedIndexingTerminalState && !source.isIndexing
    }

    /// 等索引结束。不做忙等；超时返回 `.timedOut` 由调用方兜底继续。
    /// - Parameter sleeper: 计时入口。生产调用方一律用默认值；只有测试传假实现，
    ///   用「立即到点 / 永不到点」两种假钟取代墙钟，杜绝计时敏感用例。
    static func waitUntilIdle(
        _ source: IndexingStateProviding,
        policy: IndexingWaitPolicy = .standard,
        sleeper: some IndexingWaitSleeping = TaskSleepSleeper()
    ) async -> IndexingWaitOutcome {
        if !source.isIndexing { return .alreadyIdle }

        var didResume = false
        var cancellable: AnyCancellable?
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<IndexingWaitOutcome, Never>) in
            let resumeOnce: (IndexingWaitOutcome) -> Void = { outcome in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: outcome)
            }

            // 索引翻回 false → 正常结束（.first() 保证订阅自动收尾）
            cancellable = source.isIndexingPublisher
                .first(where: { !$0 })
                .sink(receiveCompletion: { completion in
                    if case .failure = completion { resumeOnce(.timedOut) }
                }, receiveValue: { _ in resumeOnce(.finished) })

            // 超时兜底：索引异常 / 视图销毁也不会让等待悬死
            Task { @MainActor in
                await sleeper.sleep(nanoseconds: policy.timeoutNanoseconds)
                resumeOnce(.timedOut)
            }
        }
        cancellable?.cancel()
        return outcome
    }
}
