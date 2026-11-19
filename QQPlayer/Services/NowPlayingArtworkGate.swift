//
//  NowPlayingArtworkGate.swift
//  QQPlayer
//
//  target: ios-only
//
//  2026-11-19 CarPlay 封面偶发空白修复：把「切歌 → 发布 nowPlayingInfo」的封面决策
//  抽成不依赖 UIKit / MediaPlayer 的纯逻辑，供 QQPlayerTests 直接覆盖。
//
//  背景：锁屏与 CarPlay 读同一份 MPNowPlayingInfoCenter.nowPlayingInfo，且 CarPlay 多数
//  只在元数据变化时读一次 → 「先发布无 artwork 的信息、再异步补图」= 一路空白窗口。
//  所以「任何一次发布都必须带 artwork 键」是本模块的硬约束。
//
//  本文件只有两件事：
//    ① decide：这一次发布该用哪张图（缓存 → 刚取到 → 超时兜底 → 占位）
//    ② run   ：有界等待（超时不取消后台任务，真图到位后走既有补发路径）
//  切歌代际校验在 PlaybackTrackGate（PlaybackModels.swift，两端共享、同样可单测）。
//

import Foundation

/// 首次发布的封面决策（纯函数；`Artwork` 在生产侧是 MPMediaItemArtwork，测试用替身）。
///
/// 决策顺序固定，任何输入都返回**非 nil** 封面：
/// 1. `cached`      —— 本曲封面已在内存里（ArtworkManager 命中 / 已解析过）
/// 2. `arrived`     —— 有界等待窗口内刚取到的真封面
/// 3. `previous`    —— 超时兜底：上一曲封面（总比空白好，真图到位后会被替换）
/// 4. `placeholder` —— 占位图（首次播放 / 本曲确实没有内嵌封面）
///
/// 只有**超时**才允许拿上一曲封面兜底：本曲确无封面时退回占位图，
/// 否则会把上一首的封面永久钉在锁屏和车机上。
enum NowPlayingArtworkGate {
    /// 日志里要能一眼看出这张图从哪来（真机取证用）
    enum Source: String, Equatable {
        case cached
        case extracted
        case previousTrack
        case placeholder
    }

    struct Resolution<Artwork> {
        let artwork: Artwork
        let source: Source
        let timedOut: Bool
    }

    static func decide<Artwork>(
        cached: Artwork?,
        arrived: Artwork?,
        previous: Artwork?,
        placeholder: Artwork,
        timedOut: Bool
    ) -> Resolution<Artwork> {
        if let cached {
            return Resolution(artwork: cached, source: .cached, timedOut: false)
        }
        if let arrived {
            return Resolution(artwork: arrived, source: .extracted, timedOut: false)
        }
        if timedOut, let previous {
            return Resolution(artwork: previous, source: .previousTrack, timedOut: true)
        }
        return Resolution(artwork: placeholder, source: .placeholder, timedOut: timedOut)
    }
}

/// 有界等待：最多阻塞 `timeout`，超时返回 false 且**不取消**被等待的任务。
///
/// 为什么不用 TaskGroup：group 退出时会 await 所有子任务，而封面解压走
/// DispatchQueue + continuation、不响应取消 → 超时形同虚设，首播会被大文件拖住。
/// 这里用一次性 continuation 竞速：先到者写结果，输的一方继续在后台跑完
/// （完成后走既有补发路径把真图换上）。
enum NowPlayingBoundedWait {
    @MainActor
    static func run(for task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ResumeOnce(continuation)
            Task { @MainActor in
                _ = await task.value
                box.resume(finished: true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                box.resume(finished: false)
            }
        }
    }
}

/// 两个竞速任务共用一个 continuation，先到者赢，第二个调用是 no-op。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(finished: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: finished)
    }
}
