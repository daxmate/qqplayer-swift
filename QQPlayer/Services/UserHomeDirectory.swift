//  UserHomeDirectory.swift
//  QQPlayer
//
//  **真实用户 home 目录**的唯一入口（平台无关，可单测）。
//
//  背景（MAS 沙盒化，批 2B 2026-10-29）：沙盒里 `FileManager.homeDirectoryForCurrentUser`
//  返回的是**容器** Data 目录（`~/Library/Containers/<bundle id>/Data`）。拿它拼
//  `Music/QQPlayer` 会得到容器内路径——授权、扫描、同步 `rel:` 命名空间全部指向错误位置，
//  而且「看起来很正常」（目录确实能建、能写），是最难发现的一类沙盒回归。
//
//  口径：凡是「用户主目录」语义（曲库默认根、`~` 展开、旧库位置）一律走这里；
//  「App 数据位置」语义（Application Support / Logs）继续用 FileManager，它们本来就该落容器。
//

import Darwin
import Foundation

enum UserHomeDirectory {
    /// 真实用户 home（`getpwuid` 不受沙盒重定向影响）。
    ///
    /// 取不到 passwd 条目时退回 `NSHomeDirectory()`（iOS 与极端异常场景的兜底）。
    static var realHomeURL: URL {
        if let passwordEntry = getpwuid(getuid()) {
            let path = String(cString: passwordEntry.pointee.pw_dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
