//
//  TagRenameLogic.swift
//  QQPlayer
//
//  重命名模板渲染纯逻辑（web tag_editor.target_filename/_render_rename_template 移植，
//  E1 刮削批 2026-09）。web 为唯一事实源，行为逐条对齐（回归测试锚定）：
//
//  - 模板占位符 {artist}/{title}/{album}/{track}/{year}；值为 nil/空 → 渲染空串；
//    非法占位符/语法错误 → 回落默认模板 "{artist} - {title}"
//  - 模板为 nil 或等于默认模板 → 旧版分支逻辑（artist+title 都空 → 返回 nil 不改名；
//    artist 空 → 只有 title，不留 " - " 分隔符）
//  - 模板含 '/' → 相对文件所在目录的子目录（调用方 mkdir parents）
//  - 非法文件名字符清洗（不含 '/'，保留其目录分隔语义）；过滤空/./.. 路径段防穿越
//  - 同名去重 (2)(3) 递增由调用方（TagWriterService）在目标目录做，本逻辑只渲染
//  - track/year 渲染：数字转字符串，nil/非法 → 空串

import Foundation

enum TagRenameLogic {
    static let defaultTemplate = "{artist} - {title}"

    /// 模板渲染上下文（文件当前标签值；nil = 空占位）
    struct Values {
        var artist: String?
        var title: String?
        var album: String?
        var track: Int?
        var year: Int?

        init(artist: String? = nil, title: String? = nil, album: String? = nil,
             track: Int? = nil, year: Int? = nil) {
            self.artist = artist
            self.title = title
            self.album = album
            self.track = track
            self.year = year
        }
    }

    /// 按模板渲染目标文件名（相对文件所在目录，可能含子目录路径段）。
    /// 返回 nil = 不改名。S1 实现。
    static func renderFileName(
        template: String?,
        values: Values,
        ext: String
    ) -> String? {
        fatalError("S1 实现：模板渲染纯逻辑（web target_filename 语义）")
    }
}
