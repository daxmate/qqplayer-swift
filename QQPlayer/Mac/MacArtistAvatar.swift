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

/// macOS 侧沿用旧名，实现见共享 `ArtistAvatarStyle`（纯文本规则，双 target 唯一实现）。
typealias MacArtistAvatarStyle = ArtistAvatarStyle

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
