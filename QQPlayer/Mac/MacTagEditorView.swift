//
//  MacTagEditorView.swift
//  QQPlayer
//
//  标签编辑/刮削弹窗（web TagEditorModal.vue 移植，E1 刮削批 2026-09）。
//  骨架：S4（UI 批）实现。用户已拍板形态：sheet 弹窗。
//
//  功能契约（web TagEditorModal + /api/tags 语义对齐）：
//  - 打开即自动刮削：POST /api/tags/scrape 等价 → 候选分组展示
//    （netease[] / musicbrainz[] 分节；行：标题/歌手/专辑/封面缩略/年份/时长；
//    来源 badge；MB 候选带 track/genre/album_artist 尽力值）
//  - 点选候选 → 填充表单（可再编辑）；网易云候选且表单 year 空 →
//    静默调 song/detail 补年份（POST /api/tags/album-year 等价，不阻塞）
//  - 表单字段：title/artist/album/year/genre/track/album_artist + 封面（当前文件
//    封面预览 + 候选封面下载替换）+ 重命名（开关或随设置模板；web 保存总是按
//    rename_template 改名，模板在设置「刮削」分类配置，默认 "{artist} - {title}"）
//  - 保存 = TagWriterService.writeTags（原子写+改名）→ renamed 时 DatabaseManager
//    moveTrack 迁移引用 → 通知刷新（LibraryFolderContentChanged）→ toast；
//    改名后 UI 目标歌曲路径跟随（不打断播放的曲目用新路径刷新元数据）
//  - 错误处理：UnsupportedFormatError → 弹提示「该格式不支持写标签」；
//    写失败 → 红字真实原因（web 409 语义）
//  - 入口：MacTrackListView 右键菜单第 8 项「编辑标签/刮削」（单曲）
//
//  多选批量入口（右键批量「批量刮削…」）另见 MacScrapeBatchView/或本视图复用。

import SwiftUI

struct MacTagEditorView: View {
    var body: some View {
        // S4 实现
        EmptyView()
    }
}
