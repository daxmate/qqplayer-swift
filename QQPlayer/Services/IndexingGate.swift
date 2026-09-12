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

import Combine
import Foundation

/// 索引状态来源。生产实现是 `LibraryIndexer`；测试注入假实现，
/// 避免测试触碰 DatabaseManager 单例。
@MainActor
protocol IndexingStateProviding: AnyObject {
    var isIndexing: Bool { get }
    var isIndexingPublisher: AnyPublisher<Bool, Never> { get }
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

@MainActor
enum IndexingGate {
    /// 等索引结束。不做忙等；超时返回 `.timedOut` 由调用方兜底继续。
    static func waitUntilIdle(
        _ source: IndexingStateProviding,
        policy: IndexingWaitPolicy = .standard
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
                try? await Task.sleep(nanoseconds: policy.timeoutNanoseconds)
                resumeOnce(.timedOut)
            }
        }
        cancellable?.cancel()
        return outcome
    }
}
