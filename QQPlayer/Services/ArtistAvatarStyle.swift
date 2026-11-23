//
//  ArtistAvatarStyle.swift
//  QQPlayer
//
//  艺人头像的**纯文本规则**（不碰 AppKit / UIKit / 网络）：双 target 共享。
//
//  2026-11-23 从 `QQPlayer/Mac/MacArtistAvatar.swift` **原样搬出**，改为唯一实现：
//  macOS（`MacArtistAvatarStyle` = typealias）与 iOS（`ArtistAvatarView`）共用同一套
//  配色索引 / 首字母 / 文件名清洗规则 —— 不允许两份逻辑并存。
//
//  为什么单独成文件：iOS 端也要用同一规则，而 Mac 文件是 Mac 专属 target 成员
//  （见 `scripts/check-target-membership.py` 的 Mac 白名单）。
//

import Foundation

/// 艺人头像的**纯文本规则**（不碰 AppKit / UIKit / 网络）：独立 harness 可直接切片验证。
enum ArtistAvatarStyle {
    /// 稳定配色索引：Unicode 标量求和取模。
    /// **禁止 `String.hashValue` / `hashValue`**：Swift 的哈希按进程随机化，
    /// 同一个人每次启动会换颜色（视觉抖动 + 无法回归测试）。
    static func paletteIndex(for name: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        var sum = 0
        for scalar in name.unicodeScalars {
            sum = (sum &+ Int(scalar.value)) % paletteCount
        }
        return sum
    }

    /// 首字符：跳过前导空白；拉丁字母转大写，中文等原样；空名字回 `?`。
    static func monogram(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "?"
        }
        return String(first).uppercased()
    }

    /// 文件名安全清洗：去掉路径分隔符与文件系统非法字符，压缩首尾空白。
    /// `/` 会改变路径、`:` 在 Finder 里显示成 `/`，两者都必须去掉。
    static func sanitizedFileName(for name: String) -> String {
        let illegal: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]
        let cleaned = name.filter { !illegal.contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "_" : cleaned
    }
}
