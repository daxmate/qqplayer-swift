//
//  MacLibraryRootAccess.swift
//  QQPlayer
//
//  macOS 曲库根的**安全作用域授权唯一入口**（MAS 沙盒化，批 2B 2026-10-29）。
//
//  为什么必须存在：开 App Sandbox 后，容器外的 `~/Music/QQPlayer`（以及用户指定
//  的 NAS / 外接盘目录）默认**不可读**。可读的前提只有两条：
//    ① 用户经 NSOpenPanel 选过一次 → 拿到 security-scoped bookmark；
//    ② 启动时解析该书签并 `startAccessingSecurityScopedResource()`。
//  以前没有这一层：读不到 = 扫描白跑 = **静默空库**（用户以为丢歌）。
//
//  口径：
//    · 判定纯逻辑在 `Services/LibraryRootAccessPlan.swift`（可单测，两平台共用）；
//    · **本文件是书签读写的唯一入口**——别处不得再 `bookmarkData(options: .withSecurityScope)`；
//    · 期望根仍由 `MacLibraryRoot.desiredRootURL`（设置指定 → 否则默认）决定，
//      本文件不改「曲库在哪」的口径，只回答「能不能读」。
//
//  target: macos-only
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MacLibraryRootAccess {
    /// App 级单例：装配点在 `QQPlayerMacApp`（两个场景根各注入一次），视图只读环境值。
    static let shared = MacLibraryRootAccess()

    /// UserDefaults key（唯一事实源；书签是 Data，跟着 App 容器走）。
    static let bookmarkDefaultsKey = "mac.libraryRootSecurityScopedBookmark"

    /// 当前访问状态；视图（授权引导页 / 设置页）只读这个值。
    private(set) var state: LibraryRootAccessState = .needsAuthorization

    /// 最近一次失败原因（展示用；nil = 无）。
    private(set) var lastErrorMessage: String?

    /// 已成功开启安全作用域的根（nil = 当前没有活动授权）。
    private(set) var authorizedRootURL: URL?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isAccessingScope = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 期望曲库根（设置指定 → 否则 `~/Music/QQPlayer`；不判存在性）。
    var desiredRootURL: URL { MacLibraryRoot.desiredRootURL }

    // MARK: - 状态

    /// 重新判定「现在能不能读期望根」，并按需解析已存书签（幂等，启动与授权后各调一次）。
    func refreshState() {
        let desired = desiredRootURL
        let bookmarkURL = restoreBookmarkIfNeeded(for: desired)
        let scopeActive = bookmarkURL != nil && isAccessingScope
        let readable = FileManager.default.isReadableFile(atPath: desired.path)
        let next = LibraryRootAccessPlan.decide(
            desiredRootPath: desired.path,
            bookmarkRootPath: bookmarkURL?.path,
            bookmarkScopeActive: scopeActive,
            rootIsReadable: readable
        )
        if next != state {
            AppLog.info(.ui, "🔐 曲库根访问状态：\(state) → \(next)（\(desired.path)）")
        }
        state = next
    }

    // MARK: - 授权

    /// 用户经 NSOpenPanel 选好目录后调用：存书签 + 立刻开启安全作用域 + 刷新状态。
    ///
    /// 顺带把「设置里的曲库位置」对齐到该目录（选择 = 授权 + 指定位置，同一动作），
    /// 否则下次启动「设置说要 A、书签指向 B」→ 又变回未授权。
    func authorize(_ url: URL, updateSettings: Bool = true) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        stopAccessingScope()
        defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)

        isAccessingScope = url.startAccessingSecurityScopedResource()
        authorizedRootURL = url
        lastErrorMessage = nil

        if updateSettings {
            applyLibraryRootSetting(for: url)
        }
        MacLibraryRoot.ensureRootExists()
        refreshState()
        AppLog.info(.ui, "🔐 曲库根已授权：\(url.path)（scope=\(isAccessingScope)）")
    }

    /// 退出前释放安全作用域（**保留书签**）：下次启动照常恢复。
    func releaseAccess() {
        stopAccessingScope()
        state = .needsAuthorization
    }

    /// 放弃当前授权（停止作用域 + 删书签）；不删用户在磁盘上的任何文件。
    func revoke() {
        stopAccessingScope()
        defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
        authorizedRootURL = nil
        state = .needsAuthorization
    }

    // MARK: - 内部

    /// 解析已存书签；路径与期望根一致才开启安全作用域并返回该 URL。
    private func restoreBookmarkIfNeeded(for desired: URL) -> URL? {
        if let authorizedRootURL,
           LibraryRootAccessPlan.canonicalPath(authorizedRootURL.path)
           == LibraryRootAccessPlan.canonicalPath(desired.path) {
            return authorizedRootURL
        }
        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return nil }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            AppLog.warn(.ui, "⚠️ 曲库根书签解析失败（按未授权处理）：\(error)")
            defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
            return nil
        }
        guard LibraryRootAccessPlan.canonicalPath(url.path)
            == LibraryRootAccessPlan.canonicalPath(desired.path) else {
            // 书签指向别的目录（设置换了位置）：等用户在设置页/引导页重新授权。
            return nil
        }

        // 上一个根的作用域先关掉（换位置后重复解析不叠加 start 次数）。
        stopAccessingScope()
        isAccessingScope = url.startAccessingSecurityScopedResource()
        authorizedRootURL = url
        if isStale {
            // 书签过期但仍可用：立刻刷新一份，避免下次启动失效。
            if let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
            }
        }
        if !isAccessingScope {
            AppLog.warn(.ui, "⚠️ 曲库根安全作用域未开启（\(url.path)）——非沙盒构建或书签已失效")
        }
        return url
    }

    /// 把设置里的曲库位置对齐到已授权目录：等于默认根 → 存空串（默认语义）。
    private func applyLibraryRootSetting(for url: URL) {
        let path = LibraryRootAccessPlan.canonicalPath(url.path)
        let defaultPath = LibraryRootAccessPlan.canonicalPath(MacLibraryRoot.defaultRootURL.path)
        var settings = DeleteSettings.load()
        let next = path == defaultPath ? "" : path
        guard settings.libraryRoot != next else { return }
        settings.libraryRoot = next
        settings.save()
    }

    private func stopAccessingScope() {
        guard isAccessingScope, let url = authorizedRootURL else {
            isAccessingScope = false
            authorizedRootURL = nil
            return
        }
        url.stopAccessingSecurityScopedResource()
        isAccessingScope = false
        authorizedRootURL = nil
    }
}
