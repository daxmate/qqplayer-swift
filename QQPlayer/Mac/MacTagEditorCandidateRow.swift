//
//  MacTagEditorCandidateRow.swift
//  QQPlayer
//
//  标签编辑弹窗候选行（web TagEditorModal.vue .cand-item 结构，E1 刮削批 2026-09）。
//  行内容：封面缩略（远程 AsyncImage / 占位）+ 标题/歌手/专辑/年份/流派/时长
//  （缺失段跳过，· 连接）+ 来源 badge。QQPlayerMac target only。
//

import SwiftUI

/// 单条刮削候选行
struct MacTagEditorCandidateRow: View {
    let candidate: ScrapeCandidate

    var body: some View {
        HStack(spacing: DesignTokens.space10) {
            cover
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(candidate.title.map(DisplayScriptNormalizer.display) ?? "")
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DesignTokens.space6)
            sourceBadge
        }
        .padding(.vertical, DesignTokens.space6)
        .padding(.horizontal, DesignTokens.space8)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.radius8))
        .contentShape(Rectangle())
    }

    private var cover: some View {
        Group {
            if let coverURL = candidate.coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius6))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.radius6)
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: DesignTokens.font13))
                    .foregroundColor(.secondary)
            }
    }

    /// 歌手 · 专辑 · 年份 · 流派 · 时长（web cand-sub 结构，缺失段跳过）
    /// 文本段按 UI 语言归一字形（刮削候选是“非模型字符串”，只影响显示；
    /// 选中后写入表单/DB 的仍是服务返回原文，见 MacTagEditorView）
    private var subtitle: String {
        var parts: [String] = []
        if let artist = candidate.artist, !artist.isEmpty { parts.append(DisplayScriptNormalizer.display(artist)) }
        if let album = candidate.album, !album.isEmpty { parts.append(DisplayScriptNormalizer.display(album)) }
        if let year = candidate.year { parts.append(String(year)) }
        if let genre = candidate.genre, !genre.isEmpty { parts.append(DisplayScriptNormalizer.display(genre)) }
        if let durationMs = candidate.durationMs, durationMs > 0 {
            parts.append(Self.formatDuration(durationMs))
        }
        return parts.joined(separator: " · ")
    }

    /// 来源 badge（MB 候选带 genre/track/album_artist 尽力值时，title 前缀不加——
    /// 尽力值已在 subtitle 的 genre 段体现；badge 只标来源）
    private var sourceBadge: some View {
        Text(candidate.source == "netease" ? "source_netease".localized : "source_musicbrainz".localized)
            .font(.system(size: DesignTokens.font9))
            .foregroundColor(.secondary)
            .padding(.horizontal, DesignTokens.space4)
            .padding(.vertical, DesignTokens.space2)
            .background(Color.gray.opacity(0.15), in: Capsule())
            .lineLimit(1)
    }

    private static func formatDuration(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
