//
//  PlayerGestureLogic.swift
//  QQPlayer
//
//  播放页/歌词页手势与歌词时间轴的纯逻辑（不依赖 SwiftUI，可单元测试）
//

import CoreGraphics
import Foundation

/// 歌词时间轴计算：当前播放时间 → 当前歌词行
enum LyricTiming {
    /// 当前播放时间对应的歌词行 index；早于第一句返回 nil；无时间戳的行跳过。
    /// 语义：最后一个 timestamp <= time 的行；time 在两句之间时返回前一句。
    static func activeLineIndex(time: TimeInterval, in lines: [LyricsLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var idx: Int?
        for (i, line) in lines.enumerated() {
            guard let ts = line.timestamp else { continue }
            if time >= ts {
                idx = i
            } else {
                break
            }
        }
        return idx
    }
}

/// 播放页/歌词页的滑动手势关闭判定（阈值 + 快速回甩）
enum PlayerDismissGesture {
    /// 歌词页右滑关闭：位移超过 120pt，或位移过半（>40pt）且快速回甩（预测 >260pt）
    static func shouldDismissLyrics(translation: CGFloat, predictedTranslation: CGFloat) -> Bool {
        translation > 120 || (translation > 40 && predictedTranslation > 260)
    }

    /// 歌词搜索页左滑关闭（从左侧滑入的页面左滑往回推）：与歌词页右滑关闭镜像
    static func shouldDismissLyricsSearch(translation: CGFloat, predictedTranslation: CGFloat) -> Bool {
        translation < -120 || (translation < -40 && predictedTranslation < -260)
    }

    /// 播放页封面下拉关闭：位移达 100pt，或位移过半（>40pt）且快速下拉（预测 >300pt）
    static func shouldDismissPlayer(pullOffset: CGFloat, predictedHeight: CGFloat) -> Bool {
        pullOffset >= 100 || (pullOffset >= 40 && predictedHeight > 300)
    }
}

/// 整页手势按**起手位置**划分的区域（`PlayerPageGesture.region` 的返回值）
enum PlayerPageRegion: Hashable {
    /// 封面区：横滑切歌（队列 >1）/ 竖向归封面手势（下拉缩回主页）
    case artwork
    /// 进度条区：横滑 seek / 竖向 seek（进度条手势独占）
    case progress
    /// 其余整页区：左右滑开歌词 / 搜索，上下滑展开 / 收起 / 缩回主页
    case page
}

/// 播放页**整页手势**的判定（2026-09-22：作用范围从「封面 / 小歌词窗 / 控制区」扩到整页）：
/// - 左右滑 → 全屏歌词页 / 歌词搜索页（封面横滑切歌、进度条横滑 seek 两处例外不走这里）
/// - 上滑 → 展开「更多播放控制」；下滑 → 收起展开面板（面板未展开时则缩小主页，见 PlayerDismissGesture）
/// 阈值与历史小歌词窗手势一致（位移 ±60pt / 快速回甩 ±120pt），只是消费点从「小歌词窗」
/// 换成了整页——同一语义只留一份判定（旧 `MiniLyricSwipeGesture` 已删）。
enum PlayerPageGesture {
    // MARK: - 起手区域（例外手势按区域排除；纯逻辑，供视图与单测共用）

    /// 进度条区的触摸外扩量（pt，上下各一份）：进度条布局高仅 1pt（可见轨道 4pt / 滑块 12pt），
    /// 不外扩则排除带几乎无宽度，「起手在进度条上」判不出来；外扩值远小于它与时间标签行的间距
    /// （12/16pt），不会把标签行的横向手势吃掉
    static let progressTouchSlop: CGFloat = 8

    /// 进度条实际 frame → 触摸区（frame 未测量到 .zero 时返回 .null：不排除任何点）。
    /// 横向排除带按**实测 frame** 收窄（旧实现写死「控制容器顶部 60pt」，把时间标签行与其下空白
    /// 一起排除，导致那块区域左右滑无响应，2026-09-22 复核 ②）
    static func progressTouchRegion(barFrame: CGRect) -> CGRect {
        guard !barFrame.isEmpty else { return .null }
        return barFrame.insetBy(dx: 0, dy: -progressTouchSlop)
    }

    /// 起手位置 → 区域（**横向**分流用）：封面区在「无可切换的相邻曲目」（队列 ≤1）时
    /// 没有切歌可言，按整页处理——否则封面区（约 360pt 高）左右滑什么也不发生
    /// （2026-09-22 复核 ①）。队列 >1 时仍返回 .artwork（封面横滑切歌不受影响）
    static func region(
        startLocation: CGPoint,
        artworkFrame: CGRect,
        progressFrame: CGRect,
        canSwitchTrack: Bool
    ) -> PlayerPageRegion {
        if artworkFrame.contains(startLocation) {
            return canSwitchTrack ? .artwork : .page
        }
        if progressFrame.contains(startLocation) {
            return .progress
        }
        return .page
    }

    /// 整页手势是否接管**竖向**（下拉跟手）：封面区竖向归封面手势、进度条区竖向归 seek，
    /// 两者都除外——起手在进度条上时下拉只 seek，不再「一次下拉两个效果」
    /// （既改播放位置又下移整页，2026-09-22 复核 ②）
    static func ownsVerticalPull(
        startLocation: CGPoint,
        artworkFrame: CGRect,
        progressFrame: CGRect
    ) -> Bool {
        !artworkFrame.contains(startLocation) && !progressFrame.contains(startLocation)
    }

    // MARK: - 方向与阈值

    /// 拖动方向（首个回调判定后锁定，横/纵互斥）
    enum Axis {
        case horizontal
        case vertical
    }

    /// 方向锁定：|横向位移| > |纵向位移| 即横向
    static func axis(translation: CGSize) -> Axis {
        abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
    }

    /// 上滑展开「更多播放控制」：上滑 ≥ 30pt
    static func shouldExpandMoreControls(translationHeight: CGFloat) -> Bool {
        translationHeight < -30
    }

    /// 下滑收起「更多播放控制」：下滑 ≥ 30pt
    static func shouldCollapseMoreControls(translationHeight: CGFloat) -> Bool {
        translationHeight > 30
    }

    /// 左滑打开全屏歌词页（从右侧滑入）
    static func shouldOpenLyricsSheet(translation: CGFloat, predictedTranslation: CGFloat) -> Bool {
        translation < -60 || predictedTranslation < -120
    }

    /// 右滑打开歌词搜索页（从左侧滑入）
    static func shouldOpenLyricsSearch(translation: CGFloat, predictedTranslation: CGFloat) -> Bool {
        translation > 60 || predictedTranslation > 120
    }
}
