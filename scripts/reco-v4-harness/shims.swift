//
//  shims.swift — reco-v4 本地 harness 专用替身
//
//  只编译「纯逻辑」生产源码（Matcher / Sampler / Selection / Profile / Ranker /
//  Retention + 它们依赖的类型），不编译网络客户端（NeteaseOnlineClient 等）。
//  这里补一个与生产同形的 `RecommendationRemoteSong`，仅为让类型系统闭环；
//  **不要**把本文件加进 App target。
//

import Foundation

/// `String.localized` 在 App 里由本地化扩展提供（本 harness 不编那份文件）。
extension String {
    var localized: String { self }

    func localized(with arguments: CVarArg...) -> String {
        String(format: self, arguments: arguments)
    }
}

/// 日志（App 里的 AppLog 不编进 harness；这里只保证签名闭环）。
enum AppLog {
    enum Category { case general }

    static func info(_ category: Category, _ message: @autoclosure () -> String) { _ = category; _ = message() }
    static func warn(_ category: Category, _ message: @autoclosure () -> String) { _ = category; _ = message() }
    static func error(_ category: Category, _ message: @autoclosure () -> String) { _ = category; _ = message() }
}

/// 曲库根目录（App 里的实现不在纯逻辑集内）。
enum LibraryRoot {
    static func macAppSupportRootURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}

struct RecommendationRemoteSong: Sendable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var year: Int?
    var songID: Int?
    var durationMs: Int?
    var artworkURL: URL?
    var previewURL: URL?
    var source: RecommendationSource?
    var degradedReason: String?
    var popularity: Double?

    init(
        title: String,
        artist: String,
        album: String? = nil,
        year: Int? = nil,
        songID: Int? = nil,
        durationMs: Int? = nil,
        previewURL: URL? = nil,
        artworkURL: URL? = nil,
        source: RecommendationSource? = nil,
        degradedReason: String? = nil,
        popularity: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.songID = songID
        self.durationMs = durationMs
        self.previewURL = previewURL
        self.artworkURL = artworkURL
        self.source = source
        self.degradedReason = degradedReason
        self.popularity = popularity
    }
}
