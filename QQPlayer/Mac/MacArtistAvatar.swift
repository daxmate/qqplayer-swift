//
//  MacArtistAvatar.swift
//  QQPlayer
//
//  艺术家头像（**纯本地、零网络**）：三级回退
//  ① 曲库根 `artists/<艺人名>.jpg|jpeg|png`（本地照片，NSImage 直接读）
//  ② 代表曲目封面拼贴（≤4 张，复用 `MacArtworkCollage`）
//  ③ 首字符色块（稳定配色，禁用 `hashValue` —— Swift 每进程随机化，重启会换色）
//
//  「代表曲目」由 `MacLibraryFactsStore` 批量预取后按 artistId 缓存，本视图只做
//  字典查找（审计 M2：禁止每行每帧查库）。QQPlayerMac target only.
//

import AppKit
import SwiftUI

/// 艺人头像的**纯文本规则**（不碰 AppKit / 网络）：独立 harness 可直接切片验证。
enum MacArtistAvatarStyle {
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

/// 头像调色板：系统语义色（浅色 / 深色模式各自适配），白字可读。
/// 不用 hashValue 选色，见 `MacArtistAvatarStyle.paletteIndex`。
enum MacArtistAvatarPalette {
    static let colors: [NSColor] = [
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemGreen,
        .systemOrange,
        .systemBrown,
    ]

    static func color(for name: String) -> Color {
        let index = MacArtistAvatarStyle.paletteIndex(for: name, paletteCount: colors.count)
        return Color(nsColor: colors[index])
    }
}

/// 艺术家头像：本地照片 → 代表曲目拼贴 → 首字符色块。
///
/// - Parameters:
///   - artistName: 艺人原始名（清洗 / 配色 / 首字符都基于它）
///   - tracks: `MacLibraryFactsStore` 预取的 ≤4 条**有封面**代表曲目
///   - size: 边长（圆形，行内 40pt / 详情页 96pt）
struct MacArtistAvatar: View {
    let artistName: String
    let tracks: [Track]
    let size: CGFloat

    @State private var localPhoto: NSImage?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .accessibilityLabel(Text(artistName))
            .task(id: artistName) { await loadLocalPhoto() }
    }

    @ViewBuilder
    private var content: some View {
        if let localPhoto {
            Image(nsImage: localPhoto)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        } else if !tracks.isEmpty {
            MacArtworkCollage(
                tracks: tracks,
                size: size,
                cornerRadius: size / 2,
                placeholderIcon: "music.mic"
            )
        } else {
            monogram
        }
    }

    private var monogram: some View {
        ZStack {
            Circle()
                .fill(MacArtistAvatarPalette.color(for: artistName))
            Text(MacArtistAvatarStyle.monogram(for: artistName))
                .font(.system(size: max(size * 0.42, 11), weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.1)
        }
    }

    /// 本地照片读取：存在性判定收敛在 `MacLibraryRoot`（曲库根唯一 IO 入口）；
    /// 读字节放后台，NSImage 在主线程构造（懒解码，避免占主线程解码整库图）。
    private func loadLocalPhoto() async {
        guard let url = MacLibraryRoot.artistPhotoURL(forArtistName: artistName) else {
            localPhoto = nil
            return
        }
        // 后台下采样后上屏（复用封面同一套 CGImageSource 管线）：
        // 直接 NSImage(data:) 会把原图留到绘制时在主线程同步解码，40 / 96pt 用不到原图。
        let maxPixelSize = max(size * 2, 80)
        let image = await Task.detached(priority: .utility) {
            ArtworkManager.downsampledImage(at: url, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        // 解码失败（文件损坏 / 不是图片）→ nil → 自动退到下一级（拼贴 / 首字符色块）
        localPhoto = image
    }
}
