//
//  ScrapeCoverLoader.swift
//  QQPlayer
//
//  刮削封面下载**唯一入口**（2026-11-14，自动刮削/批量刮削批）。
//
//  背景：候选封面下载此前只有一处实现（`MacTagEditorView+Scrape.downloadCoverData`）。
//  自动刮削（下载完成后）与批量刮削都要下载封面 → 若各写一份，UA/超时/魔数校验
//  会变成三处手工对齐（PROJECT_RULES「同一语义只有一个入口」）。本文件收口：
//    · HTTP 细节（15s 超时、UA、HTTP 2xx 判定）只在这里；
//    · 格式判据仍走唯一入口 ScrapeLogic.validateCoverData（不在此再写魔数）。
//
//  行为与原单曲实现逐条一致：请求失败 / 非 2xx / 非法图片数据 → nil（不抛错）。
//  调用方语义不变：nil = 保留文件现有封面（自动/批量刮削里只记日志，不中断）。
//

import Foundation

enum ScrapeCoverLoader {
    /// 请求超时（与原 MacTagEditorView+Scrape.downloadCoverData 一致，web fetch_cover 对齐）
    static let timeout: TimeInterval = 15

    /// 下载候选封面 → 校验通过的原始图片数据；任何失败返回 nil。
    ///
    /// UA 复用 MusicBrainzClient.userAgent（刮削源统一标识，避免再写第三份 UA 字面量）。
    static func loadCoverData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(MusicBrainzClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              ScrapeLogic.validateCoverData(data) else {
            return nil
        }
        return data
    }
}
