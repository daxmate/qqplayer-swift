//
//  LyricAlignmentActions.swift
//  QQPlayer
//
//  视图层的动作入口：视图不得直连单例（QQPlayerTests/ViewSharedSingletonContractTests.swift），
//  所以「取歌词 → 复核判据 → 交给 controller」全部收敛到本文件的非视图类型里。
//

import Foundation

@MainActor
enum LyricAlignmentActions {
    /// 供进度 sheet 宿主注入的 controller 实例（视图只拿实例，不写 `.shared`）。
    static var controller: LyricAlignmentController { LyricAlignmentController.shared }

    /// 对齐某首歌：歌词取不到 / 判据不满足 → 记一条可读失败文案（sheet 展示）。
    static func startAlignment(for track: Track) async {
        // track.path 是存储形态（相对 Documents/Music），必须经 LibraryRoot 解析；空串不解析。
        let fileExists = !track.path.isEmpty
            && FileManager.default.fileExists(atPath: LibraryRoot.absolutePath(forStoredPath: track.path))
        guard let lyrics = await LyricsManager.shared.getLyrics(for: track),
              LyricAlignmentFeature.canAlign(track: track, lyrics: lyrics, fileExists: fileExists)
        else {
            LyricAlignmentController.shared.fail(message: "lyrics.align.error.emptyLyrics".localized)
            return
        }
        await LyricAlignmentController.shared.start(track: track, lyrics: lyrics)
    }

    /// 恢复原歌词时间轴（写盘失败只记日志：菜单路径没有结果页可展示错误）。
    static func revertAlignment(for track: Track) {
        do {
            try LyricAlignmentController.shared.revert(stableId: track.stableId)
        } catch {
            AppLog.error(.ui, "❌ Failed to revert lyric alignment: \(error)")
        }
    }
}
