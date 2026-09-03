//  MacFolderMonitor.swift
//  QQPlayer
//
//  macOS 曲库文件夹 FSEvents 实时监控（QQPlayerMac target only）。
//
//  背景（2026-09-03 B 组）：批次 3 MVP = 启动全扫 + 手动刷新，实时监控后补。
//  对齐 web 版 watchdog 语义：递归监听配置曲库文件夹 → 事件（创建/删除/改名/
//  文件内容变化）经 2s 去抖 → 触发一次全量重扫（scanMusicFolder 本就是全量 +
//  reconcile 删缺失曲目，等价 web 的 _rescan() + version++）。
//
//  架构：
//  - FSEventStream（CoreServices）按路径数组监听，fileEvents 标志拿到文件级事件
//  - 回调跑在独立串行队列；去抖后派发到主线程，经 onChange（业务侧转
//    LibraryFolderContentChanged 通知 → MacLibraryView 走 reload + start/排队）
//  - 生命周期与曲库文件夹集合绑定：start(paths:onChange:) 可随时重启
//    （设置页增删文件夹后由 MacLibraryView 调 restart）
//

import CoreServices
import Foundation

final class MacFolderMonitor: @unchecked Sendable {
    static let shared = MacFolderMonitor()

    /// 去抖后回调（已在主线程）。文件夹增删改（含目录自身元数据噪声已过滤）。
    private var onChange: (() -> Void)?

    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.daxmate.qqplayer.fsevents")
    private var debounceWorkItem: DispatchWorkItem?
    /// 事件处理信号量：start 与 FSEventStream 回调可能并发，防重启竞态
    private let lock = NSLock()

    private init() {}

    deinit {
        stop()
    }

    /// 开始监听。重复调用会先停旧流（幂等）。只监听存在的文件夹
    /// （MacFolderWatchPolicy.relevantFolders 已过滤）。
    func start(paths: [String], onChange: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        self.onChange = onChange
        stopStreamLocked()

        let relevant = MacFolderWatchPolicy.relevantFolders(paths.map { URL(fileURLWithPath: $0) })
            .map(\.path)
        guard !relevant.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<MacFolderMonitor>.fromOpaque(info).takeUnretainedValue()
            var paths: [String] = []
            // SDK 头：eventPaths 是 `void *`（实为 char** 数组）→ Swift 导入为
            // UnsafeMutableRawPointer，需按 C 字符串指针数组重新绑定后索引
            let pathPointers = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            for i in 0 ..< numEvents {
                if let rawPath = pathPointers[i] {
                    paths.append(String(cString: rawPath))
                }
            }
            monitor.handleEvents(paths: paths)
        }

        // 10s 历史 + 文件级事件 + 根路径自身变化也上报（watchRoot 让目录被
        // 移动/删除时也能感知，扫描收尾 reconcile 会清理）
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            relevant as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latency（秒）：FSEvents 内核级聚合窗口
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            streamRef = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// 停止监听（幂等）。
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopStreamLocked()
        onChange = nil
    }

    /// 重启（文件夹集合变化后调用）。锁已由调用方持有。
    private func stopStreamLocked() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    /// FSEvents 回调线程：收集相关路径 → 2s 去抖 → 主线程通知。
    fileprivate func handleEvents(paths: [String]) {
        // 噪声过滤（隐藏文件/.DS_Store/Finder 元数据等）
        let relevant = paths.filter { !MacFolderWatchPolicy.shouldIgnore(eventPath: $0) }
        guard !relevant.isEmpty else { return }

        lock.lock()
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = workItem
        lock.unlock()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(MacFolderWatchPolicy.debounceNanoseconds)),
            execute: workItem
        )
    }
}
