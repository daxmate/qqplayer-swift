//  LibraryRootAccessPlan.swift
//  QQPlayer
//
//  曲库根「访问授权」决策纯逻辑（平台无关，iOS / macOS 共享，可单测）。
//
//  背景（MAS 批 2B，2026-10-29）：macOS 版开 App Sandbox 后，`~/Music/QQPlayer`
//  这类**容器外**目录默认不可读——必须由用户经 NSOpenPanel 授权一次，再靠
//  security-scoped bookmark 持久化。授权与否的判定散在视图里 → 两套口径（沙盒内
//  读不到 = 空库 = 静默失败）。本文件把判定收成纯函数，IO 与 AppKit 全在
//  `Mac/MacLibraryRootAccess.swift`（唯一入口）。
//
//  判定只回答一个问题：**现在能不能真正读到用户想要的那个曲库根**。
//  两条通过路径（任一成立即视为已授权）：
//    1. 已存书签解析成功、路径与期望根一致、且安全作用域已开启；
//    2. 该目录当前确实可读（未沙盒的开发构建 / 目录本来就在容器内 / 用户已授权）。
//

import Foundation

/// 曲库根访问状态。
enum LibraryRootAccessState: Equatable {
    /// 可以读：授权有效，或当前运行环境本来就放行（未沙盒 / 容器内目录）。
    case granted
    /// 读不到：需要用户选一次曲库文件夹（沙盒首次启动 / 书签失效 / 换了位置）。
    case needsAuthorization
}

enum LibraryRootAccessPlan {
    /// 授权判定（纯函数，无 IO）。
    ///
    /// - Parameters:
    ///   - desiredRootPath: 用户想要的曲库根（设置里的指定位置，否则默认根）
    ///   - bookmarkRootPath: 已存书签解析出的目录（nil = 没有可用书签）
    ///   - bookmarkScopeActive: 书签已解析且 `startAccessingSecurityScopedResource` 成功
    ///   - rootIsReadable: 目录当前实际可读（`FileManager.isReadableFile`）
    static func decide(
        desiredRootPath: String,
        bookmarkRootPath: String?,
        bookmarkScopeActive: Bool,
        rootIsReadable: Bool
    ) -> LibraryRootAccessState {
        if bookmarkScopeActive,
           let bookmarkRootPath,
           canonicalPath(bookmarkRootPath) == canonicalPath(desiredRootPath) {
            return .granted
        }
        return rootIsReadable ? .granted : .needsAuthorization
    }

    /// 路径比较口径（唯一入口）：标准化 + 去尾斜杠；相等即同一目录。
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
